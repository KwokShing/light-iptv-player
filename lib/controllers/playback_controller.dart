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
import '../services/ping_service.dart';
import '../services/proxy_service.dart';

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
    _listenPlaybackInfo();
  }

  late Player player;
  late VideoController videoController;
  // Bumped every time the engine is recreated. The player page keys its `Video`
  // widget with this so a fresh Video State binds to the new VideoController
  // (media_kit's Video does not rebind a swapped controller in didUpdateWidget).
  int _engineGeneration = 0;
  int get engineGeneration => _engineGeneration;

  // Local exo_driven DASH engine for ClearKey-protected MPEG-DASH. When active,
  // mpv is pointed at its single muxed/decrypted local fMP4 stream instead of
  // the origin URL.
  final DashStreamServer _dashServer = DashStreamServer();
  // The URL actually handed to mpv for the current channel: the origin URL for
  // plain streams, or the proxy's local manifest for ClearKey DASH. Used by the
  // reconnect path so it reloads the right source.
  String _activeStreamUrl = '';

  final TextEditingController streamUrlController = TextEditingController();
  final FocusNode playerFocusNode = FocusNode();

  Channel? nowPlaying;
  VideoParams videoParams = const VideoParams();
  Track selectedTrack = const Track();

  StreamSubscription<VideoParams>? _videoParamsSubscription;
  StreamSubscription<Track>? _trackSubscription;
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

  Uint8List? lastFrame;
  int? videoBitrate;
  double? containerFps;
  String? hwdecCurrent;
  bool _interpolationConfigured = false;
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
    _messages.add(text);
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelStreamSubscriptions();
    _bitrateTimer?.cancel();
    _reconnectTimer?.cancel();
    _connectTimer?.cancel();
    _ytdlGraceTimer?.cancel();
    _cursorHideTimer?.cancel();
    playerFocusNode.dispose();
    streamUrlController.dispose();
    _dashServer.dispose();
    player.dispose();
    _messages.close();
    super.dispose();
  }

  void _cancelStreamSubscriptions() {
    _videoParamsSubscription?.cancel();
    _trackSubscription?.cancel();
    _completedSubscription?.cancel();
    _playingSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _errorSubscription?.cancel();
    _logSubscription?.cancel();
  }

  /// Tears down the current mpv engine and builds a fresh one. Disposing the
  /// [Player] frees its native render context and unregisters the Flutter
  /// texture (see media_kit's `~VideoOutput`), which is the only reliable way to
  /// drop the last decoded frame the texture retains by design. A new engine
  /// starts with a blank texture, so switching channels no longer flashes the
  /// previous channel's final frame. The player page rebinds via
  /// [engineGeneration].
  Future<void> _recreateEngine() async {
    _cancelStreamSubscriptions();
    final old = player;
    final engine = _createPlaybackEngine();
    player = engine.$1;
    videoController = engine.$2;
    _engineGeneration++;
    _listenPlaybackInfo();
    notifyListeners();
    // Dispose the old engine after the swap so the UI can bind the new texture
    // first; the black gap between the two is what replaces the stale frame.
    unawaited(old.dispose().catchError((_) {}));
  }

  (Player, VideoController) _createPlaybackEngine() {
    final nextPlayer = Player(
      configuration: const PlayerConfiguration(
        title: 'Light IPTV Player',
        // Keep mpv logs at warning level: real problems still surface, but the
        // verbose per-frame/demuxer chatter used while diagnosing is gone.
        logLevel: MPVLogLevel.warn,
        // Forward read-ahead cache. media_kit turns this into mpv's
        // `demuxer-max-bytes`. Sized generously here (overridden per-stream in
        // _applyPlaybackOptions) so DASH playback can buffer many seconds and
        // ride out slow segment downloads on rate-limited CDNs.
        bufferSize: 128 * 1024 * 1024,
      ),
    );
    final nextVideoController = VideoController(
      nextPlayer,
      configuration: const VideoControllerConfiguration(
        // `auto-copy` keeps hardware decoding but copies decoded frames back to
        // system memory instead of sharing a D3D11 texture directly with ANGLE.
        // The zero-copy interop path (`auto`) crashes the native process on
        // Windows for some IPTV codecs/resolutions; the copy path is far more
        // robust at a small upload cost.
        hwdec: 'auto-copy',
        enableHardwareAcceleration: true,
      ),
    );
    return (nextPlayer, nextVideoController);
  }

  void _listenPlaybackInfo() {
    _videoParamsSubscription = player.stream.videoParams.listen((params) {
      if (_disposed) return;
      videoParams = params;
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
        'Selected track changed: audio.id=${track.audio.id} audio.title=${track.audio.title}',
      );
      selectedTrack = track;
      notifyListeners();
    });
    // Some IPTV streams are delivered in segments: the server closes the
    // connection at the end of each segment, which media_kit surfaces as a
    // "completed" event even though more data is available. When that happens
    // while a channel is selected, transparently reconnect and keep playing.
    _completedSubscription = player.stream.completed.listen((completed) async {
      if (!completed) return;
      if (_disposed || nowPlaying == null || reconnecting) return;
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
      // A position past zero also proves real playback (covers audio-only
      // streams that emit no video params).
      if (!_everPlayed && value > Duration.zero) _confirmPlaybackStarted();
      // The progress UI only shows whole seconds, so ignore the sub-second
      // firehose. This alone cuts page rebuilds during playback from many per
      // second down to about one.
      if (value.inSeconds == position.inSeconds) return;
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
        debugPrint('player error before first frame but ytdl_hook-only -> defer');
        return;
      }
      debugPrint('player error before first frame -> Load error');
      _failLoad();
    });
    // Raw mpv logs, printed for diagnostics only. NOTE: these "[mpv:error]"
    // lines are not treated as load failures — only genuine "Player error"
    // events (player.stream.error, handled above) are.
    _logSubscription = player.stream.log.listen((log) {
      debugPrint('[mpv:${log.level}] ${log.prefix}: ${log.text}');
      if (log.level == 'error' && log.prefix == 'ytdl_hook') {
        _lastYtdlHookErrorAt = DateTime.now();
      }
    });
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

  Future<void> _pollBitrate() async {
    final platform = player.platform;
    if (platform == null || nowPlaying == null || _failureLabel != null) return;
    try {
      final bitrateValue =
          await (platform as dynamic).getProperty('video-bitrate') as String?;
      final fpsValue =
          await (platform as dynamic).getProperty('container-fps') as String?;
      final hwdecValue =
          await (platform as dynamic).getProperty('hwdec-current') as String?;
      if (_disposed) return;
      final parsedBitrate = bitrateValue == null
          ? null
          : int.tryParse(bitrateValue);
      final parsedFps = fpsValue == null ? null : double.tryParse(fpsValue);
      videoBitrate = parsedBitrate;
      containerFps = parsedFps;
      hwdecCurrent = hwdecValue;
      notifyListeners();
      // Once mpv reports the real source frame rate, decide interpolation
      // automatically (one time per stream).
      if (!_interpolationConfigured && parsedFps != null && parsedFps > 0) {
        _interpolationConfigured = true;
        await _applyInterpolationForFps(parsedFps);
      }
    } catch (_) {}
  }

  // Returns false when the stream is a format the bundled libmpv can't open
  // without crashing the whole process (currently MPEG-DASH). Fetches a small
  // prefix with a short timeout so a healthy stream isn't delayed much, and
  // returns true (play it) on any uncertainty so a flaky probe never blocks a
  // good channel.
  Future<bool> _isNativeSafeStream(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return true;
    }
    final client = http.Client();
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = true
        ..headers['User-Agent'] = 'Mozilla/5.0'
        ..headers['Range'] = 'bytes=0-4095';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 6));
      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= 4096) break;
      }
      final head = utf8.decode(
        bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes,
        allowMalformed: true,
      );
      final looksDash =
          contentType.contains('dash+xml') ||
          head.contains('<MPD') ||
          head.contains('urn:mpeg:dash');
      return !looksDash;
    } finally {
      client.close();
    }
  }

  Future<void> play(Channel channel) async {
    final request = ++playbackRequest;
    // A previously-selected channel means the engine has (or will have) painted
    // a frame that its texture would otherwise retain across the switch. In that
    // case rebuild the engine so the stale frame is truly released; on the very
    // first play the freshly-constructed engine is still blank, so reuse it.
    final needsEngineSwap = nowPlaying != null;
    _reconnectTimer?.cancel();
    _connectTimer?.cancel();
    reconnecting = false;
    _reconnectAttempts = 0;
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
    debugPrint('  channel drm: manifestType=${channel.manifestType} '
        'licenseType=${channel.licenseType} '
        'licenseKey=${channel.licenseKey} '
        'isDash=${channel.isDash} clearKeys=${channel.clearKeys.length} '
        'isEncryptedDash=${channel.isEncryptedDash}');
    nowPlaying = channel;
    videoParams = const VideoParams();
    selectedTrack = const Track();
    position = Duration.zero;
    duration = Duration.zero;
    _seeking = false;
    notifyListeners();
    if (needsEngineSwap) {
      await _recreateEngine();
    } else {
      await player.stop();
    }
    if (_disposed || request != playbackRequest) return;

    // ClearKey-protected MPEG-DASH: libmpv can't decrypt CENC, so route the
    // stream through the local exo_driven engine which parses the MPD, picks a
    // video + audio Representation, downloads/decrypts (AES-128-CTR) segments
    // and muxes them into a single clear fMP4. mpv then plays that local
    // stream. Plain streams keep using their origin URL directly.
    var streamUrl = channel.url;
    if (channel.isEncryptedDash) {
      try {
        streamUrl = await _dashServer.start(channel.url, channel.clearKeys);
        debugPrint('DASH engine started: $streamUrl');
      } catch (error) {
        debugPrint('DASH engine failed to start: $error');
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
    // first: if it's DASH, don't hand it to mpv. Best-effort; a probe failure
    // falls through to a normal open so healthy streams are never blocked.
    //
    // Skip the guard for streams we deliberately open: DASH declared via
    // #KODIPROP (played through the ClearKey proxy) and the proxy's own local
    // manifest.
    var nativeSafe = true;
    if (!channel.isDash) {
      try {
        nativeSafe = await _isNativeSafeStream(channel.url);
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

    _activeStreamUrl = streamUrl;
    await _applyPlaybackOptions();
    if (_disposed || request != playbackRequest) return;
    await player.open(Media(streamUrl));
    // A recreated engine starts at mpv's default volume (100, unmuted), so the
    // controller's current volume/mute state must be pushed back onto it —
    // otherwise switching channels while muted would silently play at full
    // volume even though the UI still shows muted.
    await _applyVolumeToEngine();
    _connectTimer?.cancel();
  }

  bool _deferFailureForYtdl() {
    if (_everPlayed || _failureLabel != null || nowPlaying == null) return false;
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
    try {
      if (_reconnectAttempts > 1) {
        await _applyPlaybackOptions();
        if (_disposed || request != playbackRequest) return;
      }
      final platform = player.platform;
      var replaced = false;
      if (platform != null) {
        try {
          await (platform as dynamic).command(['loadfile', reloadUrl, 'replace']);
          await player.play();
          replaced = true;
        } catch (e) {
          debugPrint('loadfile replace failed, falling back to open: $e');
        }
      }
      if (!replaced) {
        if (_disposed || request != playbackRequest) return;
        await player.open(Media(reloadUrl));
      }
    } catch (error) {
      debugPrint('Reconnect failed: $error');
      if (!_disposed && request == playbackRequest) {
        _scheduleReconnect();
      }
    }
  }

  Future<void> stopPlayback() async {
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
    _clearFreezeFrame();
    unawaited(_dashServer.stop());
    streamUrlController.clear();
    try {
      await player.stop();
    } catch (error) {
      _showMessage('Failed to stop playback: $error');
    }
    if (_disposed) return;
    nowPlaying = null;
    videoParams = const VideoParams();
    selectedTrack = const Track();
    videoBitrate = null;
    containerFps = null;
    hwdecCurrent = null;
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
    notifyListeners();
  }

  Future<void> onSeekEnd(double seconds) async {
    final target = Duration(milliseconds: (seconds * 1000).round());
    position = target;
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

  Future<void> _applyPlaybackOptions() async {
    final platform = player.platform;
    if (platform == null) return;

    // Low-latency baseline. Motion interpolation stays OFF here and is enabled
    // later, automatically, only for low-frame-rate sources once the real fps
    // is known (see _applyInterpolationForFps). Interpolation + display-resample
    // are very expensive at 4K60 and noticeably delay first frame.
    _interpolationConfigured = false;
    final options = {
      'hwdec': 'auto-copy',
      'interpolation': 'no',
      'video-sync': 'audio',
      // Deinterlacing is handled via an explicit video filter (see
      // _applyDeinterlaceFilter), applied after the option loop so the filter
      // string can be swapped live without a reload. Nothing to set here.
      // Keep the last decoded frame on EOF so a fast `loadfile replace` at a
      // segment boundary does not flash black while the next connection opens.
      'keep-open': 'yes',
      // Let mpv actually use more of media_kit's forward buffer. This does not
      // stitch independent segments together (so no rewind risk), but it lets
      // mpv hold many seconds of demuxed data so a slow segment download (the
      // ~8s outliers on this rate-limited CDN) doesn't drain the buffer and
      // stall playback.
      'demuxer-readahead-secs': '60',
      // Also cap the total forward demuxer cache generously so readahead-secs
      // isn't the limiting factor for the low-bitrate stream.
      'demuxer-max-bytes': (128 * 1024 * 1024).toString(),
      // We buffer entirely in memory (the demuxer cache above plus our own
      // producer queue), so stop mpv trying to spill the cache to a disk file
      // — that attempt just fails with "lavf: Failed to create file cache".
      'cache-on-disk': 'no',
      // media_kit sizes mpv's backward demuxer cache from `bufferSize` too, so
      // it grows toward tens of MiB the entire time a stream plays. Live IPTV
      // can never seek backward, so that buffer is pure wasted RAM. Cap it hard.
      'demuxer-max-back-bytes': (4 * 1024 * 1024).toString(),
      // Region proxy for the stream itself. Local ClearKey-proxy streams stay
      // DIRECT here (their origin requests are proxied inside dash_clearkey
      // via HttpOverrides instead). An empty value clears any proxy left over
      // from a previously played channel.
      'http-proxy': _proxyForActiveStream(),
    };

    for (final option in options.entries) {
      try {
        await (platform as dynamic).setProperty(option.key, option.value);
        debugPrint('Applied option: ${option.key}=${option.value}');
      } catch (e) {
        debugPrint('Failed to apply ${option.key}: $e');
      }
    }

    try {
      final current =
          await (platform as dynamic).getProperty('hwdec-current') as String?;
      debugPrint('After apply: hwdec-current=$current');
    } catch (_) {}

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
    final enable = fps > 0 && fps < 40;
    try {
      await (platform as dynamic)
          .setProperty('video-sync', enable ? 'display-resample' : 'audio');
      await (platform as dynamic)
          .setProperty('interpolation', enable ? 'yes' : 'no');
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
  // — that frame doubling, on top of the `auto-copy` hwdec path that already
  // copies frames back to system RAM, is what makes playback stutter like a
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
    if (key == LogicalKeyboardKey.keyS) {
      stopPlayback();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      toggleMute();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyD) {
      toggleDeinterlace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      if (!fullscreenChanging) toggleFullscreen();
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
