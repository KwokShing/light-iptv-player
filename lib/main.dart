import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset_converter/charset_converter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'dash_clearkey.dart';
import 'update_service.dart';

const sourcesStorageKey = 'light-iptv-player:sources:flutter:v1';
const installedTagStorageKey = 'light-iptv-player:installed-tag:v1';
const allChannels = 'All Channels';
const ungroupedGroup = 'Ungrouped';

/// The git tag this build was released under, injected at build time via
/// `--dart-define=RELEASE_TAG=...`. Empty for local/dev builds.
const releaseTag = String.fromEnvironment('RELEASE_TAG');
const fullscreenAnimationDuration = Duration(milliseconds: 180);
const fullscreenAnimationCurve = Curves.easeOutCubic;
// Fixed height of a channel row, including its bottom divider. Sized to fit the
// 46px logo (plus padding) and, while searching, a single-line name above the
// group label without overflow.
const _channelRowHeight = 64.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _filterNoisyDebugLogs();
  // Keep more decoded logos resident so scrolling back through a long channel
  // list doesn't re-download and re-decode images it already showed.
  PaintingBinding.instance.imageCache.maximumSize = 2000;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 128 * 1024 * 1024;
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Light IPTV Player',
      // Height tuned so the video pane is ~16:9 at the default width, avoiding
      // top/bottom black bars for the common 16:9 stream.
      size: Size(1360, 680),
      minimumSize: Size(1040, 520),
      center: true,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const IptvApp());
}

enum SourceKind { local, online, single }

class Channel {
  const Channel({
    required this.name,
    required this.url,
    required this.group,
    this.logo,
    this.manifestType,
    this.licenseType,
    this.licenseKey,
  });

  final String name;
  final String url;
  final String group;
  final String? logo;

  // DRM / adaptive-streaming hints parsed from #KODIPROP lines that precede the
  // stream URL in the playlist. These mirror Kodi's inputstream.adaptive props:
  //   inputstream.adaptive.manifest_type  -> 'mpd' (MPEG-DASH) or 'hls'
  //   inputstream.adaptive.license_type   -> e.g. 'clearkey'
  //   inputstream.adaptive.license_key    -> for clearkey, 'KID:KEY' hex pairs
  final String? manifestType;
  final String? licenseType;
  final String? licenseKey;

  // True when the playlist explicitly marks this entry as MPEG-DASH.
  bool get isDash => (manifestType ?? '').toLowerCase() == 'mpd';

  // ClearKey key pairs (kidHex -> keyHex) parsed from license_key, empty when
  // none/unusable.
  Map<String, String> get clearKeys =>
      licenseKey == null ? const {} : parseClearKeyLicense(licenseKey!);

  // True when this is a DASH stream we can decrypt via the local ClearKey proxy.
  bool get isEncryptedDash => isDash && clearKeys.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'group': group,
    'logo': logo,
    if (manifestType != null) 'manifestType': manifestType,
    if (licenseType != null) 'licenseType': licenseType,
    if (licenseKey != null) 'licenseKey': licenseKey,
  };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
    name: json['name'] as String? ?? 'Untitled Channel',
    url: json['url'] as String? ?? '',
    group: json['group'] as String? ?? ungroupedGroup,
    logo: json['logo'] as String?,
    manifestType: json['manifestType'] as String?,
    licenseType: json['licenseType'] as String?,
    licenseKey: json['licenseKey'] as String?,
  );
}

class PlaylistSource {
  const PlaylistSource({
    required this.id,
    required this.name,
    required this.kind,
    required this.source,
    required this.channels,
    required this.cached,
  });

  final String id;
  final String name;
  final SourceKind kind;
  final String source;
  final List<Channel> channels;
  final bool cached;

  PlaylistSource copyWith({
    String? name,
    String? source,
    List<Channel>? channels,
    bool? cached,
  }) => PlaylistSource(
    id: id,
    name: name ?? this.name,
    kind: kind,
    source: source ?? this.source,
    channels: channels ?? this.channels,
    cached: cached ?? this.cached,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'source': source,
    'cached': cached,
    'channels': channels.map((channel) => channel.toJson()).toList(),
  };

  factory PlaylistSource.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String? ?? SourceKind.online.name;
    return PlaylistSource(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? 'Playlist',
      kind: SourceKind.values.firstWhere(
        (kind) => kind.name == kindName,
        orElse: () => SourceKind.online,
      ),
      source: json['source'] as String? ?? '',
      cached: json['cached'] as bool? ?? false,
      channels: (json['channels'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Channel.fromJson)
          .where((channel) => channel.url.isNotEmpty)
          .toList(),
    );
  }
}

class IptvApp extends StatelessWidget {
  const IptvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Light IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff8357f7),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff6f8fc),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
      ),
      builder: (context, child) =>
          ExcludeSemantics(child: child ?? const SizedBox.shrink()),
      home: const IptvHome(),
    );
  }
}

void _filterNoisyDebugLogs() {
  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null) return;
    final noisy =
        message.startsWith('VideoOutput.Resize') ||
        message.startsWith('{handle:') ||
        message.startsWith('NativeVideoController: Texture ID:');
    if (noisy) return;
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };
}

class IptvHome extends StatefulWidget {
  const IptvHome({super.key});

  @override
  State<IptvHome> createState() => _IptvHomeState();
}

class _IptvHomeState extends State<IptvHome> {
  late Player player;
  late VideoController videoController;
  // Local decrypting proxy for ClearKey-protected MPEG-DASH. When active, mpv
  // is pointed at its rewritten local manifest instead of the origin URL.
  final DashClearKeyProxy _clearKeyProxy = DashClearKeyProxy();
  // The URL actually handed to mpv for the current channel: the origin URL for
  // plain streams, or the proxy's local manifest for ClearKey DASH. Used by the
  // reconnect path so it reloads the right source.
  String _activeStreamUrl = '';
  final TextEditingController streamUrlController = TextEditingController();
  final ScrollController channelScrollController = ScrollController();
  List<PlaylistSource> sources = [];
  PlaylistSource? activeSource;
  PlaylistSource? playerSource;
  String activeGroup = allChannels;
  String search = '';
  Channel? nowPlaying;
  VideoParams videoParams = const VideoParams();
  Track selectedTrack = const Track();
  StreamSubscription<VideoParams>? videoParamsSubscription;
  StreamSubscription<Track>? trackSubscription;
  StreamSubscription<bool>? completedSubscription;
  StreamSubscription<bool>? playingSubscription;
  StreamSubscription<Duration>? positionSubscription;
  StreamSubscription<Duration>? durationSubscription;
  StreamSubscription<String>? errorSubscription;
  StreamSubscription<PlayerLog>? logSubscription;
  Timer? bitrateTimer;
  Timer? reconnectTimer;
  // Retained only so existing cancel() calls stay valid; the initial-connection
  // watchdog that used to time out a stream after 15s has been removed so slow
  // starts (proxied DASH, slow CDNs) are never killed early.
  Timer? connectTimer;
  int reconnectAttempts = 0;
  bool reconnecting = false;
  // Set true once a channel has actually started rendering. Distinguishes a
  // legitimate mid-stream segment boundary (reconnect is desirable) from a
  // stream that could never connect in the first place (reconnecting forever,
  // and screenshotting a frameless output, is what crashes the process).
  bool _everPlayed = false;
  // Non-null when playback failed before it ever started; shown verbatim in the
  // control bar. 'Load error' for a hard open/demux failure. Cleared on a new
  // open, on stop, and if playback eventually starts.
  String? _failureLabel;
  Uint8List? lastFrame;
  int? videoBitrate;
  double? containerFps;
  String? hwdecCurrent;
  // Whether interpolation has already been decided for the current stream.
  // Reset on every (re)open; set once the real source frame rate is known.
  bool _interpolationConfigured = false;
  bool fullscreen = false;
  bool fullscreenChanging = false;
  // When fullscreen, the mouse cursor auto-hides after a short period of
  // inactivity and reappears on any movement or click.
  bool cursorHidden = false;
  Timer? cursorHideTimer;
  final FocusNode playerFocusNode = FocusNode();
  static const _cursorHideDelay = Duration(seconds: 3);
  bool loading = true;
  // Transport state surfaced in the control bar.
  bool isPlaying = false;
  // Current playback position and total duration. For live streams the
  // duration stays zero, in which case the progress bar is shown disabled.
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  // While the user is dragging the progress thumb we show their target value
  // and hold off applying stream position updates so the thumb doesn't jump.
  bool _seeking = false;
  Duration _seekTarget = Duration.zero;
  double volume = 100;
  bool muted = false;
  // Volume to restore when unmuting; captured the moment mute is engaged.
  double _volumeBeforeMute = 100;
  // Maximum consecutive reconnect attempts before giving up. Reset to zero
  // whenever playback successfully resumes, so long-running segmented streams
  // can reconnect indefinitely as long as each reconnect eventually plays.
  static const int _maxReconnectAttempts = 30;
  int playbackRequest = 0;

  // Auto-update state.
  ReleaseInfo? availableUpdate;
  bool updating = false;
  double? updateProgress;
  // True while a "refresh all playlists" run is in progress, so the header
  // button shows a spinner and can't be triggered again concurrently.
  bool refreshingAll = false;
  // IDs of sources currently being refreshed individually, so each tile can
  // show its own spinner without blocking the others.
  Set<String> refreshingSourceIds = const {};

  @override
  void initState() {
    super.initState();
    final engine = _createPlaybackEngine();
    player = engine.$1;
    videoController = engine.$2;
    _listenPlaybackInfo();
    _loadSources();
    _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    // Updating in place is only implemented for the Windows build.
    if (!Platform.isWindows) return;
    try {
      final release = await UpdateService.fetchLatestRelease();
      if (release == null || !mounted) return;

      final prefs = await SharedPreferences.getInstance();
      final currentTag = releaseTag.isNotEmpty
          ? releaseTag
          : (prefs.getString(installedTagStorageKey) ?? '');

      final bool isUpdate;
      if (currentTag.isNotEmpty) {
        // We know exactly which release we're running; the list endpoint
        // returns the newest release first, so anything different is an update.
        isUpdate = release.tag != currentTag;
      } else {
        // Unknown build identity (e.g. a build made before this feature):
        // fall back to semantic version comparison for proper releases, and
        // always surface pre-releases since their tags aren't semver.
        final info = await PackageInfo.fromPlatform();
        if (!mounted) return;
        isUpdate = release.prerelease
            ? true
            : UpdateService.isNewer(release.version, info.version);
      }

      if (isUpdate && mounted) {
        setState(() => availableUpdate = release);
      }
    } catch (error) {
      debugPrint('Update check failed: $error');
    }
  }

  Future<void> _startUpdate() async {
    final release = availableUpdate;
    if (release == null || updating) return;
    setState(() {
      updating = true;
      updateProgress = null;
    });
    try {
      final zip = await UpdateService.download(
        release.zipUrl,
        onProgress: (progress) {
          if (mounted) setState(() => updateProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() => updateProgress = null);
      _showMessage('Update downloaded. Restarting to apply...');

      // Hand off to the external updater (its own console window), then quit so
      // it can replace the locked application files and relaunch us.
      await UpdateService.applyUpdate(zip);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      UpdateService.quit();
    } catch (error) {
      if (!mounted) return;
      setState(() => updating = false);
      _showMessage('Update failed: $error');
    }
  }

  @override
  void dispose() {
    videoParamsSubscription?.cancel();
    trackSubscription?.cancel();
    completedSubscription?.cancel();
    playingSubscription?.cancel();
    positionSubscription?.cancel();
    durationSubscription?.cancel();
    errorSubscription?.cancel();
    logSubscription?.cancel();
    bitrateTimer?.cancel();
    reconnectTimer?.cancel();
    connectTimer?.cancel();
    cursorHideTimer?.cancel();
    playerFocusNode.dispose();
    streamUrlController.dispose();
    channelScrollController.dispose();
    _clearKeyProxy.dispose();
    player.dispose();
    super.dispose();
  }

  (Player, VideoController) _createPlaybackEngine() {
    final nextPlayer = Player(
      configuration: const PlayerConfiguration(
        title: 'Light IPTV Player',
        // Keep mpv logs at warning level: real problems still surface, but the
        // verbose per-frame/demuxer chatter used while diagnosing is gone.
        logLevel: MPVLogLevel.warn,
        // Forward read-ahead cache. media_kit turns this into mpv's
        // `demuxer-max-bytes`. 32 MiB is plenty of buffering for IPTV while
        // keeping the resident cache modest. (It also seeds
        // `demuxer-max-back-bytes`, which we override per-stream below.)
        bufferSize: 32 * 1024 * 1024,
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
    videoParamsSubscription = player.stream.videoParams.listen((params) {
      if (!mounted) return;
      setState(() => videoParams = params);
      // Real decoded dimensions are proof the stream actually started (unlike
      // the `playing`/pause event, which fires the moment a file opens). Use it
      // to confirm playback and, on a reconnect, drop the freeze frame.
      if ((params.w ?? 0) > 0 && (params.h ?? 0) > 0) {
        _confirmPlaybackStarted();
      }
    });
    trackSubscription = player.stream.track.listen((track) {
      if (!mounted) return;
      debugPrint(
        'Selected track changed: audio.id=${track.audio.id} audio.title=${track.audio.title}',
      );
      setState(() => selectedTrack = track);
    });
    // Some IPTV streams are delivered in segments: the server closes the
    // connection at the end of each segment, which media_kit surfaces as a
    // "completed" event even though more data is available. When that happens
    // while a channel is selected, transparently reconnect and keep playing.
    completedSubscription = player.stream.completed.listen((completed) async {
      if (!completed) return;
      if (!mounted || nowPlaying == null || reconnecting) return;
      // Ignore the completed event that our own player.stop() triggers once a
      // failure has already been recorded.
      if (_failureLabel != null) return;
      // Never rendered a frame: this "completed" is a failed/aborted open, not
      // a segment boundary. Treat it as a load failure immediately.
      if (!_everPlayed) {
        _failLoad();
        return;
      }
      reconnecting = true;
      // mpv runs with keep-open=yes, so the last frame is still held on the
      // output here. Grab it once and freeze it so the reload doesn't flash
      // black. Captured on-demand (not periodically) to avoid playback stutter.
      await _captureLastFrame();
      if (!mounted) return;
      // Ensure the freeze-frame overlay is applied even if capture returned
      // nothing (reconnecting was set outside of setState above).
      setState(() {});
      _scheduleReconnect();
    });
    // A successful resume means the previous segment boundary was crossed, so
    // clear the failure counter and drop the freeze-frame overlay.
    playingSubscription = player.stream.playing.listen((playing) {
      if (!mounted) return;
      // This stream mirrors mpv's pause state and flips true the instant a file
      // is opened, so it only drives the transport (play/pause) UI. "Playback
      // actually started" is detected separately via decoded frames/position.
      if (isPlaying != playing) {
        setState(() => isPlaying = playing);
      }
    });
    bitrateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollBitrate();
    });
    positionSubscription = player.stream.position.listen((value) {
      if (!mounted || _seeking) return;
      // A position past zero also proves real playback (covers audio-only
      // streams that emit no video params).
      if (!_everPlayed && value > Duration.zero) _confirmPlaybackStarted();
      // The progress UI only shows whole seconds, so ignore the sub-second
      // firehose. This alone cuts page rebuilds during playback from many per
      // second down to about one, avoiding a full channel-list re-filter and
      // duplicate-name rescan on every tick.
      if (value.inSeconds == position.inSeconds) return;
      setState(() => position = value);
    });
    durationSubscription = player.stream.duration.listen((value) {
      if (!mounted) return;
      setState(() => duration = value);
    });
    // Any hard playback error before the stream has started is treated as a
    // load failure right away (no waiting for the 15s watchdog). Errors after
    // playback is underway are left to the reconnect logic.
    errorSubscription = player.stream.error.listen((error) {
      debugPrint('Player error: $error');
      if (!mounted || nowPlaying == null || _everPlayed || reconnecting) return;
      _failLoad();
    });
    // Raw mpv logs, printed for diagnostics only. NOTE: these "[mpv:error]"
    // lines are not treated as load failures — only genuine "Player error"
    // events (player.stream.error, handled above) are. mpv logs plenty of
    // benign/transient errors (GL init, demuxer probes) that don't mean the
    // stream failed.
    logSubscription = player.stream.log.listen((log) {
      debugPrint('[mpv:${log.level}] ${log.prefix}: ${log.text}');
    });
  }

  // Capture the currently displayed frame. mpv holds the last frame at EOF
  // (keep-open=yes), so calling this at the "completed" event yields a real
  // image to freeze during the reconnect instead of a black screen.
  Future<void> _captureLastFrame() async {
    try {
      final frame = await player.screenshot();
      if (!mounted || frame == null) return;
      // Release the previous freeze frame before storing the new one so its
      // decoded bitmap doesn't linger in the global image cache.
      _clearFreezeFrame();
      lastFrame = frame;
    } catch (_) {}
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
      if (!mounted) return;
      final parsedBitrate = bitrateValue == null
          ? null
          : int.tryParse(bitrateValue);
      final parsedFps = fpsValue == null ? null : double.tryParse(fpsValue);
      setState(() {
        videoBitrate = parsedBitrate;
        containerFps = parsedFps;
        hwdecCurrent = hwdecValue;
      });
      // Once mpv reports the real source frame rate, decide interpolation
      // automatically (one time per stream).
      if (!_interpolationConfigured && parsedFps != null && parsedFps > 0) {
        _interpolationConfigured = true;
        await _applyInterpolationForFps(parsedFps);
      }
    } catch (_) {}
  }

  Future<void> _loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(sourcesStorageKey);
    final nextSources = raw == null
        ? <PlaylistSource>[]
        : (jsonDecode(raw) as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(PlaylistSource.fromJson)
              .toList();
    setState(() {
      sources = nextSources;
      loading = false;
    });
  }

  Future<void> _saveSources() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      sourcesStorageKey,
      jsonEncode(sources.map((source) => source.toJson()).toList()),
    );
  }

  Future<void> _addLocalSource() async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Load M3U File',
        type: FileType.custom,
        allowedExtensions: const ['m3u', 'm3u8', 'txt'],
        withData: true,
        lockParentWindow: true,
      );
      final file = result?.files.single;
      if (file == null) {
        _showMessage('File selection cancelled');
        return;
      }

      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) {
        _showMessage('Could not read selected file');
        return;
      }
      final text = await decodePlaylistBytes(bytes);
      final channels = parsePlaylist(text);
      if (channels.isEmpty) {
        _showMessage('No channels found in ${file.name}');
        return;
      }

      final fileName = file.name.replaceAll(
        RegExp(r'\.m3u8?$|\.txt$', caseSensitive: false),
        '',
      );
      await _upsertSource(
        PlaylistSource(
          id: _newId(),
          name: fileName.isEmpty ? 'Local Playlist' : fileName,
          kind: SourceKind.local,
          source: file.path ?? file.name,
          channels: channels,
          cached: true,
        ),
      );
      _showMessage('Loaded ${channels.length} channels');
    } catch (error) {
      _showMessage('Failed to load M3U file: $error');
    }
  }

  Future<void> _addOnlineSource() async {
    final values = await showSourceDialog(
      context,
      title: 'Online M3U Link',
      urlLabel: 'URL',
    );
    if (values == null) return;
    final response = await http.get(Uri.parse(values.source));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _showMessage('Failed to load playlist: HTTP ${response.statusCode}');
      return;
    }
    final text = await decodeHttpPlaylist(response);
    await _upsertSource(
      PlaylistSource(
        id: _newId(),
        name: values.name,
        kind: SourceKind.online,
        source: values.source,
        channels: parsePlaylist(text),
        cached: true,
      ),
    );
  }

  Future<void> _addSingleChannel() async {
    final values = await showSourceDialog(
      context,
      title: 'Single Channel',
      urlLabel: 'Stream URL',
    );
    if (values == null) return;
    await _upsertSource(
      PlaylistSource(
        id: _newId(),
        name: values.name,
        kind: SourceKind.single,
        source: values.source,
        channels: [
          Channel(name: values.name, url: values.source, group: 'Quick Test'),
        ],
        cached: true,
      ),
    );
  }

  Future<void> _refreshSource(PlaylistSource source) async {
    if (refreshingSourceIds.contains(source.id)) return;
    setState(
      () => refreshingSourceIds = {...refreshingSourceIds, source.id},
    );
    try {
      final channels = await _fetchChannels(source);
      await _replaceSource(source.copyWith(channels: channels, cached: true));
    } catch (error) {
      if (mounted) _showMessage('Update failed for "${source.name}": $error');
    } finally {
      if (mounted) {
        setState(
          () => refreshingSourceIds = {...refreshingSourceIds}
            ..remove(source.id),
        );
      }
    }
  }

  // Fetch and parse a source's channels from its origin. Network/file I/O runs
  // on the main isolate (CharsetConverter uses platform channels and can't run
  // in a background isolate), but the CPU-heavy M3U parse is offloaded via
  // `compute` so it never janks the UI. Throws on failure.
  Future<List<Channel>> _fetchChannels(PlaylistSource source) async {
    if (source.kind == SourceKind.local) {
      final text = await decodePlaylistBytes(
        await File(source.source).readAsBytes(),
      );
      return compute(parsePlaylist, text);
    }
    final response = await http.get(Uri.parse(source.source));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final text = await decodeHttpPlaylist(response);
    return compute(parsePlaylist, text);
  }

  // Refresh every reloadable playlist (local + online) in one go. Single
  // channels have no upstream to refresh and are skipped. Fetches run
  // concurrently and state is written (and persisted) once at the end, so the
  // list doesn't rebuild repeatedly mid-run.
  Future<void> _refreshAllSources() async {
    if (refreshingAll) return;
    final reloadable = sources
        .where((source) => source.kind != SourceKind.single)
        .toList();
    if (reloadable.isEmpty) {
      _showMessage('No playlists to refresh');
      return;
    }
    setState(() => refreshingAll = true);

    Future<({String id, String name, List<Channel>? channels})> refreshOne(
      PlaylistSource source,
    ) async {
      try {
        final channels = await _fetchChannels(source);
        return (id: source.id, name: source.name, channels: channels);
      } catch (_) {
        return (id: source.id, name: source.name, channels: null);
      }
    }

    final results = await Future.wait(reloadable.map(refreshOne));

    if (!mounted) return;

    final updates = <String, List<Channel>>{};
    var succeeded = 0;
    final failures = <String>[];
    for (final result in results) {
      if (result.channels != null) {
        updates[result.id] = result.channels!;
        succeeded++;
      } else {
        failures.add(result.name);
      }
    }

    PlaylistSource apply(PlaylistSource source) {
      final channels = updates[source.id];
      return channels == null
          ? source
          : source.copyWith(channels: channels, cached: true);
    }

    setState(() {
      sources = sources.map(apply).toList();
      if (activeSource != null) activeSource = apply(activeSource!);
      if (playerSource != null) playerSource = apply(playerSource!);
      refreshingAll = false;
    });
    await _saveSources();

    if (!mounted) return;
    // Only surface a bottom message when something failed; a success banner
    // popping in right as the list rebuilds caused a visible frame hitch.
    if (failures.isNotEmpty) {
      _showMessage(
        'Refreshed $succeeded, failed ${failures.length}: '
        '${failures.join(', ')}',
      );
    }
  }

  Future<void> _renameSource(PlaylistSource source) async {
    final result = await showEditSourceDialog(context, source: source);
    if (result == null) return;
    switch (result) {
      case EditSourceResultName(:final name):
        await _replaceSource(source.copyWith(name: name));
      case EditSourceResultUrl(:final url, :final name):
        final updatedSource = name != null
            ? source.copyWith(name: name)
            : source;
        if (updatedSource.kind == SourceKind.single) {
          await _replaceSource(
            updatedSource.copyWith(
              source: url,
              channels: [
                Channel(
                  name: updatedSource.name,
                  url: url,
                  group: 'Quick Test',
                ),
              ],
              cached: true,
            ),
          );
        } else if (updatedSource.kind == SourceKind.online) {
          try {
            final response = await http.get(Uri.parse(url));
            if (response.statusCode < 200 || response.statusCode >= 300) {
              _showMessage(
                'Failed to load playlist: HTTP ${response.statusCode}',
              );
              return;
            }
            final text = await decodeHttpPlaylist(response);
            await _replaceSource(
              updatedSource.copyWith(
                source: url,
                channels: parsePlaylist(text),
                cached: true,
              ),
            );
          } catch (error) {
            _showMessage('Failed to load URL: $error');
          }
        }
      case EditSourceResultFile(:final path, :final channels):
        await _replaceSource(
          source.copyWith(source: path, channels: channels, cached: true),
        );
    }
  }

  Future<void> _deleteSource(PlaylistSource source) async {
    final deletingOpenSource =
        activeSource?.id == source.id || playerSource?.id == source.id;
    if (deletingOpenSource) {
      await _stopPlayback();
    }
    if (!mounted) return;
    setState(() {
      sources = sources.where((item) => item.id != source.id).toList();
      if (activeSource?.id == source.id) {
        activeSource = null;
      }
      if (playerSource?.id == source.id) {
        playerSource = null;
      }
    });
    await _saveSources();
  }

  Future<void> _upsertSource(PlaylistSource source) async {
    setState(() {
      sources = [source, ...sources];
    });
    await _saveSources();
  }

  Future<void> _replaceSource(PlaylistSource source) async {
    setState(() {
      sources = sources
          .map((item) => item.id == source.id ? source : item)
          .toList();
      if (activeSource?.id == source.id) {
        activeSource = source;
      }
      if (playerSource?.id == source.id) {
        playerSource = source;
      }
    });
    await _saveSources();
  }

  Future<void> _openSource(PlaylistSource source) async {
    if (activeSource?.id != source.id || nowPlaying != null) {
      await _stopPlayback();
    }
    if (!mounted) return;
    setState(() {
      activeSource = source;
      playerSource = source;
      activeGroup = allChannels;
      search = '';
    });
  }

  Future<void> _showSourcesPage() async {
    await _stopPlayback();
    if (!mounted) return;
    setState(() {
      activeSource = null;
      fullscreen = false;
    });
    cursorHideTimer?.cancel();
    if (cursorHidden) setState(() => cursorHidden = false);
  }

  // Returns false when the stream is a format the bundled libmpv can't open
  // without crashing the whole process (currently MPEG-DASH). Fetches a small
  // prefix with a short timeout so a healthy stream isn't delayed much, and
  // returns true (play it) on any uncertainty so a flaky probe never blocks a
  // good channel.
  Future<bool> _isNativeSafeStream(String url) async {
    final uri = Uri.tryParse(url);
    // Only HTTP(S) endpoints can serve a DASH manifest; let mpv handle
    // everything else (file, udp, rtp, ...) directly.
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
      // Read only a small prefix, then stop pulling from the socket so we never
      // start downloading an actual live stream here.
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

  Future<void> _play(Channel channel) async {
    final request = ++playbackRequest;
    reconnectTimer?.cancel();
    connectTimer?.cancel();
    reconnecting = false;
    reconnectAttempts = 0;
    _everPlayed = false;
    _failureLabel = null;
    _clearFreezeFrame();
    streamUrlController.text = channel.url;
    debugPrint('Playing: ${channel.name} - ${channel.url}');
    setState(() {
      nowPlaying = channel;
      videoParams = const VideoParams();
      selectedTrack = const Track();
      position = Duration.zero;
      duration = Duration.zero;
      _seeking = false;
    });
    await player.stop();
    if (!mounted || request != playbackRequest) return;

    // ClearKey-protected MPEG-DASH: libmpv can't decrypt CENC, so route the
    // stream through the local proxy which fetches, decrypts (AES-128-CTR) and
    // rewrites segments to clear fMP4. mpv then plays the proxy's local
    // manifest. Plain streams keep using their origin URL directly.
    var streamUrl = channel.url;
    if (channel.isEncryptedDash) {
      try {
        streamUrl = await _clearKeyProxy.start(channel.url, channel.clearKeys);
        debugPrint('ClearKey proxy started: $streamUrl');
      } catch (error) {
        debugPrint('ClearKey proxy failed to start: $error');
        if (!mounted || request != playbackRequest) return;
        setState(() => _failureLabel = 'Load error');
        return;
      }
    } else {
      await _clearKeyProxy.stop();
    }
    if (!mounted || request != playbackRequest) return;

    // The bundled libmpv's ffmpeg segfaults the whole process on some
    // MPEG-DASH manifests (a native crash we can't catch). Sniff the response
    // first: if it's DASH, don't hand it to mpv — show "Load error" in the
    // control bar. Best-effort; a probe failure falls through to a normal open
    // so healthy streams are never blocked.
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
    if (!mounted || request != playbackRequest) return;
    if (!nativeSafe) {
      setState(() => _failureLabel = 'Load error');
      try {
        await player.stop();
      } catch (_) {}
      return;
    }

    _activeStreamUrl = streamUrl;
    await _applyPlaybackOptions();
    if (!mounted || request != playbackRequest) return;
    await player.open(Media(streamUrl));
    // No connection watchdog: slow-starting streams (e.g. DASH going through
    // the local decrypting proxy, or channels behind slow CDNs) can take a
    // while to render the first frame, and we don't want to kill them early.
    // A genuine hard failure still surfaces via the player error/completed
    // handlers.
    connectTimer?.cancel();
  }

  // Marks the current stream as genuinely playing (decoded frames/advancing
  // position). Clears any failure state, and — if this confirmation is a
  // reconnect resuming — drops the freeze frame.
  // Cheap and idempotent, so it's safe to call from high-frequency streams.
  void _confirmPlaybackStarted() {
    _everPlayed = true;
    reconnectAttempts = 0;
    connectTimer?.cancel();
    connectTimer = null;
    final needsRebuild = _failureLabel != null || reconnecting;
    _failureLabel = null;
    if (reconnecting) {
      reconnecting = false;
      _clearFreezeFrame();
    }
    if (needsRebuild && mounted) setState(() {});
  }

  // Marks the current channel as failed to load: shows "Load error" in the
  // control bar, cancels the connection watchdog, and stops the player to free
  // decoder/network resources. nowPlaying is kept so the status stays visible.
  // No-op once playback has started or a failure is already recorded.
  void _failLoad() {
    if (!mounted || nowPlaying == null || _everPlayed || _failureLabel != null) {
      return;
    }
    connectTimer?.cancel();
    connectTimer = null;
    setState(() => _failureLabel = 'Load error');
    unawaited(player.stop().catchError((_) {}));
  }

  void _scheduleReconnect() {
    // reconnecting is set true by the caller; only guard channel/attempt limits.
    if (nowPlaying == null) return;
    if (reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('Reconnect: giving up after $reconnectAttempts attempts');
      if (mounted) setState(() => reconnecting = false);
      return;
    }
    reconnectAttempts++;
    final request = playbackRequest;
    // Reconnect quickly on the first try (segment gap), then back off if the
    // stream is genuinely struggling, capped at 5s.
    final delay = reconnectAttempts <= 1
        ? const Duration(milliseconds: 200)
        : Duration(seconds: reconnectAttempts.clamp(1, 5));
    reconnectTimer?.cancel();
    reconnectTimer = Timer(delay, () {
      _reconnectStream(request);
    });
  }

  Future<void> _reconnectStream(int request) async {
    final channel = nowPlaying;
    // Abort if playback was stopped or another channel was opened meanwhile.
    if (!mounted || channel == null || request != playbackRequest) {
      reconnecting = false;
      return;
    }
    // For ClearKey DASH this is the proxy's local manifest URL (still valid, as
    // the proxy keeps running); for plain streams it's the origin URL.
    final reloadUrl = _activeStreamUrl.isNotEmpty
        ? _activeStreamUrl
        : channel.url;
    debugPrint(
      'Reconnecting stream (attempt $reconnectAttempts): $reloadUrl',
    );
    try {
      await _applyPlaybackOptions();
      if (!mounted || request != playbackRequest) return;
      // Keep reconnecting=true (freeze frame + spinner stay up) until the
      // playing event confirms the new segment is rendering.
      //
      // Prefer mpv's `loadfile <url> replace`: it swaps the source while
      // keeping the existing video output texture, so the last decoded frame
      // stays on screen with no black flash. player.open() tears the texture
      // down and flashes black, so it's only the fallback.
      final platform = player.platform;
      var replaced = false;
      if (platform != null) {
        try {
          await (platform as dynamic).command([
            'loadfile',
            reloadUrl,
            'replace',
          ]);
          await player.play();
          replaced = true;
        } catch (e) {
          debugPrint('loadfile replace failed, falling back to open: $e');
        }
      }
      if (!replaced) {
        if (!mounted || request != playbackRequest) return;
        await player.open(Media(reloadUrl));
      }
    } catch (error) {
      debugPrint('Reconnect failed: $error');
      // Retry with backoff while the freeze frame remains on screen.
      if (mounted && request == playbackRequest) {
        _scheduleReconnect();
      }
    }
  }

  Future<void> _stopPlayback() async {
    playbackRequest++;
    reconnectTimer?.cancel();
    connectTimer?.cancel();
    reconnecting = false;
    reconnectAttempts = 0;
    _everPlayed = false;
    _failureLabel = null;
    _activeStreamUrl = '';
    _clearFreezeFrame();
    unawaited(_clearKeyProxy.stop());
    streamUrlController.clear();
    try {
      await player.stop();
    } catch (error) {
      _showMessage('Failed to stop playback: $error');
    }
    if (!mounted) return;
    setState(() {
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
    });
    cursorHideTimer?.cancel();
    if (cursorHidden) setState(() => cursorHidden = false);
  }

  Future<void> _togglePlayPause() async {
    if (nowPlaying == null) return;
    try {
      await player.playOrPause();
    } catch (error) {
      _showMessage('Failed to toggle playback: $error');
    }
  }

  // Called continuously while dragging so the thumb tracks the pointer without
  // committing the seek until the drag ends.
  void _onSeekChanged(double seconds) {
    setState(() {
      _seeking = true;
      _seekTarget = Duration(milliseconds: (seconds * 1000).round());
      position = _seekTarget;
    });
  }

  Future<void> _onSeekEnd(double seconds) async {
    final target = Duration(milliseconds: (seconds * 1000).round());
    setState(() {
      position = target;
      _seeking = false;
    });
    try {
      await player.seek(target);
    } catch (error) {
      _showMessage('Failed to seek: $error');
    }
  }

  Future<void> _setVolume(double value) async {
    final next = value.clamp(0.0, 100.0);
    setState(() {
      volume = next;
      muted = next == 0;
    });
    try {
      await player.setVolume(next);
    } catch (_) {}
  }

  Future<void> _toggleMute() async {
    if (muted || volume == 0) {
      final restore = _volumeBeforeMute <= 0 ? 100.0 : _volumeBeforeMute;
      await _setVolume(restore);
    } else {
      _volumeBeforeMute = volume;
      await _setVolume(0);
    }
  }

  Future<void> _takeSnapshot() async {
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
    // Save next to the executable under a Snapshots folder so it's easy to find
    // regardless of where the portable app lives.
    final base = File(Platform.resolvedExecutable).parent.path;
    final dir = Directory('$base\\Snapshots');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  double get _videoAspectRatio {
    final track = selectedTrack.video;
    final width = videoParams.dw ?? videoParams.w ?? track.w;
    final height = videoParams.dh ?? videoParams.h ?? track.h;
    if (width != null && height != null && height > 0) {
      return width / height;
    }
    return 16 / 9;
  }

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

  // Value for mpv's `demuxer-lavf-o`. Left empty: ClearKey DASH is decrypted
  // by the local proxy (which strips all encryption boxes) before mpv sees it,
  // so no FFmpeg-side `decryption_key` is needed. FFmpeg's `decryption_key`
  // doesn't propagate to the DASH demuxer's child segments anyway.
  String _lavfOptionsFor(Channel? channel) => '';

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
      // media_kit sizes mpv's backward demuxer cache from `bufferSize` too, so
      // it grows toward tens of MiB the entire time a stream plays. Live IPTV
      // can never seek backward, so that buffer is pure wasted RAM that makes
      // memory climb steadily during playback. Cap it hard.
      'demuxer-max-back-bytes': (4 * 1024 * 1024).toString(),
      // ClearKey DRM: hand the content key to FFmpeg's demuxer so it can
      // decrypt CENC (AES-128-CTR) fragments inline. Set to empty for
      // unprotected streams so a key from a previous channel never lingers.
      // MPEG-CENC content keys are passed as a bare hex string via
      // `decryption_key`.
      'demuxer-lavf-o': _lavfOptionsFor(nowPlaying),
    };

    for (final option in options.entries) {
      try {
        await (platform as dynamic).setProperty(option.key, option.value);
        debugPrint('Applied option: ${option.key}=${option.value}');
      } catch (e) {
        debugPrint('Failed to apply ${option.key}: $e');
      }
    }

    // Verify hwdec status
    try {
      final current =
          await (platform as dynamic).getProperty('hwdec-current') as String?;
      debugPrint('After apply: hwdec-current=$current');
    } catch (_) {}
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

  Future<void> _toggleFullscreen() async {
    if (fullscreenChanging) return;
    fullscreenChanging = true;
    final nextFullscreen = !fullscreen;
    setState(() => fullscreen = nextFullscreen);
    try {
      await windowManager.setFullScreen(nextFullscreen);
      final actualFullscreen = await windowManager.isFullScreen();
      if (mounted && actualFullscreen != fullscreen) {
        setState(() => fullscreen = actualFullscreen);
      }
    } catch (_) {
      if (mounted) {
        setState(() => fullscreen = !nextFullscreen);
      }
      rethrow;
    } finally {
      fullscreenChanging = false;
      _syncCursorHiding();
    }
  }

  // Schedules the cursor to hide while fullscreen, or restores it otherwise.
  // Call whenever the fullscreen state changes.
  void _syncCursorHiding() {
    cursorHideTimer?.cancel();
    if (fullscreen) {
      playerFocusNode.requestFocus();
      _scheduleCursorHide();
    } else if (cursorHidden) {
      setState(() => cursorHidden = false);
    }
  }

  void _scheduleCursorHide() {
    cursorHideTimer?.cancel();
    cursorHideTimer = Timer(_cursorHideDelay, () {
      if (mounted && fullscreen && !cursorHidden) {
        setState(() => cursorHidden = true);
      }
    });
  }

  // Called on any mouse movement or click. Reveals the cursor (if hidden) and
  // restarts the inactivity timer while fullscreen.
  void _handlePointerActivity() {
    if (!fullscreen) return;
    if (cursorHidden) {
      setState(() => cursorHidden = false);
    }
    _scheduleCursorHide();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape && fullscreen && !fullscreenChanging) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }

    // Transport shortcuts only apply while a channel is loaded.
    if (nowPlaying == null) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      _stopPlayback();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      if (!fullscreenChanging) _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _setVolume(volume + 5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _setVolume(volume - 5);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final source = activeSource ?? playerSource;
    if (source == null) {
      return _buildSourcesPage();
    }
    return Stack(
      children: [
        _buildPlayerPage(source),
        if (activeSource == null) _buildSourcesPage(),
      ],
    );
  }

  Widget _buildSourcesPage() {
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
            child: Row(
              children: [
                const _HeaderBrand(),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: _addLocalSource,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Load M3U File'),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: _addOnlineSource,
                  icon: const Icon(Icons.link),
                  label: const Text('Online M3U Link'),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: _addSingleChannel,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Single Channel'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: refreshingAll ? null : _refreshAllSources,
                  icon: SizedBox(
                    width: 18,
                    height: 18,
                    child: Center(
                      child: refreshingAll
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                    ),
                  ),
                  label: const Text('Refresh All'),
                ),
              ],
            ),
          ),
          if (availableUpdate != null) _buildUpdateBanner(),
          Expanded(
            child: sources.isEmpty
                ? const Center(
                    child: Text(
                      'Create a source to start watching.',
                      style: TextStyle(color: Color(0xff7d8490)),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                    itemBuilder: (context, index) {
                      final source = sources[index];
                      return _SourceTile(
                        source: source,
                        onOpen: () => _openSource(source),
                        onRefresh: source.kind == SourceKind.single
                            ? null
                            : () => _refreshSource(source),
                        isRefreshing: refreshingSourceIds.contains(source.id),
                        onRename: () => _renameSource(source),
                        onDelete: () => _deleteSource(source),
                      );
                    },
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemCount: sources.length,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateBanner() {
    final release = availableUpdate!;
    final progressPercent = updateProgress == null
        ? null
        : (updateProgress! * 100).clamp(0, 100).toStringAsFixed(0);
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xffeef0ff),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xffc7c2ff)),
      ),
      child: Row(
        children: [
          const Icon(Icons.system_update, color: Color(0xff6b5bff)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  updating
                      ? (progressPercent == null
                            ? 'Downloading update...'
                            : 'Downloading update... $progressPercent%')
                      : 'New version ${release.tag} available',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (updating && updateProgress != null) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: updateProgress),
                  ),
                ] else if (!updating)
                  const Text(
                    'The update zip will be saved to the app folder for you to install.',
                    style: TextStyle(color: Color(0xff7d8490), fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (updating)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            TextButton(
              onPressed: () => setState(() => availableUpdate = null),
              child: const Text('Later'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _startUpdate,
              icon: const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ],
        ],
      ),
    );
  }

  // Cache of the last group/search filter so the potentially huge channel
  // filter (and the downstream duplicate-name scan in _ChannelList) doesn't
  // rerun on every position/bitrate tick that rebuilds the page. Returns the
  // same list instance until the inputs actually change, which also lets
  // _ChannelList skip its rescan via its identical() guard.
  List<Channel> _visibleChannelsCache = const [];
  String? _visibleChannelsKey;

  List<Channel> _computeVisibleChannels(PlaylistSource source) {
    final key =
        '${source.id}|${identityHashCode(source.channels)}|$activeGroup|$search';
    if (key == _visibleChannelsKey) return _visibleChannelsCache;
    final query = search.trim().toLowerCase();
    final filtered = source.channels.where((channel) {
      final matchesGroup =
          activeGroup == allChannels || channel.group == activeGroup;
      final matchesSearch =
          query.isEmpty || channel.name.toLowerCase().contains(query);
      return matchesGroup && matchesSearch;
    }).toList();
    _visibleChannelsKey = key;
    _visibleChannelsCache = filtered;
    return filtered;
  }

  Widget _buildPlayerPage(PlaylistSource source) {
    final groups = source.groups;
    final visibleChannels = _computeVisibleChannels(source);

    return Focus(
      focusNode: playerFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        cursor: (fullscreen && cursorHidden)
            ? SystemMouseCursors.none
            : MouseCursor.defer,
        onHover: (_) => _handlePointerActivity(),
        child: Listener(
          onPointerDown: (_) => _handlePointerActivity(),
          onPointerMove: (_) => _handlePointerActivity(),
          onPointerSignal: (_) => _handlePointerActivity(),
          child: Scaffold(
            backgroundColor: fullscreen
                ? Colors.black
                : const Color(0xfff6f8fc),
            body: Row(
        children: [
          SizedBox(
            width: fullscreen ? 0 : 190,
            child: ClipRect(
              child: IgnorePointer(
                ignoring: fullscreen,
                child: fullscreen
                    ? const SizedBox.shrink()
                    : _Sidebar(
                        source: source,
                        groups: groups,
                        activeGroup: activeGroup,
                        onBack: () => _showSourcesPage(),
                        onSearch: (value) => setState(() => search = value),
                        onGroup: (group) => setState(() => activeGroup = group),
                      ),
              ),
            ),
          ),
          SizedBox(
            width: fullscreen ? 0 : 250,
            child: ClipRect(
              child: IgnorePointer(
                ignoring: fullscreen,
                child: Visibility(
                  visible: !fullscreen,
                  maintainState: true,
                  maintainAnimation: true,
                  maintainSize: false,
                  child: _ChannelList(
                    title: activeGroup,
                    channels: visibleChannels,
                    // The sidebar already shows the selected group, so the
                    // per-channel group label is redundant — except while
                    // searching, where results span groups.
                    showGroup: search.trim().isNotEmpty,
                    selected: nowPlaying,
                    scrollController: channelScrollController,
                    onPlay: _play,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: AnimatedPadding(
              duration: fullscreenAnimationDuration,
              curve: fullscreenAnimationCurve,
              padding: fullscreen ? EdgeInsets.zero : const EdgeInsets.all(14),
              child: Column(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onDoubleTap: _toggleFullscreen,
                      child: Center(
                          child: AspectRatio(
                            aspectRatio: _videoAspectRatio,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Video(
                                  controller: videoController,
                                  fit: BoxFit.contain,
                                  controls: NoVideoControls,
                                  subtitleViewConfiguration:
                                      const SubtitleViewConfiguration(
                                        visible: false,
                                      ),
                                ),
                                // Hold the last decoded frame over the video
                                // while reconnecting so a segmented stream
                                // doesn't flash black between segments.
                                if (reconnecting && lastFrame != null)
                                  Positioned.fill(
                                    child: Image.memory(
                                      lastFrame!,
                                      fit: BoxFit.contain,
                                      gaplessPlayback: true,
                                    ),
                                  ),
                                // Buffering/loading spinner shown over the
                                // frozen frame while the next segment loads,
                                // so it's clear playback is reconnecting and
                                // not stalled.
                                if (reconnecting)
                                  const Positioned.fill(
                                    child: Center(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.all(
                                            Radius.circular(16),
                                          ),
                                        ),
                                        child: Padding(
                                          padding: EdgeInsets.all(20),
                                          child: SizedBox(
                                            width: 48,
                                            height: 48,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 3,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    Color(0xff8357f7),
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                // Auto-hiding transport overlay for fullscreen,
                                // where the sidebar controls aren't visible.
                                if (fullscreen)
                                  _FullscreenControls(
                                    visible: !cursorHidden,
                                    isPlaying: isPlaying,
                                    muted: muted,
                                    title: nowPlaying?.name,
                                    position: position,
                                    duration: duration,
                                    onSeekChanged: nowPlaying == null
                                        ? null
                                        : _onSeekChanged,
                                    onSeekEnd: nowPlaying == null
                                        ? null
                                        : _onSeekEnd,
                                    onPlayPause: nowPlaying == null
                                        ? null
                                        : _togglePlayPause,
                                    onStop: nowPlaying == null
                                        ? null
                                        : _stopPlayback,
                                    onMute: nowPlaying == null
                                        ? null
                                        : _toggleMute,
                                    onSnapshot: nowPlaying == null
                                        ? null
                                        : _takeSnapshot,
                                    onExitFullscreen: _toggleFullscreen,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!fullscreen)
                    _PlaybackControls(
                      streamUrlController: streamUrlController,
                      nowPlaying: nowPlaying,
                      playbackInfo: playbackInfo,
                      isPlaying: isPlaying,
                      muted: muted,
                      volume: volume,
                      position: position,
                      duration: duration,
                      onSeekChanged: nowPlaying == null ? null : _onSeekChanged,
                      onSeekEnd: nowPlaying == null ? null : _onSeekEnd,
                      hwActive:
                          hwdecCurrent != null &&
                          hwdecCurrent!.isNotEmpty &&
                          hwdecCurrent != 'no',
                      onReplay: nowPlaying == null
                          ? null
                          : () => _play(nowPlaying!),
                      onPlayPause: nowPlaying == null ? null : _togglePlayPause,
                      onStop: nowPlaying == null ? null : _stopPlayback,
                      onMute: nowPlaying == null ? null : _toggleMute,
                      onVolume: nowPlaying == null ? null : _setVolume,
                      onSnapshot: nowPlaying == null ? null : _takeSnapshot,
                      onFullscreen: _toggleFullscreen,
                    ),
                ],
              ),
            ),
          ),
        ],
            ),
          ),
        ),
      ),
    );
  }
}

class SourceDialogResult {
  const SourceDialogResult(this.name, this.source);
  final String name;
  final String source;
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.streamUrlController,
    required this.nowPlaying,
    required this.playbackInfo,
    required this.isPlaying,
    required this.muted,
    required this.volume,
    required this.position,
    required this.duration,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.hwActive,
    required this.onReplay,
    required this.onPlayPause,
    required this.onStop,
    required this.onMute,
    required this.onVolume,
    required this.onSnapshot,
    required this.onFullscreen,
  });

  final TextEditingController streamUrlController;
  final Channel? nowPlaying;
  final String playbackInfo;
  final bool isPlaying;
  final bool muted;
  final double volume;
  final Duration position;
  final Duration duration;
  final ValueChanged<double>? onSeekChanged;
  final ValueChanged<double>? onSeekEnd;
  final bool hwActive;
  final VoidCallback? onReplay;
  final VoidCallback? onPlayPause;
  final VoidCallback? onStop;
  final VoidCallback? onMute;
  final ValueChanged<double>? onVolume;
  final VoidCallback? onSnapshot;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final hasChannel = nowPlaying != null;
        return Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xffe9edf3)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0f000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Full channel name, shown in full (wraps instead of being
              // truncated with an ellipsis).
              if (hasChannel && (nowPlaying?.name.isNotEmpty ?? false)) ...[
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    nowPlaying!.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xff2b2f36),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              // Compact, read-only URL pill. Kept selectable so the current
              // stream address can still be copied.
              SizedBox(
                height: 34,
                child: TextField(
                  controller: streamUrlController,
                  readOnly: true,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xff5f6772),
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xfff2f4f8),
                    hintText: 'Stream URL',
                    hintStyle: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xffb0b7c3),
                    ),
                    prefixIcon: const Icon(
                      Icons.link_rounded,
                      size: 17,
                      color: Color(0xffb0b7c3),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 0,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              // Draggable playback progress bar (VOD seeking). Shows a "LIVE"
              // indicator for streams with no known duration.
              _SeekBar(
                position: position,
                duration: duration,
                onChanged: onSeekChanged,
                onChangeEnd: onSeekEnd,
              ),
              // Transport bar: play/pause, stop, reload, volume, then status,
              // HW badge, snapshot and fullscreen.
              Row(
                children: [
                  _TransportButton(
                    icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    tooltip: isPlaying ? 'Pause (Space)' : 'Play (Space)',
                    onPressed: onPlayPause,
                    primary: true,
                  ),
                  _TransportButton(
                    icon: Icons.stop_rounded,
                    tooltip: 'Stop (S)',
                    onPressed: onStop,
                  ),
                  _TransportButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Reload stream',
                    onPressed: onReplay,
                  ),
                  const SizedBox(width: 6),
                  _TransportButton(
                    icon: muted || volume == 0
                        ? Icons.volume_off_rounded
                        : volume < 50
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded,
                    tooltip: muted ? 'Unmute (M)' : 'Mute (M)',
                    onPressed: onMute,
                  ),
                  SizedBox(
                    width: compact ? 72 : 110,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                      ),
                      child: Slider(
                        value: volume.clamp(0, 100),
                        max: 100,
                        onChanged: hasChannel ? onVolume : null,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 30,
                    child: Text(
                      '${volume.round()}',
                      style: const TextStyle(
                        color: Color(0xff7d8490),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      playbackInfo,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xff7d8490),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: hwActive
                          ? const Color(0x1a8357f7)
                          : const Color(0xffeef0f4),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      hwActive ? 'HW' : 'SW',
                      style: TextStyle(
                        color: hwActive
                            ? const Color(0xff8357f7)
                            : const Color(0xff7d8490),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _TransportButton(
                    icon: Icons.photo_camera_outlined,
                    tooltip: 'Snapshot',
                    onPressed: onSnapshot,
                  ),
                  _TransportButton(
                    icon: Icons.fullscreen_rounded,
                    tooltip: 'Fullscreen (F / double-click)',
                    onPressed: onFullscreen,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Compact icon button used across the transport bars.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.primary = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  // Highlights the button with the accent color (used for play/pause).
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final resolvedColor =
        color ?? (primary ? const Color(0xff8357f7) : const Color(0xff5f6772));
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
      color: resolvedColor,
      iconSize: primary ? 24 : 20,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
      splashRadius: 20,
    );
  }
}

/// Draggable playback progress bar with elapsed/remaining time labels.
///
/// For live streams the player reports a zero duration; in that case the bar
/// is replaced with a non-interactive "LIVE" indicator since seeking isn't
/// meaningful.
class _SeekBar extends StatelessWidget {
  const _SeekBar({
    required this.position,
    required this.duration,
    required this.onChanged,
    required this.onChangeEnd,
    this.dark = false,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final bool dark;

  static String _format(Duration d) {
    final negative = d.isNegative;
    final value = negative ? -d : d;
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
    final ss = seconds.toString().padLeft(2, '0');
    final body = hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
    return negative ? '-$body' : body;
  }

  @override
  Widget build(BuildContext context) {
    final textColor = dark ? Colors.white70 : const Color(0xff7d8490);
    final totalMs = duration.inMilliseconds;
    final isLive = totalMs <= 0;
    final labelStyle = TextStyle(
      color: textColor,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    if (isLive) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xffe53935),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text('LIVE', style: labelStyle),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: dark ? Colors.white24 : const Color(0xffe0e0e0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final positionMs = position.inMilliseconds.clamp(0, totalMs).toDouble();
    final enabled = onChanged != null;
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            _format(position),
            textAlign: TextAlign.center,
            style: labelStyle,
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: dark ? Colors.white : null,
              thumbColor: dark ? Colors.white : null,
              inactiveTrackColor: dark ? Colors.white30 : null,
            ),
            child: Slider(
              value: positionMs,
              max: totalMs.toDouble(),
              onChanged: enabled
                  ? (value) => onChanged!(value / 1000)
                  : null,
              onChangeEnd: enabled && onChangeEnd != null
                  ? (value) => onChangeEnd!(value / 1000)
                  : null,
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            _format(duration),
            textAlign: TextAlign.center,
            style: labelStyle,
          ),
        ),
      ],
    );
  }
}

/// Auto-hiding transport overlay shown over the video while in fullscreen.
class _FullscreenControls extends StatelessWidget {
  const _FullscreenControls({
    required this.visible,
    required this.isPlaying,
    required this.muted,
    required this.title,
    required this.position,
    required this.duration,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onPlayPause,
    required this.onStop,
    required this.onMute,
    required this.onSnapshot,
    required this.onExitFullscreen,
  });

  final bool visible;
  final bool isPlaying;
  final bool muted;
  final String? title;
  final Duration position;
  final Duration duration;
  final ValueChanged<double>? onSeekChanged;
  final ValueChanged<double>? onSeekEnd;
  final VoidCallback? onPlayPause;
  final VoidCallback? onStop;
  final VoidCallback? onMute;
  final VoidCallback? onSnapshot;
  final VoidCallback? onExitFullscreen;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xcc000000), Color(0x00000000)],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SeekBar(
                  position: position,
                  duration: duration,
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                  dark: true,
                ),
                Row(
                  children: [
                    _TransportButton(
                      icon: isPlaying ? Icons.pause : Icons.play_arrow,
                      tooltip: isPlaying ? 'Pause (Space)' : 'Play (Space)',
                      onPressed: onPlayPause,
                      color: Colors.white,
                    ),
                    _TransportButton(
                      icon: Icons.stop,
                      tooltip: 'Stop (S)',
                      onPressed: onStop,
                      color: Colors.white,
                    ),
                    _TransportButton(
                      icon: muted ? Icons.volume_off : Icons.volume_up,
                      tooltip: muted ? 'Unmute (M)' : 'Mute (M)',
                      onPressed: onMute,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _TransportButton(
                      icon: Icons.photo_camera_outlined,
                      tooltip: 'Snapshot',
                      onPressed: onSnapshot,
                      color: Colors.white,
                    ),
                    _TransportButton(
                      icon: Icons.fullscreen_exit,
                      tooltip: 'Exit fullscreen (F / Esc)',
                      onPressed: onExitFullscreen,
                      color: Colors.white,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<SourceDialogResult?> showSourceDialog(
  BuildContext context, {
  required String title,
  required String urlLabel,
}) async {
  final name = TextEditingController();
  final source = TextEditingController();
  return showDialog<SourceDialogResult>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: source,
              decoration: InputDecoration(labelText: urlLabel),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final nextName = name.text.trim();
            final nextSource = source.text.trim();
            if (nextName.isEmpty || nextSource.isEmpty) return;
            Navigator.pop(context, SourceDialogResult(nextName, nextSource));
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

sealed class EditSourceResult {}

class EditSourceResultName extends EditSourceResult {
  EditSourceResultName(this.name);
  final String name;
}

class EditSourceResultUrl extends EditSourceResult {
  EditSourceResultUrl(this.url, {this.name});
  final String url;
  final String? name;
}

class EditSourceResultFile extends EditSourceResult {
  EditSourceResultFile(this.path, this.channels, {this.name});
  final String path;
  final List<Channel> channels;
  final String? name;
}

Future<EditSourceResult?> showEditSourceDialog(
  BuildContext context, {
  required PlaylistSource source,
}) async {
  return showDialog<EditSourceResult>(
    context: context,
    builder: (context) => _EditSourceDialog(source: source),
  );
}

class _EditSourceDialog extends StatefulWidget {
  const _EditSourceDialog({required this.source});
  final PlaylistSource source;

  @override
  State<_EditSourceDialog> createState() => _EditSourceDialogState();
}

class _EditSourceDialogState extends State<_EditSourceDialog> {
  late TextEditingController nameController;
  late TextEditingController urlController;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.source.name);
    urlController = TextEditingController(text: widget.source.source);
  }

  @override
  void dispose() {
    nameController.dispose();
    urlController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Load M3U File',
        type: FileType.custom,
        allowedExtensions: const ['m3u', 'm3u8', 'txt'],
        withData: true,
        lockParentWindow: true,
      );
      final file = result?.files.single;
      if (file == null) return;

      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) return;
      final text = await decodePlaylistBytes(bytes);
      final channels = parsePlaylist(text);
      if (channels.isEmpty) return;
      if (!mounted) return;
      Navigator.pop(
        context,
        EditSourceResultFile(file.path ?? file.name, channels),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = widget.source.kind == SourceKind.local;
    return AlertDialog(
      title: const Text('Edit Source'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            if (!isLocal) ...[
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(labelText: 'URL'),
              ),
            ],
            if (isLocal) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Load different M3U file'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = nameController.text.trim();
            final url = urlController.text.trim();
            final nameChanged = name.isNotEmpty && name != widget.source.name;
            final urlChanged =
                !isLocal && url.isNotEmpty && url != widget.source.source;
            if (urlChanged) {
              Navigator.pop(
                context,
                EditSourceResultUrl(url, name: nameChanged ? name : null),
              );
            } else if (nameChanged) {
              Navigator.pop(context, EditSourceResultName(name));
            }
          },
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

extension on PlaylistSource {
  Map<String, int> get groups {
    final map = <String, int>{allChannels: channels.length};
    for (final channel in channels) {
      map[channel.group] = (map[channel.group] ?? 0) + 1;
    }
    return map;
  }
}

List<Channel> parsePlaylist(String text) {
  final lines = const LineSplitter()
      .convert(text)
      .map((line) => line.trim())
      .toList();
  final channels = <Channel>[];
  var pendingName = '';
  var pendingGroup = ungroupedGroup;
  String? pendingLogo;
  String? extGrp;
  String? pendingManifestType;
  String? pendingLicenseType;
  String? pendingLicenseKey;

  void resetPending() {
    pendingName = '';
    pendingGroup = ungroupedGroup;
    pendingLogo = null;
    extGrp = null;
    pendingManifestType = null;
    pendingLicenseType = null;
    pendingLicenseKey = null;
  }

  for (final line in lines) {
    if (line.isEmpty || line == '#EXTM3U') continue;
    if (line.startsWith('#EXTGRP:')) {
      extGrp = line.substring('#EXTGRP:'.length).trim();
      continue;
    }
    // Kodi-style DRM/adaptive hints, e.g.
    //   #KODIPROP:inputstream.adaptive.manifest_type=mpd
    //   #KODIPROP:inputstream.adaptive.license_type=clearkey
    //   #KODIPROP:inputstream.adaptive.license_key=<kid>:<key>
    // Applied to the next stream URL that follows.
    if (line.startsWith('#KODIPROP:')) {
      final body = line.substring('#KODIPROP:'.length).trim();
      final eq = body.indexOf('=');
      if (eq > 0) {
        final key = body.substring(0, eq).trim().toLowerCase();
        final value = body.substring(eq + 1).trim();
        if (key.endsWith('manifest_type')) {
          pendingManifestType = value;
        } else if (key.endsWith('license_type')) {
          pendingLicenseType = value;
        } else if (key.endsWith('license_key')) {
          pendingLicenseKey = value;
        }
      }
      continue;
    }
    if (line.startsWith('#EXTINF')) {
      pendingName = _nameFromExtInf(line);
      pendingGroup =
          _attrFromExtInf(line, 'group-title') ?? extGrp ?? ungroupedGroup;
      pendingLogo = _attrFromExtInf(line, 'tvg-logo');
      continue;
    }
    if (!line.startsWith('#')) {
      channels.add(
        Channel(
          name: pendingName.isEmpty ? line : pendingName,
          url: line,
          group: pendingGroup.trim().isEmpty
              ? ungroupedGroup
              : pendingGroup.trim(),
          logo: pendingLogo,
          manifestType: pendingManifestType,
          licenseType: pendingLicenseType,
          licenseKey: pendingLicenseKey,
        ),
      );
      resetPending();
    }
  }
  return channels;
}

String _nameFromExtInf(String line) {
  final comma = line.lastIndexOf(',');
  if (comma < 0 || comma == line.length - 1) return 'Untitled Channel';
  return line.substring(comma + 1).trim();
}

String? _attrFromExtInf(String line, String name) {
  final quoted = RegExp(
    '$name="([^"]*)"',
    caseSensitive: false,
  ).firstMatch(line);
  if (quoted != null) return quoted.group(1);
  final singleQuoted = RegExp(
    "$name='([^']*)'",
    caseSensitive: false,
  ).firstMatch(line);
  if (singleQuoted != null) return singleQuoted.group(1);
  final bare = RegExp(
    '$name=([^\\s,]+)',
    caseSensitive: false,
  ).firstMatch(line);
  return bare?.group(1);
}

String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

Future<String> decodeHttpPlaylist(http.Response response) async {
  final contentType = response.headers['content-type'] ?? '';
  final charset = RegExp(
    r'charset=([^;\s]+)',
    caseSensitive: false,
  ).firstMatch(contentType)?.group(1);
  if (charset != null && charset.trim().isNotEmpty) {
    return decodePlaylistBytes(response.bodyBytes, preferredCharset: charset);
  }
  return decodePlaylistBytes(response.bodyBytes);
}

Future<String> decodePlaylistBytes(
  List<int> bytes, {
  String? preferredCharset,
}) async {
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }

  final charsets = <String>[
    ?preferredCharset,
    'utf-8',
    'gb18030',
    'gbk',
    'big5',
  ];

  for (final charset in charsets) {
    final decoded = await _tryDecodeWithCharset(bytes, charset);
    if (decoded != null && !decoded.contains('\uFFFD')) {
      return decoded;
    }
  }

  return utf8.decode(bytes, allowMalformed: true);
}

Future<String?> _tryDecodeWithCharset(List<int> bytes, String charset) async {
  try {
    if (charset.toLowerCase().replaceAll('_', '-') == 'utf-8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    return CharsetConverter.decode(charset, Uint8List.fromList(bytes));
  } catch (_) {
    return null;
  }
}

class _Logo extends StatelessWidget {
  const _Logo({this.size = 58});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          colors: [Color(0xff7c4dff), Color(0xffa156ff)],
        ),
      ),
      alignment: Alignment.center,
      child: const Text(
        'IPTV',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _HeaderBrand extends StatelessWidget {
  const _HeaderBrand();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 420),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Logo(size: 54),
          const SizedBox(width: 16),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Light IPTV Player',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                Text('v0.1.0', style: TextStyle(color: Color(0xff7d8490))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    this.onRefresh,
    this.isRefreshing = false,
  });

  final PlaylistSource source;
  final VoidCallback onOpen;
  final VoidCallback? onRefresh;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xffd9c7ff), width: 1.4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0f7c4dff),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              const _Logo(size: 46),
              const SizedBox(width: 14),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    _Tag(
                      label: switch (source.kind) {
                        SourceKind.local => 'Local File',
                        SourceKind.online => 'Online Link',
                        SourceKind.single => 'Quick Test',
                      },
                    ),
                    if (source.cached) const _Tag(label: 'Cached', green: true),
                    Text(
                      '${source.channels.length} channels',
                      style: const TextStyle(color: Color(0xff7d8490)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Wrap(
                spacing: 2,
                children: [
                  if (onRefresh != null)
                    IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 38,
                        height: 38,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: isRefreshing ? null : onRefresh,
                      icon: isRefreshing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  IconButton(
                    constraints: const BoxConstraints.tightFor(
                      width: 38,
                      height: 38,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: onRename,
                    icon: const Icon(Icons.edit),
                  ),
                  IconButton(
                    constraints: const BoxConstraints.tightFor(
                      width: 38,
                      height: 38,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete, color: Color(0xffe0001b)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.green = false});
  final String label;
  final bool green;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: green ? const Color(0xffe5fff4) : const Color(0xfff0e8ff),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: green ? const Color(0xff76d7ba) : const Color(0xffcdb7ff),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: green ? const Color(0xff0b9b6b) : const Color(0xff8357f7),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.source,
    required this.groups,
    required this.activeGroup,
    required this.onBack,
    required this.onSearch,
    required this.onGroup,
  });

  final PlaylistSource source;
  final Map<String, int> groups;
  final String activeGroup;
  final VoidCallback onBack;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onGroup;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xffeef1f6),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onBack,
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Text('← Sources'),
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            onChanged: onSearch,
            decoration: const InputDecoration(
              filled: true,
              fillColor: Colors.white,
              hintText: 'Search channels',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          const Divider(),
          Text(
            source.name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          Text(
            '${groups.length - 1} groups',
            style: const TextStyle(color: Color(0xff7d8490)),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              children: groups.entries.map((entry) {
                final selected = entry.key == activeGroup;
                return _GroupTile(
                  label: entry.key,
                  count: entry.value,
                  selected: selected,
                  onTap: () => onGroup(entry.key),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelList extends StatefulWidget {
  const _ChannelList({
    required this.title,
    required this.channels,
    required this.selected,
    required this.scrollController,
    required this.onPlay,
    this.showGroup = false,
  });

  final String title;
  final List<Channel> channels;
  final Channel? selected;
  final ScrollController scrollController;
  final ValueChanged<Channel> onPlay;
  final bool showGroup;

  @override
  State<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<_ChannelList> {
  // Names that appear on more than one channel get a "routes" tag. Computed
  // once whenever the channel list changes instead of rescanning the entire
  // list inside every visible tile (which made large playlists freeze while
  // scrolling).
  late Set<String> _duplicateNames;

  // Logos are remote images. Loading them for every tile that flies past
  // during a fast scroll spawns a storm of HTTP requests + decodes that
  // freezes the UI. So we only load logos once scrolling has settled.
  bool _scrolling = false;
  Timer? _scrollIdleTimer;

  @override
  void initState() {
    super.initState();
    _computeDuplicateNames();
  }

  @override
  void didUpdateWidget(_ChannelList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.channels, widget.channels)) {
      _computeDuplicateNames();
    }
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    super.dispose();
  }

  void _computeDuplicateNames() {
    final seen = <String>{};
    final duplicates = <String>{};
    for (final channel in widget.channels) {
      if (!seen.add(channel.name)) {
        duplicates.add(channel.name);
      }
    }
    _duplicateNames = duplicates;
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      _scrollIdleTimer?.cancel();
      _scrollIdleTimer = Timer(const Duration(milliseconds: 120), () {
        if (mounted && _scrolling) setState(() => _scrolling = false);
      });
    } else if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification) {
      _scrollIdleTimer?.cancel();
      if (!_scrolling) setState(() => _scrolling = true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final channels = widget.channels;
    return Container(
      color: const Color(0xfff4efff),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  '${channels.length} channels',
                  style: const TextStyle(color: Color(0xff7d8490)),
                ),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: ListView.builder(
                controller: widget.scrollController,
                itemCount: channels.length,
                // Fixed row height makes scrollbar dragging O(1) and exact:
                // the list can jump straight to any offset without measuring
                // every row, which is what made big drags freeze.
                itemExtent: _channelRowHeight,
                itemBuilder: (context, index) {
                  final channel = channels[index];
                  final selectedChannel = widget.selected?.url == channel.url;
                  return _ChannelTile(
                    channel: channel,
                    selected: selectedChannel,
                    hasRoutes: _duplicateNames.contains(channel.name),
                    loadLogo: !_scrolling,
                    showGroup: widget.showGroup,
                    onTap: () => widget.onPlay(channel),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? const Color(0xffeee6ff) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w900 : FontWeight.w500,
                      color: selected ? const Color(0xff8357f7) : null,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xff6f7681),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.hasRoutes,
    required this.loadLogo,
    required this.onTap,
    this.showGroup = false,
  });

  final Channel channel;
  final bool selected;
  final bool hasRoutes;
  final bool loadLogo;
  final bool showGroup;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xffeee6ff) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: _channelRowHeight,
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0x1f000000), width: 1),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _ChannelLogo(url: channel.logo, load: loadLogo),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            channel.name,
                            // Names get two lines when browsing (no subtitle),
                            // but only one while searching so the row still fits
                            // the group label below without overflowing.
                            maxLines: showGroup ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (hasRoutes) ...const [
                          SizedBox(width: 8),
                          _Tag(label: 'routes'),
                        ],
                      ],
                    ),
                    if (showGroup) ...[
                      const SizedBox(height: 4),
                      Text(
                        channel.group,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xff7d8490)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChannelLogo extends StatelessWidget {
  const _ChannelLogo({this.url, this.load = true});
  final String? url;
  final bool load;

  // URLs whose logo has already been fetched + decoded this session. Such
  // logos live in the in-memory ImageCache, so we render them immediately even
  // while scrolling (painting from memory is cheap and never re-downloads).
  // Only brand-new logos are deferred until scrolling settles, to avoid the
  // download/decode storm that froze big drags.
  static final Set<String> _loadedUrls = <String>{};

  @override
  Widget build(BuildContext context) {
    final hasLogo = url != null && url!.isNotEmpty;
    final alreadyLoaded = hasLogo && _loadedUrls.contains(url);
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        // Dark violet tile: most TV channel logos are white/light artwork, so a
        // light background made them nearly invisible. Tinting the dark tile
        // toward the app's purple accent keeps white logos crisp while sitting
        // more harmoniously in the lavender UI than a stark black box.
        color: const Color(0xff2a2540),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: !hasLogo || (!load && !alreadyLoaded)
          ? const Icon(Icons.tv, color: Color(0xff8891a3))
          : Padding(
              padding: const EdgeInsets.all(5),
              child: Image.network(
                url!,
                fit: BoxFit.contain,
                alignment: Alignment.center,
                // Decode at roughly the displayed size to cut memory and decode
                // cost for long lists. Only the width is constrained: giving
                // both cacheWidth and cacheHeight makes Flutter decode to those
                // exact pixels, squashing non-square logos into a square. With
                // width alone the height scales proportionally, so BoxFit.contain
                // renders the logo at its true aspect ratio.
                cacheWidth: 96,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                // Remember which logos have rendered so we can show them
                // instantly on future scrolls instead of waiting for the
                // post-scroll load delay.
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (frame != null) _loadedUrls.add(url!);
                  return child;
                },
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.tv, color: Color(0xff8891a3)),
              ),
            ),
    );
  }
}
