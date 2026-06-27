import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset_converter/charset_converter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _filterNoisyDebugLogs();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Light IPTV Player',
      size: Size(1360, 760),
      minimumSize: Size(1040, 560),
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
  });

  final String name;
  final String url;
  final String group;
  final String? logo;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'group': group,
    'logo': logo,
  };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
    name: json['name'] as String? ?? 'Untitled Channel',
    url: json['url'] as String? ?? '',
    group: json['group'] as String? ?? ungroupedGroup,
    logo: json['logo'] as String?,
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
  Timer? bitrateTimer;
  Timer? reconnectTimer;
  int reconnectAttempts = 0;
  bool reconnecting = false;
  Uint8List? lastFrame;
  int? videoBitrate;
  double? containerFps;
  bool hwdecEnabled = true;
  String? hwdecCurrent;
  bool fullscreen = false;
  bool fullscreenChanging = false;
  bool loading = true;
  // Maximum consecutive reconnect attempts before giving up. Reset to zero
  // whenever playback successfully resumes, so long-running segmented streams
  // can reconnect indefinitely as long as each reconnect eventually plays.
  static const int _maxReconnectAttempts = 30;
  int playbackRequest = 0;

  // Auto-update state.
  ReleaseInfo? availableUpdate;
  bool updating = false;
  double? updateProgress;

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
      // Remember which release we're moving to so we don't re-prompt for it.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(installedTagStorageKey, release.tag);
      // Stop playback and release file handles before the swap.
      await player.stop();
      await UpdateService.applyAndRestart(zip);
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
    bitrateTimer?.cancel();
    reconnectTimer?.cancel();
    streamUrlController.dispose();
    channelScrollController.dispose();
    player.dispose();
    super.dispose();
  }

  (Player, VideoController) _createPlaybackEngine() {
    final nextPlayer = Player(
      configuration: const PlayerConfiguration(
        title: 'Light IPTV Player',
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    final nextVideoController = VideoController(
      nextPlayer,
      configuration: const VideoControllerConfiguration(
        hwdec: 'auto-safe',
        enableHardwareAcceleration: true,
      ),
    );
    return (nextPlayer, nextVideoController);
  }

  void _listenPlaybackInfo() {
    videoParamsSubscription = player.stream.videoParams.listen((params) {
      if (!mounted) return;
      setState(() => videoParams = params);
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
      if (!playing || !mounted) return;
      reconnectAttempts = 0;
      if (reconnecting) {
        setState(() => reconnecting = false);
      }
    });
    bitrateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollBitrate();
    });
  }

  // Capture the currently displayed frame. mpv holds the last frame at EOF
  // (keep-open=yes), so calling this at the "completed" event yields a real
  // image to freeze during the reconnect instead of a black screen.
  Future<void> _captureLastFrame() async {
    try {
      final frame = await player.screenshot();
      if (!mounted || frame == null) return;
      lastFrame = frame;
    } catch (_) {}
  }

  Future<void> _pollBitrate() async {
    final platform = player.platform;
    if (platform == null || nowPlaying == null) return;
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
        if (hwdecValue != null && hwdecValue.isNotEmpty && hwdecValue != 'no') {
          hwdecEnabled = true;
        }
      });
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
    try {
      if (source.kind == SourceKind.local) {
        final text = await decodePlaylistBytes(
          await File(source.source).readAsBytes(),
        );
        await _replaceSource(
          source.copyWith(channels: parsePlaylist(text), cached: true),
        );
      } else if (source.kind == SourceKind.online) {
        final response = await http.get(Uri.parse(source.source));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('HTTP ${response.statusCode}');
        }
        final text = await decodeHttpPlaylist(response);
        await _replaceSource(
          source.copyWith(channels: parsePlaylist(text), cached: true),
        );
      }
    } catch (error) {
      _showMessage('Refresh failed: $error');
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
  }

  Future<void> _play(Channel channel) async {
    final request = ++playbackRequest;
    reconnectTimer?.cancel();
    reconnecting = false;
    reconnectAttempts = 0;
    lastFrame = null;
    streamUrlController.text = channel.url;
    debugPrint('Playing: ${channel.name} - ${channel.url}');
    setState(() {
      nowPlaying = channel;
      videoParams = const VideoParams();
      selectedTrack = const Track();
    });
    await player.stop();
    if (!mounted || request != playbackRequest) return;
    await _applyPlaybackOptions();
    if (!mounted || request != playbackRequest) return;
    await player.open(Media(channel.url));
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
    debugPrint(
      'Reconnecting stream (attempt $reconnectAttempts): ${channel.url}',
    );
    try {
      await _applyPlaybackOptions();
      if (!mounted || request != playbackRequest) return;
      // Keep reconnecting=true (freeze frame stays up) until the playing event
      // confirms the new segment is rendering.
      await player.open(Media(channel.url));
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
    reconnecting = false;
    reconnectAttempts = 0;
    lastFrame = null;
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
    });
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

    final options = {
      'video-sync': 'display-resample',
      'interpolation': 'yes',
      'tscale': 'oversample',
      'hwdec': hwdecEnabled ? 'auto-safe' : 'no',
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

  Future<void> _toggleHwdec() async {
    final next = !hwdecEnabled;
    setState(() => hwdecEnabled = next);
    final platform = player.platform;
    if (platform == null) {
      debugPrint('HW toggle: platform is null');
      return;
    }
    try {
      final value = next ? 'auto-safe' : 'no';
      debugPrint('HW toggle: setting hwdec=$value');
      await (platform as dynamic).setProperty('hwdec', value);
      final current =
          await (platform as dynamic).getProperty('hwdec-current') as String?;
      debugPrint('HW toggle: hwdec-current=$current');
    } catch (e) {
      debugPrint('HW toggle failed: $e');
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
    }
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
                    'The app will restart automatically after updating.',
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
              label: const Text('Update now'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlayerPage(PlaylistSource source) {
    final groups = source.groups;
    final visibleChannels = source.channels.where((channel) {
      final matchesGroup =
          activeGroup == allChannels || channel.group == activeGroup;
      final matchesSearch =
          search.trim().isEmpty ||
          channel.name.toLowerCase().contains(search.toLowerCase());
      return matchesGroup && matchesSearch;
    }).toList();

    return Scaffold(
      backgroundColor: fullscreen ? Colors.black : const Color(0xfff6f8fc),
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
                      child: AnimatedContainer(
                        duration: fullscreenAnimationDuration,
                        curve: fullscreenAnimationCurve,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(
                            fullscreen ? 0 : 12,
                          ),
                          border: fullscreen
                              ? null
                              : Border.all(
                                  color: const Color(0xffd9c7ff),
                                  width: 2,
                                ),
                        ),
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
                              ],
                            ),
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
                      hwdecEnabled: hwdecEnabled,
                      onToggleHwdec: _toggleHwdec,
                      onReplay: nowPlaying == null
                          ? null
                          : () => _play(nowPlaying!),
                    ),
                ],
              ),
            ),
          ),
        ],
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
    required this.hwdecEnabled,
    required this.onToggleHwdec,
    required this.onReplay,
  });

  final TextEditingController streamUrlController;
  final Channel? nowPlaying;
  final String playbackInfo;
  final bool hwdecEnabled;
  final VoidCallback onToggleHwdec;
  final VoidCallback? onReplay;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: streamUrlController,
                      readOnly: true,
                      decoration: const InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(),
                        hintText: 'Stream URL',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: compact ? 72 : 140,
                    child: FilledButton(
                      onPressed: onReplay,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 0 : 18,
                          vertical: 14,
                        ),
                        child: const Text('Play'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    'Now Playing',
                    style: TextStyle(color: Color(0xff7d8490)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      nowPlaying?.name ?? 'No stream selected',
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      playbackInfo,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xff7d8490),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: onToggleHwdec,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: hwdecEnabled
                            ? const Color(0x1a8357f7)
                            : const Color(0xffe8e8e8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        hwdecEnabled ? 'HW' : 'SW',
                        style: TextStyle(
                          color: hwdecEnabled
                              ? const Color(0xff8357f7)
                              : const Color(0xff7d8490),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
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

  for (final line in lines) {
    if (line.isEmpty || line == '#EXTM3U') continue;
    if (line.startsWith('#EXTGRP:')) {
      extGrp = line.substring('#EXTGRP:'.length).trim();
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
        ),
      );
      pendingName = '';
      pendingGroup = ungroupedGroup;
      pendingLogo = null;
      extGrp = null;
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
  });

  final PlaylistSource source;
  final VoidCallback onOpen;
  final VoidCallback? onRefresh;
  final VoidCallback onRename;
  final VoidCallback onDelete;

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
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh),
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

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.title,
    required this.channels,
    required this.selected,
    required this.scrollController,
    required this.onPlay,
  });

  final String title;
  final List<Channel> channels;
  final Channel? selected;
  final ScrollController scrollController;
  final ValueChanged<Channel> onPlay;

  @override
  Widget build(BuildContext context) {
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
                  title,
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
            child: ListView.separated(
              controller: scrollController,
              itemCount: channels.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final channel = channels[index];
                final selectedChannel = selected?.url == channel.url;
                return _ChannelTile(
                  channel: channel,
                  selected: selectedChannel,
                  hasRoutes:
                      channels
                          .where((item) => item.name == channel.name)
                          .length >
                      1,
                  onTap: () => onPlay(channel),
                );
              },
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
                    overflow: TextOverflow.ellipsis,
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
    required this.onTap,
  });

  final Channel channel;
  final bool selected;
  final bool hasRoutes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xffeee6ff) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _ChannelLogo(url: channel.logo),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 130),
                          child: Text(
                            channel.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (hasRoutes) const _Tag(label: 'routes'),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      channel.group,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xff7d8490)),
                    ),
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
  const _ChannelLogo({this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: const Color(0xffe9edf3),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null || url!.isEmpty
          ? const Icon(Icons.tv, color: Color(0xff8c94a1))
          : Padding(
              padding: const EdgeInsets.all(5),
              child: Image.network(
                url!,
                fit: BoxFit.contain,
                alignment: Alignment.center,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.tv, color: Color(0xff8c94a1)),
              ),
            ),
    );
  }
}
