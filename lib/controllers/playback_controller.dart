import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../dash/dash_stream_server.dart';
import '../models/playlist.dart';
import '../services/av3a_stream_server.dart';
import '../services/debug_log_service.dart';
import '../services/mmt_tlv_utils.dart';
import '../services/ping_service.dart';
import '../services/proxy_service.dart';
import '../services/user_agent_service.dart';

/// Owns the media_kit player engine and all playback state: the reconnect
/// state machine, ytdl grace handling, freeze-frame overlay, mpv option
/// application, transport controls, snapshots, fullscreen and cursor hiding.
///
/// This is a near-verbatim port of the original `_IptvHomeState` playback
/// logic: `mounted` becomes `!_disposed`, `setState(...)` becomes
/// `notifyListeners()`, and user-facing text is emitted on [messages].
class PlaybackController extends ChangeNotifier {
  PlaybackController() {
    final engine = _createPlaybackEngine();
    player = engine.$1;
    videoController = engine.$2;
    _dashSubtitleSubscription = _dashServer.subtitleCues.listen(
      _handleDashSubtitleCues,
    );
    _dashTtmlTrackSubscription = _dashServer.ttmlTracks.listen(
      _handleDashTtmlTracks,
    );
    _listenPlaybackInfo();
  }

  Player? _player;
  Player get player => _player!;
  set player(Player value) => _player = value;

  VideoController? _videoController;
  VideoController get videoController => _videoController!;
  set videoController(VideoController value) => _videoController = value;

  bool _engineReleased = false;
  bool get hasPlaybackEngine => _player != null;
  // Bumped every time the engine is recreated or fully released. The player
  // page keys its `Video` widget with this so a fresh Video State binds to the
  // new VideoController (media_kit's Video does not rebind a swapped controller
  // in didUpdateWidget).
  int _engineGeneration = 0;
  int get engineGeneration => _engineGeneration;

  // Local exo_driven DASH engine for ClearKey-protected MPEG-DASH. When active,
  // mpv is pointed at its single muxed/decrypted local fMP4 stream instead of
  // the origin URL.
  final DashStreamServer _dashServer = DashStreamServer();
  // AV3A (AVS3-P3 / Audio Vivid) is decoded by a dedicated FFmpeg build,
  // remuxed with the untouched video, and exposed as synchronized Matroska.
  final Av3aStreamServer _av3aServer = Av3aStreamServer();
  // The URL actually handed to mpv for the current channel: the origin URL for
  // plain and native MMT/TLV streams, or a loopback proxy URL for ClearKey DASH
  // and AV3A. Used by the reconnect path so it reloads the right source.
  String _activeStreamUrl = '';
  // Retain format hints so reconnects re-apply the same lavf demuxer options.
  bool _activeIsHls = false;
  bool _activeIsAv3a = false;
  bool _activeIsMmtTlv = false;
  // Guards the log-triggered fallback: mpv can emit several AV3A warnings for
  // one stream before the local transcoder has finished starting.
  bool _av3aFallbackStarting = false;
  // Set true for the current stream once we've fallen back to opening it with
  // mpv's `tls-verify=no` after a TLS certificate verification failure. Some
  // IPTV origins serve HTTPS with self-signed/expired certs; mpv (via its curl
  // network layer) refuses them by default and prints "curl: TLS certificate
  // verification failed" + "Failed to open". We keep verification ON normally
  // and only disable it, per-stream, after seeing that failure — then reconnect
  // so the stream is reopened with the relaxed setting. Reset on every play().
  bool _tlsVerifyDisabled = false;
  // Guards the log-triggered TLS fallback so the burst of curl error lines mpv
  // emits for one failed open only triggers a single retry.
  bool _tlsFallbackStarting = false;
  // Counts consecutive "ad: Error decoding audio." lines from mpv for the
  // current open. A single transient decode error is ignored; a sustained run
  // of them means mpv has no working decoder for this audio (AV3A on the
  // bundled libmpv), which triggers the AV3A bridge fallback.
  int _audioDecodeErrorStreak = 0;
  static const _av3aDecodeErrorThreshold = 3;

  final TextEditingController streamUrlController = TextEditingController();
  final FocusNode playerFocusNode = FocusNode();

  Channel? nowPlaying;
  VideoParams videoParams = const VideoParams();
  Track selectedTrack = const Track();

  /// Subtitles are enabled afresh for every selected channel. This lets HLS
  /// WebVTT renditions and embedded container tracks follow their default or
  /// forced disposition without carrying an "off" choice to the next video.
  bool subtitlesEnabled = true;

  /// Every subtitle track offered to the viewer: the ones libmpv reports for the
  /// current stream, followed by one synthetic entry per DASH TTML track that
  /// Flutter has to draw itself.
  List<SubtitleTrack> subtitleTracks = const [];
  List<SubtitleTrack> _nativeSubtitleTracks = const [];
  List<DashTtmlTrack> _dashTtmlTracks = const [];
  String? _pendingDefaultSubtitleId;
  String? _autoSelectedSubtitleId;
  // Ids of the subtitle tracks mpv reported but cannot decode, and the one we
  // have already switched off, so it is only done once per stream.
  Set<String> _undecodableSubtitleIds = const {};
  String? _disabledUndecodableSubtitleId;

  /// Marks a [SubtitleTrack] in [subtitleTracks] as a DASH TTML track rendered
  /// by Flutter rather than one libmpv can select.
  static const String _ttmlTrackIdPrefix = 'dash-ttml:';

  final List<DashSubtitleCue> _dashSubtitleCues = [];
  final Set<String> _dashSubtitleCueKeys = {};
  String? _selectedTtmlTrackId;
  // Set once the viewer picks a TTML track explicitly, so a later native track
  // discovery does not silently take it away from them.
  bool _ttmlChosenByUser = false;
  bool get subtitlesAvailable => subtitleTracks.isNotEmpty;
  Duration _rawPlaybackPosition = Duration.zero;
  String dashSubtitleText = '';
  StreamSubscription<List<DashSubtitleCue>>? _dashSubtitleSubscription;
  StreamSubscription<List<DashTtmlTrack>>? _dashTtmlTrackSubscription;

  /// The track the subtitle menu should show as active. A Flutter-rendered TTML
  /// track is not known to libmpv, so it cannot come from [selectedTrack].
  SubtitleTrack get activeSubtitleTrack {
    final ttmlId = _selectedTtmlTrackId;
    if (ttmlId == null) return selectedTrack.subtitle;
    return subtitleTracks.firstWhere(
      (track) => track.id == '$_ttmlTrackIdPrefix$ttmlId',
      orElse: () => selectedTrack.subtitle,
    );
  }

  StreamSubscription<VideoParams>? _videoParamsSubscription;
  StreamSubscription<Track>? _trackSubscription;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<PlayerLog>? _logSubscription;
  Timer? _bitrateTimer;
  Timer? _reconnectTimer;
  // Retained only so existing cancel() calls stay valid; the initial-connection
  // watchdog that used to time out a stream after 15s has been removed so slow
  // starts (proxied DASH, slow CDNs) are never killed early.
  Timer? _connectTimer;
  int _reconnectAttempts = 0;
  bool reconnecting = false;
  // mpv's raw buffering/stall state (player.stream.buffering). True while the
  // demuxer cache is draining and playback is stalled.
  bool _buffering = false;
  // True while the stream is opening (from play() until the first frame is
  // rendered) or while mpv is stalled mid-stream (buffering). Drives the
  // spinner overlay for both plain videos and DASH/MPD streams. Kept false
  // once a real load failure is recorded or during the reconnect flow (which
  // has its own freeze-frame + spinner overlay).
  bool get loading {
    if (nowPlaying == null || _failureLabel != null || reconnecting) {
      return false;
    }
    // Still opening: no frame yet.
    if (!_everPlayed) return true;
    // Started, but mpv has stalled waiting for data.
    return _buffering;
  }

  // Set true once a channel has actually started rendering. Distinguishes a
  // legitimate mid-stream segment boundary (reconnect is desirable) from a
  // stream that could never connect in the first place (reconnecting forever,
  // and screenshotting a frameless output, is what crashes the process).
  bool _everPlayed = false;
  // Times how long the current channel took from play() to its first rendered
  // frame, so the list can show that as a real ping (correcting a stale red
  // dot) once playback is confirmed. Keyed to the channel's list URL.
  Stopwatch? _startupStopwatch;
  String? _startupUrl;
  // Non-null when playback failed before it ever started; shown verbatim in the
  // control bar. 'Load error' for a hard open/demux failure. Cleared on a new
  // open, on stop, and if playback eventually starts.
  String? _failureLabel;
  // Timestamp of the most recent "[mpv:error] ytdl_hook: ..." log line.
  DateTime? _lastYtdlHookErrorAt;
  Timer? _ytdlGraceTimer;
  static const _ytdlGracePeriod = Duration(seconds: 20);

  // True once the current engine has been handed media to play (so its texture
  // may be holding a rendered frame). Reset when the engine is recreated. Used
  // to decide whether the next play() must swap engines to drop a stale frame —
  // `nowPlaying` can't be used for this because stopPlayback() clears it while
  // the old texture still shows the previous stream's last frame.
  bool _engineDirty = false;

  Uint8List? lastFrame;
  int? videoBitrate;
  double? containerFps;
  String? hwdecCurrent;
  // Last decoder written to the log, so the same one is not reported again when
  // `hwdec-current` briefly reads back empty.
  String? _loggedHwdecCurrent;
  bool _interpolationConfigured = false;
  bool _bitratePollInFlight = false;
  // Per-channel deinterlace toggle. Starts OFF for every stream and is reset
  // to OFF on each channel switch (see play()); the user turns it on manually
  // when a given channel shows combing.
  bool deinterlace = false;

  bool fullscreen = false;
  bool fullscreenChanging = false;
  bool cursorHidden = false;
  Timer? _cursorHideTimer;
  static const _cursorHideDelay = Duration(seconds: 3);

  bool isPlaying = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool _seeking = false;
  Duration _seekTarget = Duration.zero;
  double volume = 100;
  bool muted = false;
  double _volumeBeforeMute = 100;

  static const int _maxReconnectAttempts = 30;
  int playbackRequest = 0;

  bool _disposed = false;

  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;
  void _showMessage(String text) {
    if (_disposed) return;
    DebugLogService.instance.add(text, source: 'app');
    _messages.add(text);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_cancelStreamSubscriptions());
    unawaited(_dashSubtitleSubscription?.cancel());
    _dashSubtitleSubscription = null;
    unawaited(_dashTtmlTrackSubscription?.cancel());
    _dashTtmlTrackSubscription = null;
    _bitrateTimer?.cancel();
    _reconnectTimer?.cancel();
    _connectTimer?.cancel();
    _ytdlGraceTimer?.cancel();
    _cursorHideTimer?.cancel();
    playerFocusNode.dispose();
    streamUrlController.dispose();
    _dashServer.dispose();
    _av3aServer.dispose();
    final activePlayer = _player;
    _player = null;
    _videoController = null;
    if (activePlayer != null) unawaited(activePlayer.dispose());
    _messages.close();
    super.dispose();
  }

  Future<void> _cancelStreamSubscriptions() async {
    final subscriptions = <StreamSubscription<dynamic>?>[
      _videoParamsSubscription,
      _trackSubscription,
      _tracksSubscription,
      _completedSubscription,
      _playingSubscription,
      _bufferingSubscription,
      _positionSubscription,
      _durationSubscription,
      _errorSubscription,
      _logSubscription,
    ];
    _videoParamsSubscription = null;
    _trackSubscription = null;
    _tracksSubscription = null;
    _completedSubscription = null;
    _playingSubscription = null;
    _bufferingSubscription = null;
    _positionSubscription = null;
    _durationSubscription = null;
    _errorSubscription = null;
    _logSubscription = null;
    await Future.wait(
      subscriptions.whereType<StreamSubscription<dynamic>>().map((
        subscription,
      ) async {
        try {
          await subscription.cancel();
        } catch (_) {}
      }),
    );
  }

  /// Tears down the current mpv engine and builds a fresh one. Disposing the
  /// [Player] frees its native render context and unregisters the Flutter
  /// texture (see media_kit's `~VideoOutput`), which is the only reliable way to
  /// drop the last decoded frame the texture retains by design. A new engine
  /// starts with a blank texture, so switching channels no longer flashes the
  /// previous channel's final frame. The player page rebinds via
  /// [engineGeneration].
  Future<void> _recreateEngine() async {
    await _swapEngine();
    notifyListeners();
  }

  void _restoreEngine() {
    if (!_engineReleased) return;
    final engine = _createPlaybackEngine();
    player = engine.$1;
    videoController = engine.$2;
    _engineReleased = false;
    _engineDirty = false;
    _engineGeneration++;
    _listenPlaybackInfo();
  }

  /// Releases the native player without replacing it. This is used when
  /// returning home, where keeping a blank libmpv instance and Flutter texture
  /// alive serves no purpose. [play] restores an engine lazily when needed.
  Future<void> _releaseEngine() async {
    if (_engineReleased) return;
    await _cancelStreamSubscriptions();
    final old = player;
    _player = null;
    _videoController = null;
    _engineReleased = true;
    _engineDirty = false;
    _engineGeneration++;
    try {
      await old.dispose();
    } catch (_) {}
  }

  /// Disposes the current engine and installs a fresh blank one. Frees the
  /// native render context and unregisters the Flutter texture (dropping the
  /// last decoded frame the texture retains by design), then rebinds the UI via
  /// [engineGeneration]. Callers are responsible for calling notifyListeners()
  /// at an appropriate point.
  Future<void> _swapEngine() async {
    await _cancelStreamSubscriptions();
    final old = player;
    _player = null;
    _videoController = null;
    _engineReleased = true;
    try {
      await old.dispose();
    } catch (_) {}
    if (_disposed) return;
    final engine = _createPlaybackEngine();
    player = engine.$1;
    videoController = engine.$2;
    _engineReleased = false;
    _engineDirty = false;
    _engineGeneration++;
    _listenPlaybackInfo();
  }

  (Player, VideoController) _createPlaybackEngine() {
    final nextPlayer = Player(
      configuration: const PlayerConfiguration(
        title: 'Light IPTV Player',
        // Deliver mpv logs at info level. The AV3A "Could not find codec
        // parameters for stream N (... av3a ...)" line from the lavf/hls
        // demuxer — the one definitive runtime AV3A signal — is emitted below
        // `warn`, so a `warn` filter dropped it and the AV3A fallback never
        // fired (the same stream would then play silently). `info` guarantees
        // that line reaches player.stream.log; the extra chatter is filtered in
        // the log listener before it reaches the debug UI.
        logLevel: MPVLogLevel.info,
        // Let libmpv render subtitles into the video texture. Flutter's
        // SubtitleView only receives text cues, so it cannot display bitmap
        // formats such as DVB/PGS; native rendering supports both bitmap and
        // text subtitles without changing the video's layout or dimensions.
        libass: true,
        // Bound native read-ahead memory. A large value is especially costly
        // while switching channels because decoder and demuxer allocations may
        // coexist briefly until libmpv finishes releasing the old stream.
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    // Must start before the VideoController below is constructed: it races
    // against VideoOutputManager.Create (which creates the render context),
    // and mpv ignores runtime changes to gpu-hwdec-interop.
    unawaited(_configureRenderHwdecInterop(nextPlayer));
    final nextVideoController = VideoController(
      nextPlayer,
      configuration: const VideoControllerConfiguration(
        // `auto-copy` (hardware decode + readback) instead of the zero-copy
        // `auto` interop path. On Windows the zero-copy d3d11va/ANGLE interop
        // renders the decoder's alignment padding: HEVC 1920x1080 streams
        // decode into a padded surface (rows/columns rounded up to the codec
        // alignment) and the un-cropped surface reaches the shared texture,
        // which shows up as a black bar at the bottom (and left) of the video.
        // The copy path crops to the visible size during readback, fixing e.g.
        // the HLS + WebVTT HEVC channels. Zero-copy also crashed the native
        // process for some IPTV codecs/resolutions in the past.
        //
        // This stays the default for every stream. Frames too large to afford
        // the readback are switched to zero-copy at runtime instead, once their
        // real size is known — see [_applyLargeFrameTuning].
        hwdec: 'auto-copy',
        enableHardwareAcceleration: true,
      ),
    );
    return (nextPlayer, nextVideoController);
  }

  /// Loads exactly one hwdec interop into the libmpv render context: the
  /// `d3d11-egl` one that actually works on ANGLE.
  ///
  /// The libmpv render API (media_kit's video path) has no on-demand interop
  /// loading, so the default `gpu-hwdec-interop=auto` behaves like `all`: every
  /// interop is loaded eagerly when the render context is created. The
  /// `dxva2-egl` interop then fails to init on ANGLE's D3D11 backend and logs
  /// "[mpv:error] libmpv_render/dxva2-egl: Failed to create EGL surface" on
  /// every engine (re)creation, i.e. every channel switch.
  ///
  /// That noise used to be silenced with `no`, which also made zero-copy
  /// decoding impossible for every stream. Naming the single working interop
  /// keeps the log clean and still leaves `hwdec=d3d11va` available for frames
  /// too large to survive a readback (see [_applyLargeFrameTuning]).
  ///
  /// Timing is critical: mpv reads this option only once, when the render
  /// context is created inside VideoOutputManager.Create. A plain
  /// `setProperty` would `await waitForVideoControllerInitializationIfAttached`
  /// — which completes only after that render context already exists — so this
  /// waits for the raw mpv handle instead and writes the property directly.
  /// The VideoController's own create flow waits for a post-frame callback and
  /// a decoder query first, so this always lands in time.
  Future<void> _configureRenderHwdecInterop(Player target) async {
    try {
      await target.handle;
      final platform = target.platform;
      if (platform == null) return;
      // Interop names come from the libmpv build, so fall back to letting mpv
      // decide rather than leaving the property unset if this build spells it
      // differently. `auto` costs the dxva2-egl log noise but stays functional.
      for (final value in const ['d3d11-egl', 'auto']) {
        try {
          await (platform as dynamic).setProperty(
            'gpu-hwdec-interop',
            value,
            waitForInitialization: false,
          );
          debugPrint('Applied gpu-hwdec-interop=$value');
          return;
        } catch (error) {
          debugPrint('gpu-hwdec-interop=$value rejected: $error');
        }
      }
    } catch (e) {
      debugPrint('Failed to set gpu-hwdec-interop: $e');
    }
  }

  // Above this many pixels a decoded frame can no longer afford hwdec's
  // GPU->CPU readback. One 8K 10-bit frame is ~95 MiB, so 59.94 fps needs
  // ~5.6 GiB/s down plus the same again back up into the shared texture.
  // Measured with 8K HEVC Main10 on this class of GPU: ~95 fps while frames stay
  // on the GPU, collapsing to ~20 fps once the readback is added. 4K and below
  // stay on the proven copy path, so only streams that are unwatchable today
  // change behaviour.
  static const int _zeroCopyPixelThreshold = 3840 * 2160;

  // Interpolation and display-resample cost scales with pixel count. Past this
  // size they cost far more than they can return, and a container that
  // misreports a low `container-fps` (MMT/TLV among others) would otherwise
  // switch them on for an 8K stream and ruin an otherwise-smooth pipeline.
  static const int _interpolationPixelLimit = 2560 * 1440;

  // Ceiling for the texture handed to Flutter. mpv scales into it on the GPU,
  // so the stream still decodes at full resolution, but everything downstream —
  // the render pass, the DXGI shared surface, and Flutter's own per-frame
  // sampling — shrinks with the square of the ratio. An 8K frame is a 132 MiB
  // BGRA texture that no display can show and that the player pane draws into a
  // few hundred pixels; capping at 4K cuts that fourfold. It also shortens the
  // render pass that the engine-teardown deadlock in [play] races against.
  static const int _maxTextureWidth = 3840;
  static const int _maxTextureHeight = 2160;

  bool _largeFrameTuningApplied = false;

  int get _decodedPixels {
    final width = videoParams.dw ?? videoParams.w ?? 0;
    final height = videoParams.dh ?? videoParams.h ?? 0;
    return width * height;
  }

  /// Applies the tuning only very large frames need, once mpv reports the real
  /// frame size: zero-copy decoding, plus a bound on the texture size. Called
  /// for every `videoParams` update, applied at most once per open (reset in
  /// [_applyPlaybackOptions]).
  Future<void> _applyLargeFrameTuning() async {
    if (_largeFrameTuningApplied || _disposed) return;
    final width = videoParams.dw ?? videoParams.w ?? 0;
    final height = videoParams.dh ?? videoParams.h ?? 0;
    if (width <= 0 || height <= 0) return;
    if (width * height <= _zeroCopyPixelThreshold) return;
    final platform = hasPlaybackEngine ? player.platform : null;
    // Claim the one-shot only once there is something to write to, so an engine
    // swap racing the first frame does not consume it.
    if (platform == null) return;
    _largeFrameTuningApplied = true;
    await _capTextureSize(width, height);
    if (_disposed) return;
    await _enableZeroCopyHwdec(platform, '${width}x$height');
  }

  /// Pins the render surface to at most 4K, preserving the source aspect ratio
  /// so mpv does not letterbox inside the texture.
  Future<void> _capTextureSize(int width, int height) async {
    if (width <= _maxTextureWidth && height <= _maxTextureHeight) return;
    final widthRatio = _maxTextureWidth / width;
    final heightRatio = _maxTextureHeight / height;
    final scale = widthRatio < heightRatio ? widthRatio : heightRatio;
    // Even dimensions keep chroma subsampling happy.
    final cappedWidth = (width * scale).round() & ~1;
    final cappedHeight = (height * scale).round() & ~1;
    if (cappedWidth <= 0 || cappedHeight <= 0) return;
    try {
      await videoController.setSize(
        width: cappedWidth,
        height: cappedHeight,
      );
      DebugLogService.instance.add(
        'Render surface capped to ${cappedWidth}x$cappedHeight '
        'for ${width}x$height source',
        source: 'app',
      );
    } catch (error) {
      debugPrint('Failed to cap render surface: $error');
    }
  }

  Future<void> _enableZeroCopyHwdec(Object platform, String size) async {
    // A comma-separated list is walked in order by mpv, so a build or driver
    // that cannot map d3d11va into the render context falls back to the copy
    // path instead of dropping all the way to software decoding. Older builds
    // take only a single method, hence the second candidate.
    for (final value in const ['d3d11va,auto-copy', 'd3d11va']) {
      try {
        await (platform as dynamic).setProperty('hwdec', value);
        DebugLogService.instance.add(
          'Zero-copy decoding requested for $size (hwdec=$value)',
          source: 'app',
        );
        // Which method actually took effect is NOT read back here: writing
        // `hwdec` tears down and rebuilds the decoder, and `hwdec-current`
        // returns an empty string while that is in flight. The once-a-second
        // poll reports it instead, and also catches a later fallback (see
        // _pollBitrate).
        return;
      } catch (error) {
        debugPrint('hwdec=$value rejected: $error');
      }
    }
    DebugLogService.instance.add(
      'Zero-copy decoding unavailable for $size, staying on hwdec=auto-copy',
      level: DebugLogLevel.warn,
      source: 'app',
    );
  }

  void _handleDashSubtitleCues(List<DashSubtitleCue> cues) {
    if (_disposed) return;
    if (cues.isEmpty) {
      // The server flushes an empty batch when a session ends or the selected
      // TTML track changes, so the previous track's cues must not linger.
      final changed =
          dashSubtitleText.isNotEmpty || _dashSubtitleCues.isNotEmpty;
      _dashSubtitleCues.clear();
      _dashSubtitleCueKeys.clear();
      dashSubtitleText = '';
      if (changed) notifyListeners();
      return;
    }
    // Segments for a track the viewer just switched away from can still be in
    // flight; their cues belong to nothing on screen.
    if (cues.first.trackId != _selectedTtmlTrackId) return;

    for (final cue in cues) {
      final key =
          '${cue.start.inMicroseconds}|${cue.end.inMicroseconds}|'
          '${cue.text}';
      if (_dashSubtitleCueKeys.add(key)) _dashSubtitleCues.add(cue);
    }
    _dashSubtitleCues.sort((a, b) => a.start.compareTo(b.start));
    if (_dashSubtitleCues.length > 2000) {
      final removed = _dashSubtitleCues.sublist(
        0,
        _dashSubtitleCues.length - 2000,
      );
      _dashSubtitleCues.removeRange(0, removed.length);
      for (final cue in removed) {
        _dashSubtitleCueKeys.remove(
          '${cue.start.inMicroseconds}|${cue.end.inMicroseconds}|${cue.text}',
        );
      }
    }
    if (_updateDashSubtitleText(_rawPlaybackPosition)) notifyListeners();
  }

  /// The DASH pipeline publishes the TTML tracks it found once the manifest has
  /// been parsed. They are merged into [subtitleTracks] as synthetic entries so
  /// the menu offers every language, not just the one that happened to load.
  void _handleDashTtmlTracks(List<DashTtmlTrack> tracks) {
    if (_disposed) return;
    if (tracks.isNotEmpty && _dashTtmlTracks.isEmpty) {
      DebugLogService.instance.add(
        'Using Flutter TTML subtitle renderer for '
        '${tracks.length} track(s)',
        source: 'app',
      );
    }
    _dashTtmlTracks = List<DashTtmlTrack>.unmodifiable(tracks);
    _selectedTtmlTrackId = _dashServer.selectedTtmlTrackId;
    final changed = _rebuildSubtitleTracks();
    _autoSelectSubtitle();
    if (changed) notifyListeners();
  }

  void _resetDashSubtitleFallback() {
    _dashSubtitleCues.clear();
    _dashSubtitleCueKeys.clear();
    _dashTtmlTracks = const [];
    _selectedTtmlTrackId = null;
    _ttmlChosenByUser = false;
    _rawPlaybackPosition = Duration.zero;
    dashSubtitleText = '';
  }

  bool _updateDashSubtitleText(Duration at) {
    final next = _selectedTtmlTrackId == null || !subtitlesEnabled
        ? ''
        : _dashSubtitleCues
              .where((cue) => at >= cue.start && at < cue.end)
              .map((cue) => cue.text)
              .toSet()
              .join('\n');
    if (next == dashSubtitleText) return false;
    dashSubtitleText = next;
    return true;
  }

  // Subtitle codecs the bundled libmpv has no decoder for. Selecting one makes
  // mpv log "sub/ass: Could not open libavcodec subtitle converter" at fatal
  // level and then fail every subtitle packet, while never drawing anything.
  // ARIB MMT/TLV broadcasts carry their captions as TTML, so an 8K channel would
  // otherwise have its unusable track auto-selected on every open. (DASH TTML is
  // unaffected: those tracks never reach libmpv, they are parsed in Dart and
  // drawn by Flutter — see [_handleDashTtmlTracks].)
  static const Set<String> _undecodableSubtitleCodecs = {'ttml'};

  bool _isUndecodableSubtitle(SubtitleTrack track) {
    final codec = track.codec?.trim().toLowerCase();
    return codec != null && _undecodableSubtitleCodecs.contains(codec);
  }

  bool _refreshSubtitleTracks(Iterable<SubtitleTrack> tracks) {
    final real = tracks.where((track) {
      final id = track.id.toLowerCase();
      return id != 'auto' && id != 'no';
    });
    _undecodableSubtitleIds = {
      for (final track in real)
        if (_isUndecodableSubtitle(track)) track.id,
    };
    final next = real
        .where((track) => !_isUndecodableSubtitle(track))
        .toList(growable: false);
    if (!_sameTrackIds(_nativeSubtitleTracks, next)) {
      _nativeSubtitleTracks = List<SubtitleTrack>.unmodifiable(next);
    }
    final changed = _rebuildSubtitleTracks();
    _autoSelectSubtitle();
    return changed;
  }

  bool _rebuildSubtitleTracks() {
    final next = <SubtitleTrack>[
      ..._nativeSubtitleTracks,
      for (final track in _dashTtmlTracks)
        SubtitleTrack(
          '$_ttmlTrackIdPrefix${track.id}',
          track.label,
          track.language,
        ),
    ];
    if (_sameTrackIds(subtitleTracks, next)) return false;
    subtitleTracks = List<SubtitleTrack>.unmodifiable(next);
    return true;
  }

  static bool _sameTrackIds(List<SubtitleTrack> a, List<SubtitleTrack> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i].id == b[i].id);

  /// Turns on the first sensible track once one shows up. DVB subtitles embedded
  /// in MPEG-TS commonly have `default=0`, so mpv's `auto` selector leaves them
  /// off; picking the first real track keeps the app's "subtitles on for every
  /// video" behaviour deterministic.
  void _autoSelectSubtitle() {
    if (nowPlaying == null) return;
    // mpv's own default selector, and the `auto` fallback below, will happily
    // land on a track it has no decoder for. Turn it off explicitly rather than
    // leaving it selected and failing every packet.
    if (_undecodableSubtitleIds.contains(selectedTrack.subtitle.id)) {
      unawaited(_disableUndecodableSubtitle(selectedTrack.subtitle));
      return;
    }
    if (!subtitlesEnabled) return;
    if (_nativeSubtitleTracks.isEmpty) return;
    // A TTML track the viewer chose stays put. One the DASH pipeline started by
    // default gives way to a native track, since libmpv renders that itself and
    // showing both would double the text on screen.
    if (_selectedTtmlTrackId != null) {
      if (_ttmlChosenByUser) return;
      _selectDashTtmlTrack(null);
    }
    final selectedId = selectedTrack.subtitle.id.toLowerCase();
    if (selectedId.isNotEmpty && selectedId != 'auto' && selectedId != 'no') {
      return;
    }
    final first = _nativeSubtitleTracks.first;
    // Try the default once per discovered track list. mpv answering with `no`
    // must not turn the stream of track/videoParams events into a loop.
    if (_autoSelectedSubtitleId == first.id) return;
    _autoSelectedSubtitleId = first.id;
    unawaited(_selectDiscoveredSubtitle(first));
  }

  Future<void> _disableUndecodableSubtitle(SubtitleTrack track) async {
    if (_disabledUndecodableSubtitleId == track.id) return;
    _disabledUndecodableSubtitleId = track.id;
    DebugLogService.instance.add(
      'Subtitle track ${track.id} uses ${track.codec}, which this libmpv '
      'cannot decode; turning it off',
      level: DebugLogLevel.warn,
      source: 'app',
    );
    if (!hasPlaybackEngine || nowPlaying == null) return;
    try {
      await player.setSubtitleTrack(SubtitleTrack.no());
    } catch (error) {
      debugPrint('Failed to turn off undecodable subtitle: $error');
    }
  }

  /// Points the DASH pipeline at [id] (or stops TTML downloads when null) and
  /// clears whatever the previous track had drawn.
  void _selectDashTtmlTrack(String? id) {
    if (_selectedTtmlTrackId == id) return;
    _selectedTtmlTrackId = id;
    _dashServer.selectTtmlTrack(id);
    _dashSubtitleCues.clear();
    _dashSubtitleCueKeys.clear();
    dashSubtitleText = '';
  }

  static const String subtitleFontFamily = 'Microsoft JhengHei';
  static const double subtitleFontSizeAt720p = 56;

  Map<String, String> get _nativeSubtitleOptions => {
    'sub-visibility': subtitlesEnabled ? 'yes' : 'no',
    'sub-font': subtitleFontFamily,
    'sub-font-size': subtitleFontSizeAt720p.toString(),
    'sub-color': '#FFFFFFFF',
    'sub-back-color': '#00000000',
    'sub-border-color': '#FF303030',
    'sub-border-size': '1.0',
    'sub-shadow-offset': '0',
    'sub-bold': 'no',
    'sub-italic': 'no',
    'sub-use-margins': 'no',
    'sub-ass-force-margins': 'no',
    'sub-margin-x': '0',
    'sub-margin-y': '0',
    'video-margin-ratio-left': '0',
    'video-margin-ratio-right': '0',
    'video-margin-ratio-top': '0',
    'video-margin-ratio-bottom': '0',
    'sub-pos': '96',
    'sub-ass-override': 'force',
  };

  Future<void> _applyNativeSubtitleOptions() async {
    final platform = hasPlaybackEngine ? player.platform : null;
    if (platform == null) return;
    for (final option in _nativeSubtitleOptions.entries) {
      try {
        await (platform as dynamic).setProperty(option.key, option.value);
      } catch (error) {
        debugPrint('Failed to apply ${option.key}: $error');
      }
    }
  }

  Future<void> _setNativeSubtitleVisibility(bool visible) async {
    final platform = hasPlaybackEngine ? player.platform : null;
    if (platform == null) return;
    try {
      await (platform as dynamic).setProperty(
        'sub-visibility',
        visible ? 'yes' : 'no',
      );
    } catch (error) {
      debugPrint('Failed to set native subtitle visibility: $error');
    }
  }

  Future<void> _selectDiscoveredSubtitle(SubtitleTrack track) async {
    if (_pendingDefaultSubtitleId == track.id) return;
    _pendingDefaultSubtitleId = track.id;
    try {
      if (_disposed || !subtitlesEnabled || nowPlaying == null) return;
      // DVB subtitles embedded in MPEG-TS commonly have default=0, so mpv's
      // `auto` selector leaves them off. Selecting the first real track keeps
      // the app's "subtitles on for every video" behaviour deterministic.
      await _setNativeSubtitleVisibility(true);
      await player.setSubtitleTrack(track);
    } catch (error) {
      debugPrint('Failed to select discovered subtitle ${track.id}: $error');
    } finally {
      if (_pendingDefaultSubtitleId == track.id) {
        _pendingDefaultSubtitleId = null;
      }
    }
  }

  Future<void> _refreshSubtitleTracksAfterOpen(int request) async {
    // HLS manifests can omit EXT-X-MEDIA and carry DVB subtitles only inside
    // MPEG-TS segments. Poll briefly while the first segment is demuxed because
    // not every libmpv build emits another tracks event for that late discovery.
    for (final delay in const [
      Duration(milliseconds: 350),
      Duration(milliseconds: 750),
      Duration(milliseconds: 1500),
    ]) {
      await Future<void>.delayed(delay);
      if (_disposed || request != playbackRequest || nowPlaying == null) return;
      if (_refreshSubtitleTracks(player.state.tracks.subtitle)) {
        notifyListeners();
      }
    }
  }

  void _listenPlaybackInfo() {
    _videoParamsSubscription = player.stream.videoParams.listen((params) {
      if (_disposed) return;
      videoParams = params;
      // The real frame size only becomes known here, and it decides whether the
      // readback in the default copy-based hwdec path is affordable at all.
      unawaited(_applyLargeFrameTuning());
      _refreshSubtitleTracks(player.state.tracks.subtitle);
      notifyListeners();
      // Real decoded dimensions are proof the stream actually started (unlike
      // the `playing`/pause event, which fires the moment a file opens). Use it
      // to confirm playback and, on a reconnect, drop the freeze frame.
      if ((params.w ?? 0) > 0 && (params.h ?? 0) > 0) {
        _confirmPlaybackStarted();
      }
    });
    _trackSubscription = player.stream.track.listen((track) {
      if (_disposed) return;
      debugPrint(
        'Selected track changed: audio.id=${track.audio.id} audio.title=${track.audio.title} '
        'subtitle.id=${track.subtitle.id} subtitle.title=${track.subtitle.title}',
      );
      selectedTrack = track;
      _pendingDefaultSubtitleId = null;
      _refreshSubtitleTracks(player.state.tracks.subtitle);
      notifyListeners();
    });
    _tracksSubscription = player.stream.tracks.listen((tracks) {
      if (_disposed) return;
      // media_kit includes its synthetic `auto` and `no` controls in the
      // subtitle list. They are selection commands, not media tracks; exposing
      // them here made a video with zero subtitles appear to have two unnamed
      // tracks. The menu supplies Auto/Off separately, so retain only tracks
      // that actually came from the HLS manifest or media container.
      _refreshSubtitleTracks(tracks.subtitle);
      notifyListeners();
    });
    // Some IPTV streams are delivered in segments: the server closes the
    // connection at the end of each segment, which media_kit surfaces as a
    // "completed" event even though more data is available. When that happens
    // while a channel is selected, transparently reconnect and keep playing.
    _completedSubscription = player.stream.completed.listen((completed) async {
      if (!completed) return;
      if (_disposed ||
          nowPlaying == null ||
          reconnecting ||
          _av3aFallbackStarting) {
        return;
      }
      // Ignore the completed event that our own player.stop() triggers once a
      // failure has already been recorded.
      if (_failureLabel != null) return;
      // Never rendered a frame: this "completed" is a failed/aborted open, not
      // a segment boundary. Treat it as a load failure immediately.
      if (!_everPlayed) {
        // If youtube-dl just failed, mpv may still play the URL directly. Keep
        // retrying quietly during the grace period instead of failing now.
        if (_deferFailureForYtdl()) {
          debugPrint(
            'completed before first frame but ytdl_hook-only -> retrying',
          );
          reconnecting = true;
          _scheduleReconnect();
          return;
        }
        debugPrint('completed before first frame -> Load error');
        _failLoad();
        return;
      }
      reconnecting = true;
      // Fast segment-boundary reconnect: do NOT take a screenshot or rebuild
      // the Flutter overlay here. Screenshot capture is expensive and was part
      // of the visible pause at every boundary. mpv is kept open and `loadfile
      // replace` preserves the video output texture, so the last decoded frame
      // remains on screen while we immediately open the next segment/session.
      _scheduleReconnect();
    });
    // A successful resume means the previous segment boundary was crossed, so
    // clear the failure counter and drop the freeze-frame overlay.
    _playingSubscription = player.stream.playing.listen((playing) {
      if (_disposed) return;
      // This stream mirrors mpv's pause state and flips true the instant a file
      // is opened, so it only drives the transport (play/pause) UI. "Playback
      // actually started" is detected separately via decoded frames/position.
      if (isPlaying != playing) {
        isPlaying = playing;
        notifyListeners();
      }
    });
    // mpv's real buffering/stall signal. While true mid-playback the picture is
    // frozen waiting for the demuxer cache to refill, so show the spinner.
    _bufferingSubscription = player.stream.buffering.listen((buffering) {
      if (_disposed) return;
      if (_buffering != buffering) {
        _buffering = buffering;
        notifyListeners();
      }
    });
    // Created once and reused across engine recreations: it reads `player`
    // lazily each tick via _pollBitrate, so it always polls the current engine.
    _bitrateTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _pollBitrate();
    });
    _positionSubscription = player.stream.position.listen((value) {
      if (_disposed || _seeking) return;
      _rawPlaybackPosition = value;
      final subtitleChanged = _updateDashSubtitleText(value);
      // A position past zero also proves real playback (covers audio-only
      // streams that emit no video params).
      if (!_everPlayed && value > Duration.zero) _confirmPlaybackStarted();
      // The progress UI only shows whole seconds, so ignore the sub-second
      // firehose unless a Flutter-rendered TTML cue changed.
      if (value.inSeconds == position.inSeconds) {
        if (subtitleChanged) notifyListeners();
        return;
      }
      position = value;
      notifyListeners();
    });
    _durationSubscription = player.stream.duration.listen((value) {
      if (_disposed) return;
      duration = value;
      notifyListeners();
    });
    // Any hard playback error before the stream has started is treated as a
    // load failure right away. Errors after playback is underway are left to
    // the reconnect logic.
    _errorSubscription = player.stream.error.listen((error) {
      debugPrint('Player error: $error');
      if (_disposed || nowPlaying == null || _everPlayed || reconnecting) {
        return;
      }
      // A ytdl_hook failure can surface an intermediate open error while mpv is
      // still falling back to direct playback. Hold off on failing and let the
      // grace period / reconnect path resolve it.
      if (_deferFailureForYtdl()) {
        debugPrint(
          'player error before first frame but ytdl_hook-only -> defer',
        );
        return;
      }
      debugPrint('player error before first frame -> Load error');
      _failLoad();
    });
    // Raw mpv logs, printed for diagnostics only. NOTE: these "[mpv:error]"
    // lines are not treated as load failures — only genuine "Player error"
    // events (player.stream.error, handled above) are.
    _logSubscription = player.stream.log.listen((log) {
      final isRoutineLog =
          log.level == 'info' || log.level == 'v' || log.level == 'debug';
      // fMP4 HLS spam: origins that prepend the same EXT-X-MAP init section to
      // every segment make ffmpeg's mov demuxer warn once per segment while it
      // safely skips the duplicate moov, plus a "corrupted TRUN atom" line at
      // each segment-boundary EOF. Both are harmless, but at one line per
      // segment they flood the console and the debug UI. Note the `msg-level`
      // option set in _applyPlaybackOptions cannot drop these here: it only
      // filters mpv's own terminal output, while media_kit receives log
      // messages through the client API at the global `logLevel`, which has no
      // per-module filter — so they must be dropped in this listener.
      final isBenignFmp4Warning =
          log.prefix == 'ffmpeg/demuxer' &&
          (log.text.contains('Found duplicated MOOV Atom') ||
              log.text.contains('corrupted TRUN atom'));
      final level = switch (log.level) {
        'error' || 'fatal' => DebugLogLevel.error,
        'warn' => DebugLogLevel.warn,
        _ => DebugLogLevel.info,
      };
      // mpv runs at info so AV3A can be detected below, but forwarding its
      // high-frequency routine output to debugPrint builds a large throttled
      // console queue during long playback. Only retain actionable messages.
      if (!isRoutineLog && !isBenignFmp4Warning) {
        debugPrint('[mpv:${log.level}] ${log.prefix}: ${log.text}');
        DebugLogService.instance.add(
          '${log.prefix}: ${log.text}',
          level: level,
          source: 'mpv',
        );
      }
      if (log.level == 'error' && log.prefix == 'ytdl_hook') {
        _lastYtdlHookErrorAt = DateTime.now();
      }
      // The lavf/hls demuxer emits a definitive AV3A signal the moment it
      // fails to map the stream, e.g.
      //   "Could not find codec parameters for stream 1
      //    (Unknown: none (av3a / 0x61337661)): unknown codec".
      // Any log line mentioning the av3a codec in a "can't handle it" context
      // means the bundled libmpv cannot decode it, so switch straight to the
      // AV3A-to-AAC bridge instead of playing on silently.
      final logText = log.text.toLowerCase();
      // mpv's curl network layer refuses HTTPS origins whose TLS certificate
      // can't be verified (self-signed/expired/untrusted CA), printing e.g.
      // "TLS certificate verification failed" / "SSL peer certificate ... was
      // not OK". Keep verification on by default, but the first time a stream
      // hits this, disable it just for that stream and reconnect so mpv reopens
      // the URL with tls-verify=no. Ignored once already disabled or for the
      // local loopback converters (which never present remote certs).
      final isTlsVerifyFailure =
          logText.contains('certificate verification failed') ||
          logText.contains('peer certificate') ||
          logText.contains('tls-verify=no');
      if (!_tlsVerifyDisabled &&
          !_tlsFallbackStarting &&
          nowPlaying != null &&
          isTlsVerifyFailure) {
        unawaited(_activateTlsVerifyFallback());
      }
      final namesAv3a =
          logText.contains('av3a') &&
          (logText.contains('unknown') ||
              logText.contains('could not find codec parameters') ||
              logText.contains('unknown codec') ||
              logText.contains('no decoder'));
      // A sustained run of "ad: Error decoding audio." is the other AV3A
      // symptom: mpv recognized the codec but has no decoder, so it just fails
      // every audio packet without ever naming av3a. A lone transient glitch on
      // a normal stream is ignored via the streak threshold.
      final isAudioDecodeError =
          log.prefix == 'ad' && logText.contains('error decoding audio');
      _audioDecodeErrorStreak = isAudioDecodeError
          ? _audioDecodeErrorStreak + 1
          : 0;
      final failedAudioDecode =
          _audioDecodeErrorStreak >= _av3aDecodeErrorThreshold;
      if (!_activeIsAv3a &&
          !_av3aFallbackStarting &&
          (namesAv3a || failedAudioDecode)) {
        unawaited(_activateAv3aFallback());
      }
    });
  }

  // Reopen the current stream with mpv's `tls-verify=no` after a TLS
  // certificate verification failure. Marks the stream so _applyPlaybackOptions
  // disables verification, then reconnects (which re-applies options and issues
  // `loadfile replace`). Kept per-stream: play() resets the flag so a healthy
  // channel always starts with verification back on.
  Future<void> _activateTlsVerifyFallback() async {
    if (_disposed || nowPlaying == null || _tlsVerifyDisabled) return;
    _tlsFallbackStarting = true;
    _tlsVerifyDisabled = true;
    DebugLogService.instance.add(
      'TLS certificate verification failed; retrying with tls-verify=no',
      level: DebugLogLevel.warn,
      source: 'app',
    );
    try {
      // Force the options+reload path even if a frame was already rendered:
      // treat this as a fresh open so the reconnect actually reopens the URL
      // with the relaxed setting rather than being skipped.
      _everPlayed = false;
      reconnecting = true;
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _scheduleReconnect();
    } finally {
      _tlsFallbackStarting = false;
    }
  }

  Future<void> _activateAv3aFallback() async {
    final channel = nowPlaying;
    if (_disposed ||
        channel == null ||
        _activeIsAv3a ||
        _av3aFallbackStarting) {
      return;
    }
    final request = playbackRequest;
    final source = _activeStreamUrl.isNotEmpty ? _activeStreamUrl : channel.url;
    final proxyUrl = _proxyForActiveStream();
    _av3aFallbackStarting = true;
    _audioDecodeErrorStreak = 0;
    debugPrint('AV3A detected by libmpv; switching to the Audio Vivid decoder');
    DebugLogService.instance.add(
      'AV3A detected by libmpv; switching to the Audio Vivid decoder',
      source: 'app',
    );
    try {
      final bridgeUrl = await _av3aServer.start(
        source,
        proxyUrl: proxyUrl.isEmpty ? null : proxyUrl,
      );
      if (_disposed || request != playbackRequest || nowPlaying == null) {
        await _av3aServer.stop();
        return;
      }
      _activeStreamUrl = bridgeUrl;
      _activeIsHls = false;
      _activeIsAv3a = true;
      // The direct stream already rendered video, so `_everPlayed` is true.
      // Reopening through the bridge is effectively a fresh open: treat it as
      // one so the brief gap before the bridge's first packet is seen as a
      // startup, not a mid-stream stall that trips a reconnect to the (now
      // stale) direct URL. Reconnect bookkeeping is reset for the same reason.
      _everPlayed = false;
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      await _applyPlaybackOptions(isAv3a: true, isMmtTlv: _activeIsMmtTlv);
      if (_disposed || request != playbackRequest) return;
      await player.open(Media(bridgeUrl));
      _engineDirty = true;
      await _applyVolumeToEngine();
    } catch (error) {
      DebugLogService.instance.add(
        'Failed to activate AV3A decoder: $error',
        level: DebugLogLevel.error,
        source: 'app',
      );
    } finally {
      if (request == playbackRequest) _av3aFallbackStarting = false;
    }
  }

  // Drop the current freeze frame and evict its decoded bitmap from the global
  // image cache. Image.memory keys the cache by the byte buffer, so without an
  // explicit evict each captured frame stays resident for the life of the app.
  void _clearFreezeFrame() {
    final frame = lastFrame;
    if (frame == null) return;
    PaintingBinding.instance.imageCache.evict(MemoryImage(frame));
    lastFrame = null;
  }

  // Dropped-frame counters as of the last report, and when that report was
  // made. Rate-limited because these only matter as a trend.
  int _reportedDecoderDrops = 0;
  int _reportedOutputDrops = 0;
  DateTime? _lastDropReport;
  static const Duration _dropReportInterval = Duration(seconds: 5);

  void _resetFrameDropReporting() {
    _reportedDecoderDrops = 0;
    _reportedOutputDrops = 0;
    _lastDropReport = null;
  }

  /// Logs how many frames are being lost, and where. Silent while nothing is
  /// dropping, so a healthy stream produces no output at all.
  void _reportFrameDrops(int decoderDrops, int outputDrops) {
    if (decoderDrops == _reportedDecoderDrops &&
        outputDrops == _reportedOutputDrops) {
      return;
    }
    final now = DateTime.now();
    final last = _lastDropReport;
    if (last != null && now.difference(last) < _dropReportInterval) return;
    final decoderDelta = decoderDrops - _reportedDecoderDrops;
    final outputDelta = outputDrops - _reportedOutputDrops;
    final elapsed = last == null
        ? _dropReportInterval
        : now.difference(last);
    _reportedDecoderDrops = decoderDrops;
    _reportedOutputDrops = outputDrops;
    _lastDropReport = now;
    if (decoderDelta <= 0 && outputDelta <= 0) return;
    final perSecond = (decoderDelta + outputDelta) / elapsed.inMilliseconds
        * 1000;
    DebugLogService.instance.add(
      'Dropping ${perSecond.toStringAsFixed(1)} frames/s '
      '(decoder +$decoderDelta, output +$outputDelta; '
      'totals $decoderDrops / $outputDrops)',
      level: DebugLogLevel.warn,
      source: 'app',
    );
  }

  Future<void> _pollBitrate() async {
    if (_bitratePollInFlight ||
        _disposed ||
        _engineReleased ||
        nowPlaying == null ||
        _failureLabel != null) {
      return;
    }
    final polledPlayer = player;
    final generation = _engineGeneration;
    final platform = polledPlayer.platform;
    if (platform == null) return;
    _bitratePollInFlight = true;
    try {
      final bitrateValue =
          await (platform as dynamic).getProperty('video-bitrate') as String?;
      final fpsValue =
          await (platform as dynamic).getProperty('container-fps') as String?;
      final hwdecValue =
          await (platform as dynamic).getProperty('hwdec-current') as String?;
      // Frames lost before they ever reached the screen. `decoder-frame-drop-count`
      // counts pictures the decoder itself threw away (corrupt or undecodable
      // input); `frame-drop-count` counts frames the output stage dropped for
      // being late. Together they separate a broken bitstream from a pipeline
      // that simply cannot keep up.
      final decoderDropsValue =
          await (platform as dynamic).getProperty('decoder-frame-drop-count')
              as String?;
      final outputDropsValue =
          await (platform as dynamic).getProperty('frame-drop-count')
              as String?;
      if (_disposed ||
          generation != _engineGeneration ||
          !identical(polledPlayer, _player)) {
        return;
      }
      final parsedBitrate = bitrateValue == null
          ? null
          : int.tryParse(bitrateValue);
      final parsedFps = fpsValue == null ? null : double.tryParse(fpsValue);
      videoBitrate = parsedBitrate;
      containerFps = parsedFps;
      // Report the decoder actually in use whenever it changes. This is the
      // only reliable place to observe it: `hwdec-current` reads back empty
      // while a decoder reinit is in flight, so the write in
      // _applyLargeFrameTuning cannot confirm its own result. Logging every
      // transition also surfaces a fallback that happens later in a stream.
      // Compared against the last *logged* value, not against `hwdecCurrent`:
      // the property reads back empty while a decoder reinit is in flight, and
      // comparing against the stored value would re-log the same decoder every
      // time it flapped through empty.
      if (hwdecValue != null &&
          hwdecValue.isNotEmpty &&
          hwdecValue != _loggedHwdecCurrent) {
        _loggedHwdecCurrent = hwdecValue;
        final resolution = _decodedPixels > 0
            ? ' at ${videoParams.dw ?? videoParams.w}x'
                  '${videoParams.dh ?? videoParams.h}'
            : '';
        final message = 'Decoder: hwdec-current=$hwdecValue$resolution';
        debugPrint(message);
        DebugLogService.instance.add(message, source: 'app');
      }
      hwdecCurrent = hwdecValue;
      _reportFrameDrops(
        int.tryParse(decoderDropsValue ?? '') ?? 0,
        int.tryParse(outputDropsValue ?? '') ?? 0,
      );
      notifyListeners();
      // Once mpv reports the real source frame rate, decide interpolation
      // automatically (one time per stream).
      if (!_interpolationConfigured && parsedFps != null && parsedFps > 0) {
        _interpolationConfigured = true;
        await _applyInterpolationForFps(parsedFps);
      }
    } catch (_) {
    } finally {
      _bitratePollInFlight = false;
    }
  }

  // Sniffs a stream before it is handed to mpv, fetching a small prefix with a
  // short timeout so a healthy stream isn't delayed much. On any uncertainty it
  // returns a permissive result so a flaky probe never blocks a good channel.
  //   nativeSafe is false only for MPEG-DASH, which the bundled libmpv's ffmpeg
  //     can segfault on (a native crash we can't catch).
  //   mediaUrl is the URL mpv should actually open: normally the origin URL,
  //     but when the origin body is a plaintext M3U wrapper (a tiny text file
  //     that just lists the real stream URL, not an HLS manifest) it is the
  //     unwrapped inner URL, so mpv opens the media directly instead of running
  //     its plaintext-playlist reader against a non-seekable live stream (which
  //     floods the log with curl backward-seek errors and stalls playback).
  //   isAv3a is true when the manifest, MP4 sample entry, raw extension, or
  //     MPEG-TS PMT identifies AVS3-P3 / Audio Vivid audio.
  //   isHls is true for a real HLS manifest, so the caller can force mpv's
  //     lavf/HLS demuxer instead of letting mpv misdetect it as a plaintext
  //     playlist.
  Future<
    ({
      bool nativeSafe,
      bool isHls,
      bool isAv3a,
      bool isMmtTlv,
      String? mediaUrl,
    })
  >
  _probeStream(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return (
        nativeSafe: true,
        isHls: false,
        isAv3a: url.toLowerCase().endsWith('.av3a'),
        isMmtTlv: isMmtTlvSource(url),
        mediaUrl: null,
      );
    }
    final client = http.Client();
    try {
      // Pull a larger prefix than a single TS PMT interval. 8 KiB frequently
      // fell inside a live sliding window that had not yet emitted the PMT
      // (stream_type 0xD5) or the manifest CODECS tag, so AV3A detection was a
      // coin flip and the same stream would sometimes bypass the bridge. 64 KiB
      // reliably spans several PMT repetitions and full media manifests.
      const probeBytes = 64 * 1024;
      final request = http.Request('GET', uri)
        ..followRedirects = true
        ..headers['User-Agent'] = UserAgentService.resolve('Mozilla/5.0')
        ..headers['Range'] = 'bytes=0-${probeBytes - 1}';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 6));
      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        final remaining = probeBytes - bytes.length;
        bytes.addAll(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
        if (bytes.length >= probeBytes) break;
      }
      // Decode the whole prefix as text (malformed bytes tolerated). The HLS /
      // plaintext-playlist checks below only look at the leading line, but the
      // AV3A CODECS tag can sit deep inside a large master manifest, so the
      // text signalling scan needs the full prefix.
      final head = utf8.decode(bytes, allowMalformed: true);
      final isAv3a = looksLikeAv3a(url, bytes, head);
      final looksDash =
          contentType.contains('dash+xml') ||
          head.contains('<MPD') ||
          head.contains('urn:mpeg:dash');
      if (looksDash) {
        return (
          nativeSafe: false,
          isHls: false,
          isAv3a: isAv3a,
          isMmtTlv: false,
          mediaUrl: null,
        );
      }
      // A real HLS manifest: #EXTM3U plus at least one #EXT-X- tag, or an
      // mpegurl content type. These must be opened by mpv's HLS/lavf demuxer,
      // NOT unwrapped and NOT read by mpv's dumb plaintext-playlist reader
      // (which plays segments one-by-one and floods the log with curl
      // backward-seek errors on a live sliding-window stream).
      final trimmed = head.trimLeft();
      final hasHlsTags =
          trimmed.startsWith('#EXTM3U') && head.contains('#EXT-X-');
      // A Content-Type ending in mpegurl is not sufficient: many providers
      // serve a one-line M3U redirect with that same type. Resolve that wrapper
      // first so both libmpv and the AV3A fallback receive the actual HLS URL.
      if (trimmed.startsWith('#EXTM3U') && !hasHlsTags) {
        return (
          nativeSafe: true,
          isHls: false,
          isAv3a: isAv3a,
          isMmtTlv: false,
          mediaUrl: _unwrapPlaintextPlaylist(head, uri),
        );
      }
      final isHls =
          hasHlsTags ||
          contentType.contains('mpegurl') ||
          contentType.contains('vnd.apple.mpegurl');
      if (isHls) {
        // An HLS manifest lists segment URLs but almost never carries the AV3A
        // signal itself (no CODECS attribute on these services), so the prefix
        // scan above can't see it — mpv then opens the stream, silently fails
        // to decode AV3A, and prints the codec warning only to its own terminal
        // (it never reaches player.stream.log). Resolve the manifest down to
        // its first media segment and scan THAT for the AV3A PMT / fourcc so we
        // pick the decoder bridge before mpv ever opens the stream.
        final segmentAv3a =
            isAv3a || await _hlsSegmentIsAv3a(head, uri, client);
        return (
          nativeSafe: true,
          isHls: true,
          isAv3a: segmentAv3a,
          isMmtTlv: false,
          mediaUrl: null,
        );
      }
      return (
        nativeSafe: true,
        isHls: false,
        isAv3a: isAv3a,
        isMmtTlv:
            isMmtTlvSource(url) ||
            isMmtTlvContentType(contentType) ||
            looksLikeMmtTlv(bytes),
        mediaUrl: _unwrapPlaintextPlaylist(head, uri),
      );
    } finally {
      client.close();
    }
  }

  // Resolves an HLS manifest down to its first media segment and scans that
  // segment's bytes for the AV3A signal (MPEG-TS PMT stream_type 0xD5 or the
  // 'av3a' fourcc in an fMP4 sample entry). The AV3A codec is carried in the
  // media, not the manifest text, so this is the only reliable way to know
  // before handing the stream to mpv. Follows one level of master -> media
  // playlist. Best-effort: any failure returns false so a healthy channel is
  // never blocked.
  Future<bool> _hlsSegmentIsAv3a(
    String manifest,
    Uri manifestUri,
    http.Client client,
  ) async {
    try {
      var playlist = manifest;
      var baseUri = manifestUri;
      // If this is a master playlist (variant streams, no segments), descend
      // into the first variant's media playlist first.
      final firstVariant = _firstHlsUri(playlist, baseUri, wantVariant: true);
      if (firstVariant != null) {
        final variantBody = await _fetchText(firstVariant, client);
        if (variantBody != null) {
          playlist = variantBody;
          baseUri = firstVariant;
        }
      }
      // An fMP4 variant declares its init segment via #EXT-X-MAP:URI="...";
      // that box carries the sample-entry fourcc. Prefer it, else the first
      // media segment.
      final mapUri = _hlsMapUri(playlist, baseUri);
      final segmentUri =
          mapUri ?? _firstHlsUri(playlist, baseUri, wantVariant: false);
      if (segmentUri == null) return false;
      final bytes = await _fetchBytes(segmentUri, client, 64 * 1024);
      if (bytes == null || bytes.isEmpty) return false;
      final text = utf8.decode(bytes, allowMalformed: true);
      return looksLikeAv3a(segmentUri.toString(), bytes, text);
    } catch (_) {
      return false;
    }
  }

  // First URI in an HLS playlist. When [wantVariant] is true, returns the first
  // #EXT-X-STREAM-INF variant URI (a nested playlist); otherwise the first
  // media segment URI (the first non-comment line, which follows #EXTINF).
  Uri? _firstHlsUri(String playlist, Uri base, {required bool wantVariant}) {
    final lines = const LineSplitter().convert(playlist);
    var previousWasStreamInf = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        previousWasStreamInf = line.startsWith('#EXT-X-STREAM-INF');
        continue;
      }
      // A bare URI line. For variants it must follow #EXT-X-STREAM-INF; for
      // media segments any bare line is one.
      if (wantVariant && !previousWasStreamInf) {
        previousWasStreamInf = false;
        continue;
      }
      final resolved = base.resolve(line);
      if (resolved.isScheme('http') || resolved.isScheme('https')) {
        return resolved;
      }
      previousWasStreamInf = false;
    }
    return null;
  }

  // The #EXT-X-MAP:URI="..." init-segment URI, if present (fMP4 variants).
  Uri? _hlsMapUri(String playlist, Uri base) {
    final match = RegExp(
      r'#EXT-X-MAP:[^\n]*URI="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(playlist);
    if (match == null) return null;
    final resolved = base.resolve(match.group(1)!);
    return (resolved.isScheme('http') || resolved.isScheme('https'))
        ? resolved
        : null;
  }

  Future<String?> _fetchText(Uri uri, http.Client client) async {
    final bytes = await _fetchBytes(uri, client, 256 * 1024);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  Future<List<int>?> _fetchBytes(Uri uri, http.Client client, int cap) async {
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = true
        ..headers['User-Agent'] = UserAgentService.resolve('Mozilla/5.0')
        ..headers['Range'] = 'bytes=0-${cap - 1}';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 6));
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        final remaining = cap - bytes.length;
        bytes.addAll(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
        if (bytes.length >= cap) break;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  // If [head] is a plaintext M3U wrapper (an #EXTM3U/#EXTINF file whose only
  // real content is a single stream URL), returns that inner URL resolved
  // against [base]. Returns null for a genuine HLS manifest (any #EXT-X- tag)
  // so mpv opens those itself and its HLS demuxer runs, and for anything that
  // isn't a plaintext playlist at all.
  String? _unwrapPlaintextPlaylist(String head, Uri base) {
    if (!head.trimLeft().startsWith('#EXTM3U')) return null;
    if (head.contains('#EXT-X-')) return null;
    for (final raw in const LineSplitter().convert(head)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final resolved = base.resolve(line);
      if (resolved.isScheme('http') ||
          resolved.isScheme('https') ||
          resolved.isScheme('rtsp') ||
          resolved.isScheme('rtmp')) {
        return resolved.toString();
      }
      return null;
    }
    return null;
  }

  Future<void> setSubtitlesEnabled(bool enabled) async {
    subtitlesEnabled = enabled;
    _pendingDefaultSubtitleId = null;
    _updateDashSubtitleText(_rawPlaybackPosition);
    notifyListeners();
    if (!hasPlaybackEngine || nowPlaying == null) return;
    try {
      if (!enabled) {
        await player.setSubtitleTrack(SubtitleTrack.no());
        await _setNativeSubtitleVisibility(false);
        return;
      }
      await _setNativeSubtitleVisibility(true);
      // A Flutter-rendered TTML track is restored by _updateDashSubtitleText
      // above; libmpv must stay silent so the two do not stack up.
      await player.setSubtitleTrack(
        _selectedTtmlTrackId != null
            ? SubtitleTrack.no()
            : _nativeSubtitleTracks.isNotEmpty
            ? _nativeSubtitleTracks.first
            // `auto` lets mpv pick, which includes tracks it cannot decode. If
            // the only ones on offer are undecodable, leave subtitles off.
            : _undecodableSubtitleIds.isNotEmpty
            ? SubtitleTrack.no()
            : SubtitleTrack.auto(),
      );
    } catch (error) {
      debugPrint(
        'Failed to ${enabled ? 'enable' : 'disable'} subtitles: $error',
      );
      _showMessage('Subtitle error');
    }
  }

  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    subtitlesEnabled = true;
    _pendingDefaultSubtitleId = null;
    final ttmlId = track.id.startsWith(_ttmlTrackIdPrefix)
        ? track.id.substring(_ttmlTrackIdPrefix.length)
        : null;
    _ttmlChosenByUser = ttmlId != null;
    _selectDashTtmlTrack(ttmlId);
    _updateDashSubtitleText(_rawPlaybackPosition);
    notifyListeners();
    if (!hasPlaybackEngine || nowPlaying == null) return;
    try {
      if (ttmlId != null) {
        // Flutter draws this one, so make sure libmpv is not showing another.
        await player.setSubtitleTrack(SubtitleTrack.no());
        return;
      }
      await _setNativeSubtitleVisibility(true);
      await player.setSubtitleTrack(track);
    } catch (error) {
      debugPrint('Failed to select subtitle track ${track.id}: $error');
      _showMessage('Subtitle error');
    }
  }

  Future<void> play(Channel channel) async {
    final request = ++playbackRequest;
    // Returning home fully releases libmpv. Recreate it only when the user
    // actually starts another channel, not merely when a source page opens.
    _restoreEngine();
    // A dirty engine has already painted a frame that its texture would
    // otherwise retain across a channel switch. Rebuild the engine so the stale
    // frame is truly released; a pristine engine (first play, or one freshly
    // recreated by stopPlayback) is still blank, so reuse it.
    final needsEngineSwap = _engineDirty;
    _reconnectTimer?.cancel();
    _connectTimer?.cancel();
    reconnecting = false;
    _reconnectAttempts = 0;
    _av3aFallbackStarting = false;
    _audioDecodeErrorStreak = 0;
    _tlsVerifyDisabled = false;
    _tlsFallbackStarting = false;
    _everPlayed = false;
    _buffering = false;
    _startupStopwatch = Stopwatch()..start();
    _startupUrl = channel.url;
    _failureLabel = null;
    _lastYtdlHookErrorAt = null;
    _ytdlGraceTimer?.cancel();
    _ytdlGraceTimer = null;
    // Deinterlace is a per-channel, opt-in toggle: reset it OFF on every
    // channel switch so a new stream always starts un-deinterlaced. The mpv
    // `vf` filter is cleared alongside it in _applyPlaybackOptions.
    deinterlace = false;
    _clearFreezeFrame();
    streamUrlController.text = channel.url;
    debugPrint('Playing: ${channel.name} - ${channel.url}');
    debugPrint(
      '  channel drm: manifestType=${channel.manifestType} '
      'licenseType=${channel.licenseType} '
      'licenseKey=${channel.licenseKey} '
      'isDash=${channel.isDash} clearKeys=${channel.clearKeys.length} '
      'isEncryptedDash=${channel.isEncryptedDash}',
    );
    nowPlaying = channel;
    videoParams = const VideoParams();
    _loggedHwdecCurrent = null;
    selectedTrack = const Track();
    subtitlesEnabled = true;
    subtitleTracks = const [];
    _nativeSubtitleTracks = const [];
    _pendingDefaultSubtitleId = null;
    _autoSelectedSubtitleId = null;
    _undecodableSubtitleIds = const {};
    _disabledUndecodableSubtitleId = null;
    _resetFrameDropReporting();
    _resetDashSubtitleFallback();
    position = Duration.zero;
    duration = Duration.zero;
    _seeking = false;
    notifyListeners();
    DebugLogService.instance.add(
      'Play: ${channel.name} — ${channel.url}',
      source: 'app',
    );
    if (needsEngineSwap) {
      // Quiesce the render loop before tearing the engine down. media_kit's
      // VideoOutput destructor blocks the platform thread until the raster
      // thread runs its texture-unregister callback, and that callback contends
      // for the same mutex as an in-flight Render(). A render pass over a
      // 7680x4320 FBO is slow enough to lose that race, which deadlocks the
      // platform thread and freezes the whole app. Unloading the file first
      // stops new frames from being produced, so nothing is mid-render.
      try {
        await player.stop();
      } catch (error) {
        debugPrint('Stop before engine swap failed: $error');
      }
      if (_disposed || request != playbackRequest) return;
      await _recreateEngine();
    } else {
      await player.stop();
    }
    if (_disposed || request != playbackRequest) return;
    // Stop the AV3A converter left by the previous channel before preparing
    // this one. MMT/TLV is decoded directly by the bundled libmpv.
    await _av3aServer.stop();
    if (_disposed || request != playbackRequest) return;

    // ClearKey-protected MPEG-DASH: libmpv can't decrypt CENC, so route the
    // stream through the local exo_driven engine which parses the MPD, picks a
    // video + audio Representation, downloads/decrypts (AES-128-CTR) segments
    // and muxes them into a single clear fMP4. mpv then plays that local
    // stream. Plain streams keep using their origin URL directly.
    var streamUrl = channel.url;
    if (channel.isEncryptedDash) {
      try {
        streamUrl = await _dashServer.start(
          channel.url,
          channel.clearKeys,
          followLiveEdge: true,
        );
        debugPrint('DASH engine started: $streamUrl');
        DebugLogService.instance.add(
          'ClearKey DASH engine started',
          source: 'app',
        );
      } catch (error) {
        debugPrint('DASH engine failed to start: $error');
        DebugLogService.instance.add(
          'DASH engine failed to start: $error',
          level: DebugLogLevel.error,
          source: 'app',
        );
        if (_disposed || request != playbackRequest) return;
        _failureLabel = 'Load error';
        notifyListeners();
        return;
      }
    } else {
      await _dashServer.stop();
    }
    if (_disposed || request != playbackRequest) return;

    // The bundled libmpv's ffmpeg segfaults the whole process on some
    // MPEG-DASH manifests (a native crash we can't catch). Sniff the response
    // first: if it's DASH, don't hand it to mpv. The same probe also unwraps a
    // plaintext M3U wrapper to its inner media URL so mpv never runs its
    // playlist reader against a non-seekable live stream. Best-effort; a probe
    // failure falls through to a normal open so healthy streams are never
    // blocked.
    //
    // Skip the guard for streams we deliberately open: DASH declared via
    // #KODIPROP (played through the ClearKey proxy) and the proxy's own local
    // manifest.
    var nativeSafe = true;
    var isHls = false;
    var isAv3a = false;
    var isMmtTlv =
        isMmtTlvSource(channel.url) ||
        const {
          'mmt',
          'mmts',
          'tlv',
        }.contains((channel.manifestType ?? '').toLowerCase());
    if (!channel.isDash && !channel.isEncryptedDash) {
      try {
        final probe = await _probeStream(channel.url);
        nativeSafe = probe.nativeSafe;
        isHls = probe.isHls;
        isAv3a = probe.isAv3a;
        isMmtTlv = isMmtTlv || probe.isMmtTlv;
        if (probe.mediaUrl != null && probe.mediaUrl != streamUrl) {
          debugPrint('Unwrapped plaintext playlist -> ${probe.mediaUrl}');
          DebugLogService.instance.add(
            'Unwrapped playlist wrapper to inner stream URL',
            source: 'app',
          );
          streamUrl = probe.mediaUrl!;
          isMmtTlv = isMmtTlv || isMmtTlvSource(streamUrl);
        }
      } catch (_) {}
    }
    if (_disposed || request != playbackRequest) return;
    if (!nativeSafe) {
      _failureLabel = 'Load error';
      notifyListeners();
      try {
        await player.stop();
      } catch (_) {}
      return;
    }

    if (isMmtTlv) {
      DebugLogService.instance.add(
        'Using native libmpv MMT/TLV demuxer',
        source: 'app',
      );
    }

    if (isAv3a) {
      try {
        streamUrl = await _av3aServer.start(
          streamUrl,
          proxyUrl: ProxyService.mpvProxyUrl(),
        );
        isHls = false;
        DebugLogService.instance.add(
          'AV3A Audio Vivid transcoder started',
          source: 'app',
        );
      } catch (error) {
        DebugLogService.instance.add(
          'AV3A transcoder failed to start: $error',
          level: DebugLogLevel.error,
          source: 'app',
        );
        if (_disposed || request != playbackRequest) return;
        _failureLabel = 'Load error';
        notifyListeners();
        return;
      }
    }

    _activeStreamUrl = streamUrl;
    _activeIsHls = isHls;
    _activeIsAv3a = isAv3a;
    _activeIsMmtTlv = isMmtTlv;
    await _applyPlaybackOptions(
      isHls: isHls,
      isAv3a: isAv3a,
      isMmtTlv: isMmtTlv,
    );
    if (_disposed || request != playbackRequest) return;
    await player.open(Media(streamUrl));
    if (_disposed || request != playbackRequest) return;
    // mpv resets several subtitle/video margin properties when loading a new
    // file. Re-apply them after open so the decoded frame fills the texture and
    // text subtitles stay over the active picture instead of a bottom strip.
    await _applyNativeSubtitleOptions();
    if (_disposed || request != playbackRequest) return;
    // Explicitly restore automatic subtitle selection for every channel. This
    // covers default HLS WebVTT renditions as well as default/forced embedded
    // subtitle tracks, even if subtitles were switched off on the last video.
    try {
      await player.setSubtitleTrack(SubtitleTrack.auto());
    } catch (error) {
      debugPrint('Failed to auto-select subtitles: $error');
    }
    if (_refreshSubtitleTracks(player.state.tracks.subtitle)) {
      notifyListeners();
    }
    unawaited(_refreshSubtitleTracksAfterOpen(request));
    _engineDirty = true;
    // A recreated engine starts at mpv's default volume (100, unmuted), so the
    // controller's current volume/mute state must be pushed back onto it —
    // otherwise switching channels while muted would silently play at full
    // volume even though the UI still shows muted.
    await _applyVolumeToEngine();
    _connectTimer?.cancel();
  }

  bool _deferFailureForYtdl() {
    if (_everPlayed || _failureLabel != null || nowPlaying == null) {
      return false;
    }
    final at = _lastYtdlHookErrorAt;
    if (at == null || DateTime.now().difference(at) > _ytdlGracePeriod) {
      return false;
    }
    _ytdlGraceTimer ??= Timer(_ytdlGracePeriod, () {
      _ytdlGraceTimer = null;
      if (_disposed || _everPlayed || _failureLabel != null) return;
      debugPrint('ytdl_hook grace period elapsed -> Load error');
      _failLoad();
    });
    return true;
  }

  void _confirmPlaybackStarted() {
    _everPlayed = true;
    _reconnectAttempts = 0;
    _connectTimer?.cancel();
    _connectTimer = null;
    _ytdlGraceTimer?.cancel();
    _ytdlGraceTimer = null;
    // First frame reached: turn the elapsed startup time into a real ping so
    // the channel list replaces any stale "unreachable" red dot with a value.
    final stopwatch = _startupStopwatch;
    final url = _startupUrl;
    if (stopwatch != null && url != null) {
      stopwatch.stop();
      PingService.markReachable(url, stopwatch.elapsedMilliseconds);
      _startupStopwatch = null;
      _startupUrl = null;
    }
    final needsRebuild = _failureLabel != null || reconnecting;
    _failureLabel = null;
    if (reconnecting) {
      reconnecting = false;
      _clearFreezeFrame();
    }
    if (needsRebuild && !_disposed) notifyListeners();
  }

  void _failLoad() {
    if (_disposed ||
        nowPlaying == null ||
        _everPlayed ||
        _failureLabel != null) {
      return;
    }
    _connectTimer?.cancel();
    _connectTimer = null;
    _ytdlGraceTimer?.cancel();
    _ytdlGraceTimer = null;
    _failureLabel = 'Load error';
    notifyListeners();
    unawaited(player.stop().catchError((_) {}));
  }

  void _scheduleReconnect() {
    // reconnecting is set true by the caller; only guard channel/attempt limits.
    if (nowPlaying == null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('Reconnect: giving up after $_reconnectAttempts attempts');
      DebugLogService.instance.add(
        'Reconnect: gave up after $_reconnectAttempts attempts',
        level: DebugLogLevel.error,
        source: 'app',
      );
      if (!_disposed) {
        reconnecting = false;
        notifyListeners();
      }
      return;
    }
    _reconnectAttempts++;
    final request = playbackRequest;
    final delay = _reconnectAttempts <= 1
        ? Duration.zero
        : Duration(seconds: _reconnectAttempts.clamp(1, 5));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectStream(request);
    });
  }

  Future<void> _reconnectStream(int request) async {
    final channel = nowPlaying;
    if (_disposed || channel == null || request != playbackRequest) {
      reconnecting = false;
      return;
    }
    final reloadUrl = _activeStreamUrl.isNotEmpty
        ? _activeStreamUrl
        : channel.url;
    debugPrint('Reconnecting stream (attempt $_reconnectAttempts): $reloadUrl');
    DebugLogService.instance.add(
      'Reconnecting (attempt $_reconnectAttempts)',
      level: DebugLogLevel.warn,
      source: 'app',
    );
    try {
      // Re-apply options on any attempt after the first, and always when a TLS
      // fallback is pending so the reopen actually carries tls-verify=no even
      // on the first (zero-delay) retry.
      if (_reconnectAttempts > 1 || _tlsVerifyDisabled) {
        await _applyPlaybackOptions(
          isHls: _activeIsHls,
          isAv3a: _activeIsAv3a,
          isMmtTlv: _activeIsMmtTlv,
        );
        if (_disposed || request != playbackRequest) return;
      }
      final platform = player.platform;
      var replaced = false;
      if (platform != null) {
        try {
          final nativePlatform = platform as dynamic;
          await nativePlatform.command(['loadfile', reloadUrl, 'replace']);
          // A raw loadfile bypasses media_kit's completed-state bookkeeping.
          // Calling Player.play() here makes media_kit replay a completed item
          // by seeking to zero, which fails for the non-seekable local DASH
          // stream. Unpause mpv directly so no synthetic seek is issued.
          await nativePlatform.setProperty('pause', 'no');
          replaced = true;
        } catch (e) {
          debugPrint('loadfile replace failed, falling back to open: $e');
        }
      }
      if (!replaced) {
        if (_disposed || request != playbackRequest) return;
        await player.open(Media(reloadUrl));
      }
      if (_disposed || request != playbackRequest) return;
      await _applyNativeSubtitleOptions();
    } catch (error) {
      debugPrint('Reconnect failed: $error');
      if (!_disposed && request == playbackRequest) {
        _scheduleReconnect();
      }
    }
  }

  Future<void> stopPlayback({bool releaseEngine = false}) async {
    playbackRequest++;
    _reconnectTimer?.cancel();
    _connectTimer?.cancel();
    reconnecting = false;
    _reconnectAttempts = 0;
    _everPlayed = false;
    _buffering = false;
    _failureLabel = null;
    _lastYtdlHookErrorAt = null;
    _ytdlGraceTimer?.cancel();
    _ytdlGraceTimer = null;
    _activeStreamUrl = '';
    _activeIsHls = false;
    _activeIsAv3a = false;
    _activeIsMmtTlv = false;
    _av3aFallbackStarting = false;
    _audioDecodeErrorStreak = 0;
    _tlsVerifyDisabled = false;
    _tlsFallbackStarting = false;
    _resetDashSubtitleFallback();
    _clearFreezeFrame();
    await Future.wait([_dashServer.stop(), _av3aServer.stop()]);
    streamUrlController.clear();
    // Returning home releases libmpv without replacing it; the transport Stop
    // button keeps a blank engine because PlayerPage remains visible there.
    if (_engineReleased) {
      // Nothing native remains to stop. This occurs when callers defensively
      // stop playback before opening a source from the home page.
    } else if (releaseEngine || _engineDirty) {
      // Unload before destroying or replacing the engine, for the same reason
      // as in [play]: tearing down media_kit's VideoOutput blocks the platform
      // thread on the raster thread, which can deadlock against a render pass
      // that is still in flight over a very large frame.
      try {
        await player.stop();
      } catch (error) {
        debugPrint('Stop before engine teardown failed: $error');
      }
      if (_disposed) return;
      if (releaseEngine) {
        await _releaseEngine();
      } else {
        await _swapEngine();
      }
    } else {
      try {
        await player.stop();
      } catch (error) {
        _showMessage('Failed to stop playback: $error');
      }
    }
    if (_disposed) return;
    nowPlaying = null;
    videoParams = const VideoParams();
    selectedTrack = const Track();
    videoBitrate = null;
    containerFps = null;
    hwdecCurrent = null;
    _resetFrameDropReporting();
    fullscreen = false;
    position = Duration.zero;
    duration = Duration.zero;
    _seeking = false;
    _cursorHideTimer?.cancel();
    if (cursorHidden) cursorHidden = false;
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    if (nowPlaying == null) return;
    try {
      await player.playOrPause();
    } catch (error) {
      _showMessage('Failed to toggle playback: $error');
    }
  }

  // Called continuously while dragging so the thumb tracks the pointer without
  // committing the seek until the drag ends.
  void onSeekChanged(double seconds) {
    _seeking = true;
    _seekTarget = Duration(milliseconds: (seconds * 1000).round());
    position = _seekTarget;
    _rawPlaybackPosition = _seekTarget;
    _updateDashSubtitleText(_seekTarget);
    notifyListeners();
  }

  Future<void> onSeekEnd(double seconds) async {
    final target = Duration(milliseconds: (seconds * 1000).round());
    position = target;
    _rawPlaybackPosition = target;
    _updateDashSubtitleText(target);
    _seeking = false;
    notifyListeners();
    try {
      await player.seek(target);
    } catch (error) {
      _showMessage('Failed to seek: $error');
    }
  }

  Future<void> setVolume(double value) async {
    final next = value.clamp(0.0, 100.0);
    volume = next;
    muted = next == 0;
    notifyListeners();
    try {
      await player.setVolume(next);
    } catch (_) {}
  }

  // Push the controller's current volume/mute state onto the active engine.
  // Volume/mute is global (owned by the controller, not any one stream), so it
  // must be re-applied whenever the engine is recreated or a new stream opens;
  // a fresh mpv engine otherwise defaults to 100 / unmuted. When muted, the
  // controller's `volume` is already 0 (the pre-mute level lives in
  // _volumeBeforeMute), so setting the engine to `volume` covers both cases.
  Future<void> _applyVolumeToEngine() async {
    try {
      await player.setVolume(volume);
    } catch (_) {}
  }

  Future<void> toggleMute() async {
    if (muted || volume == 0) {
      final restore = _volumeBeforeMute <= 0 ? 100.0 : _volumeBeforeMute;
      await setVolume(restore);
    } else {
      _volumeBeforeMute = volume;
      await setVolume(0);
    }
  }

  Future<void> takeSnapshot() async {
    if (nowPlaying == null) return;
    try {
      final frame = await player.screenshot();
      if (frame == null) {
        _showMessage('Snapshot unavailable for this stream');
        return;
      }
      final dir = await _snapshotDirectory();
      final safeName = (nowPlaying?.name ?? 'snapshot')
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .trim();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}\\${safeName}_$stamp.png');
      await file.writeAsBytes(frame);
      _showMessage('Snapshot saved to ${file.path}');
    } catch (error) {
      _showMessage('Snapshot failed: $error');
    }
  }

  Future<Directory> _snapshotDirectory() async {
    final base = File(Platform.resolvedExecutable).parent.path;
    final dir = Directory('$base\\Snapshots');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  double get videoAspectRatio {
    final track = selectedTrack.video;
    final width = videoParams.dw ?? videoParams.w ?? track.w;
    final height = videoParams.dh ?? videoParams.h ?? track.h;
    if (width != null && height != null && height > 0) {
      return width / height;
    }
    return 16 / 9;
  }

  bool get hwActive =>
      hwdecCurrent != null && hwdecCurrent!.isNotEmpty && hwdecCurrent != 'no';

  String get playbackInfo {
    if (nowPlaying == null) return 'No video loaded';
    if (_failureLabel != null) return _failureLabel!;

    final track = selectedTrack.video;
    final width = videoParams.dw ?? videoParams.w ?? track.w;
    final height = videoParams.dh ?? videoParams.h ?? track.h;
    final resolution = width != null && height != null
        ? '${width}x$height'
        : null;
    final fps = containerFps != null && containerFps! > 0
        ? '${containerFps!.round()} fps'
        : null;
    final bitrate = videoBitrate != null && videoBitrate! > 0
        ? _formatBitrate(videoBitrate!)
        : null;

    final parts = [?resolution, ?fps, ?bitrate];
    return parts.isEmpty ? 'Connecting...' : parts.join(' · ');
  }

  String _formatBitrate(int bps) {
    final mbps = bps / 1000000;
    if (mbps >= 1) return '${mbps.toStringAsFixed(1)} Mbps';
    final kbps = bps / 1000;
    return '${kbps.toStringAsFixed(0)} Kbps';
  }

  Future<void> _applyPlaybackOptions({
    bool isHls = false,
    bool isAv3a = false,
    bool isMmtTlv = false,
  }) async {
    final platform = player.platform;
    if (platform == null) return;

    // Low-latency baseline. Motion interpolation stays OFF here and is enabled
    // later, automatically, only for low-frame-rate sources once the real fps
    // is known (see _applyInterpolationForFps). Interpolation + display-resample
    // are very expensive at 4K60 and noticeably delay first frame.
    _interpolationConfigured = false;
    _largeFrameTuningApplied = false;
    final options = {
      // Keep in sync with VideoControllerConfiguration.hwdec: the zero-copy
      // path leaks HEVC decoder padding as a black bottom/left bar (see
      // _createPlaybackEngine). Frames above _zeroCopyPixelThreshold override
      // this once their size is known (see _applyLargeFrameTuning), so this
      // also restores the copy path when switching back to a normal stream.
      'hwdec': 'auto-copy',
      'interpolation': 'no',
      'video-sync': 'audio',
      // Native subtitle rendering supports text and bitmap tracks. Keep these
      // options in one map because file-local mpv properties are re-applied
      // after every open below.
      ..._nativeSubtitleOptions,
      // The app supplies its own normal and fullscreen controls. Keep mpv's
      // built-in OSC/OSD bar disabled so it cannot reserve or darken a strip at
      // the bottom of the native video surface.
      'osc': 'no',
      'osd-bar': 'no',
      // youtube-dl / yt-dlp is not bundled with the app, so mpv's ytdl_hook can
      // never succeed. Left enabled it hijacks every failed open, spends the
      // 20s ytdl grace period trying to spawn a missing binary, and floods the
      // log with "youtube-dl failed: not found". Turn it off so a failed stream
      // fails fast and cleanly.
      'ytdl': 'no',
      // Force FFmpeg's demuxer for HLS, native MMT/TLV, and the local Matroska
      // stream produced by the AV3A bridge. Cleared for other formats so normal
      // probing is unaffected when switching channels.
      'demuxer': (isHls || isAv3a || isMmtTlv) ? 'lavf' : '',
      'demuxer-lavf-format': isAv3a ? 'matroska' : (isMmtTlv ? 'mmttlv' : ''),
      // Some fMP4 HLS origins prepend the same EXT-X-MAP init section on
      // playlist reloads. FFmpeg safely skips the duplicate moov but emits a
      // warning for every segment. This only quiets mpv's own terminal
      // channel; media_kit's client-API log stream ignores per-module
      // msg-level, so the same warnings are also dropped in the log listener
      // (see isBenignFmp4Warning). Keep info for AV3A detection and
      // explicitly restore it when switching streams.
      'msg-level': isHls && !isAv3a
          ? 'ffmpeg/demuxer=error'
          : 'ffmpeg/demuxer=info',
      // Deinterlacing is handled via an explicit video filter (see
      // _applyDeinterlaceFilter), applied after the option loop so the filter
      // string can be swapped live without a reload. Nothing to set here.
      // Keep the last decoded frame on EOF so a fast `loadfile replace` at a
      // segment boundary does not flash black while the next connection opens.
      'keep-open': 'yes',
      // Keep enough read-ahead to absorb normal CDN jitter without retaining
      // a minute of demuxed packets for every live stream.
      //
      // `demuxer-max-bytes` is a ceiling, not a preallocation: `readahead-secs`
      // decides how much is actually held, so a low-bitrate channel still uses
      // only a few MiB. The previous 32 MiB ceiling silently capped read-ahead
      // at ~7s for a 35 Mbps stream (8K MMT/TLV), well short of the 20s asked
      // for above, leaving no cushion when the pipeline briefly falls behind.
      'demuxer-readahead-secs': '20',
      'demuxer-max-bytes': (96 * 1024 * 1024).toString(),
      // We buffer entirely in memory (the demuxer cache above plus our own
      // producer queue), so stop mpv trying to spill the cache to a disk file
      // — that attempt just fails with "lavf: Failed to create file cache".
      'cache-on-disk': 'no',
      // media_kit sizes mpv's backward demuxer cache from `bufferSize` too, so
      // it grows toward tens of MiB the entire time a stream plays. Live IPTV
      // can never seek backward, so that buffer is pure wasted RAM. Cap it hard.
      'demuxer-max-back-bytes': (4 * 1024 * 1024).toString(),
      // Apply the global override to libmpv itself so HLS manifests, media
      // segments and direct streams use the same identity as Dart requests.
      if (UserAgentService.current != null)
        'user-agent': UserAgentService.current!,
      // Region proxy for the stream itself. Local ClearKey-proxy streams stay
      // DIRECT here (their origin requests are proxied inside dash_clearkey
      // via HttpOverrides instead). An empty value clears any proxy left over
      // from a previously played channel.
      'http-proxy': _proxyForActiveStream(),
      // TLS certificate verification. Left ON (mpv's default) so HTTPS origins
      // are validated normally; only disabled per-stream after a verification
      // failure (see _activateTlsVerifyFallback) so those self-signed/expired
      // IPTV origins can still play. An explicit 'yes' also clears the relaxed
      // setting left over from a previous channel.
      'tls-verify': _tlsVerifyDisabled ? 'no' : 'yes',
    };

    for (final option in options.entries) {
      try {
        await (platform as dynamic).setProperty(option.key, option.value);
        debugPrint('Applied option: ${option.key}=${option.value}');
      } catch (e) {
        debugPrint('Failed to apply ${option.key}: $e');
      }
    }

    // `hwdec-current` is deliberately NOT read back here. This runs before
    // `player.open()`, so no video chain exists yet and mpv has no current
    // decoder to report: the read always yielded an empty string. The effective
    // decoder is logged by _pollBitrate once playback is actually running.

    await _applyDeinterlaceFilter();
  }

  /// mpv `http-proxy` value for the stream about to be opened: the configured
  /// proxy URL (the user's HTTP proxy, or the local SOCKS bridge) when the
  /// proxy is active and the stream is remote, otherwise empty (which clears
  /// the property).
  String _proxyForActiveStream() {
    final proxyUrl = ProxyService.mpvProxyUrl();
    if (proxyUrl == null) return '';
    final uri = Uri.tryParse(_activeStreamUrl);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        isLoopbackHost(uri.host)) {
      return '';
    }
    return proxyUrl;
  }

  // Motion interpolation (frame doubling) only helps low-frame-rate sources
  // such as 24/25/30 fps content on a 60 Hz+ display. For 50/60 fps sources it
  // adds heavy GPU load and startup latency — especially at 4K — without any
  // visible benefit, so it is left off. Called once per stream after mpv
  // reports the real source frame rate.
  Future<void> _applyInterpolationForFps(double fps) async {
    final platform = player.platform;
    if (platform == null) return;
    // A frame size of 0 means mpv has not reported one yet (audio-only streams
    // never do), which keeps the original fps-only behaviour for those.
    final pixels = _decodedPixels;
    final enable =
        !_activeIsAv3a &&
        fps > 0 &&
        fps < 40 &&
        pixels <= _interpolationPixelLimit;
    try {
      await (platform as dynamic).setProperty(
        'video-sync',
        enable ? 'display-resample' : 'audio',
      );
      await (platform as dynamic).setProperty(
        'interpolation',
        enable ? 'yes' : 'no',
      );
      if (enable) {
        await (platform as dynamic).setProperty('tscale', 'oversample');
      }
      debugPrint(
        'Interpolation ${enable ? 'enabled' : 'disabled'} '
        'for ${fps.toStringAsFixed(3)} fps',
      );
    } catch (e) {
      debugPrint('Failed to apply interpolation: $e');
    }
  }

  /// Flip the per-channel deinterlace toggle and apply it live to the running
  /// stream so the change is visible immediately (no reload needed). Not
  /// persisted: it resets to OFF on the next channel switch (see play()).
  Future<void> toggleDeinterlace() async {
    deinterlace = !deinterlace;
    notifyListeners();
    await _applyDeinterlaceFilter();
  }

  // Apply (or clear) the deinterlacer. mpv's default `deinterlace=yes` runs
  // yadif in `send_field` mode, which doubles the output frame rate (50i -> 50p)
  // — that frame doubling, on top of the per-frame upload cost of the hwdec
  // path, is what makes playback stutter like a
  // slideshow. Instead use the faster `bwdif` filter in `send_frame` mode so
  // one deinterlaced frame is produced per input field pair (output fps stays
  // the same). This keeps the CPU cost low while still removing combing.
  //
  // Set via the `vf` PROPERTY (not the `vf set` command): the property persists
  // across `loadfile`/`open`, so once enabled the filter is re-applied
  // automatically to every channel we switch to, instead of only the stream
  // that was playing when the toggle was pressed.
  Future<void> _applyDeinterlaceFilter() async {
    final platform = player.platform;
    if (platform == null) return;
    try {
      await (platform as dynamic).setProperty(
        'vf',
        deinterlace ? 'bwdif=mode=send_frame:deint=all' : '',
      );
      debugPrint('Deinterlace ${deinterlace ? 'enabled (bwdif)' : 'disabled'}');
    } catch (e) {
      debugPrint('Failed to apply deinterlace filter: $e');
    }
  }

  Future<void> toggleFullscreen() async {
    if (fullscreenChanging) return;
    fullscreenChanging = true;
    final nextFullscreen = !fullscreen;
    fullscreen = nextFullscreen;
    notifyListeners();
    try {
      await windowManager.setFullScreen(nextFullscreen);
      final actualFullscreen = await windowManager.isFullScreen();
      if (!_disposed && actualFullscreen != fullscreen) {
        fullscreen = actualFullscreen;
        notifyListeners();
      }
    } catch (_) {
      if (!_disposed) {
        fullscreen = !nextFullscreen;
        notifyListeners();
      }
      rethrow;
    } finally {
      fullscreenChanging = false;
      _syncCursorHiding();
    }
  }

  // Called when leaving the player page: exit fullscreen state and cursor
  // hiding without toggling the OS window (the page teardown handles that).
  void resetFullscreenState() {
    fullscreen = false;
    _cursorHideTimer?.cancel();
    if (cursorHidden) cursorHidden = false;
    notifyListeners();
  }

  void _syncCursorHiding() {
    _cursorHideTimer?.cancel();
    if (fullscreen) {
      playerFocusNode.requestFocus();
      _scheduleCursorHide();
    } else if (cursorHidden) {
      cursorHidden = false;
      notifyListeners();
    }
  }

  void _scheduleCursorHide() {
    _cursorHideTimer?.cancel();
    _cursorHideTimer = Timer(_cursorHideDelay, () {
      if (!_disposed && fullscreen && !cursorHidden) {
        cursorHidden = true;
        notifyListeners();
      }
    });
  }

  // Called on any mouse movement or click. Reveals the cursor (if hidden) and
  // restarts the inactivity timer while fullscreen.
  void handlePointerActivity() {
    if (!fullscreen) return;
    if (cursorHidden) {
      cursorHidden = false;
      notifyListeners();
    }
    _scheduleCursorHide();
  }

  KeyEventResult handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape && fullscreen && !fullscreenChanging) {
      toggleFullscreen();
      return KeyEventResult.handled;
    }

    // Transport shortcuts only apply while a channel is loaded.
    if (nowPlaying == null) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setVolume(volume + 5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setVolume(volume - 5);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
