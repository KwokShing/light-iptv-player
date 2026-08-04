import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../controllers/epg_controller.dart';
import '../controllers/playback_controller.dart';
import '../controllers/sources_controller.dart';
import '../controllers/ui_controller.dart';
import '../models/playlist.dart';
import '../services/paste_to_play.dart';
import '../theme.dart';
import '../widgets/channel_list.dart';
import '../widgets/common.dart';
import '../widgets/debug_log_sidebar.dart';
import '../widgets/epg_schedule_panel.dart';
import '../widgets/playback_controls.dart';
import '../widgets/proxy_button.dart';
import '../widgets/top_bar.dart';
import '../widgets/user_agent_button.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.source});
  final PlaylistSource source;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final ScrollController _channelScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadEpg();
  }

  void _loadEpg() {
    final url = widget.source.epgUrl;
    if (url == null || url.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<EpgController>().ensureGuide(url);
    });
  }

  @override
  void didUpdateWidget(PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Switching to a different source clears any leftover search text.
    if (oldWidget.source.id != widget.source.id &&
        _searchController.text.isNotEmpty) {
      _searchController.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<UiController>().setSearch('');
      });
    }
    if (oldWidget.source.epgUrl != widget.source.epgUrl) _loadEpg();
  }

  @override
  void dispose() {
    _channelScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final ui = context.watch<UiController>();
    final source = widget.source;
    final groups = source.groups;
    final visibleChannels = ui.visibleChannels(source);
    final fullscreen = playback.fullscreen;

    final isTemporary = ui.temporarySourceId == source.id;

    final player = Focus(
      focusNode: playback.playerFocusNode,
      autofocus: true,
      onKeyEvent: playback.handleKeyEvent,
      child: MouseRegion(
        cursor: (fullscreen && playback.cursorHidden)
            ? SystemMouseCursors.none
            : MouseCursor.defer,
        onHover: (_) => playback.handlePointerActivity(),
        child: Listener(
          onPointerDown: (_) => playback.handlePointerActivity(),
          onPointerMove: (_) => playback.handlePointerActivity(),
          onPointerSignal: (_) => playback.handlePointerActivity(),
          child: Scaffold(
            backgroundColor: fullscreen ? Colors.black : AppColors.bg,
            body: Column(
              children: [
                // Top bar collapses to zero height in fullscreen.
                if (!fullscreen)
                  TopBar(
                    title: '',
                    showLogo: false,
                    searchLeftInset: sideColumnsWidth,
                    leading: TopBarIconButton(
                      icon: Icons.home_rounded,
                      tooltip: 'Back to sources',
                      onPressed: () => _showSourcesPage(context),
                    ),
                    search: TopBarSearch(
                      controller: _searchController,
                      onChanged: ui.setSearch,
                      hint: 'Search channels',
                    ),
                    trailing: [
                      if (isTemporary)
                        TopBarIconButton(
                          icon: Icons.playlist_add_rounded,
                          tooltip: 'Save to library',
                          onPressed: () => _keepTemporary(context),
                        ),
                      if (isTemporary) const SizedBox(width: 10),
                      const UserAgentButton(),
                      const SizedBox(width: 10),
                      const ProxyButton(),
                    ],
                  ),
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: fullscreen ? 0 : sidebarWidth,
                        child: ClipRect(
                          child: IgnorePointer(
                            ignoring: fullscreen,
                            child: fullscreen
                                ? const SizedBox.shrink()
                                : Sidebar(
                                    source: source,
                                    groups: groups,
                                    activeGroup: ui.activeGroup,
                                    onGroup: ui.setGroup,
                                  ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: fullscreen ? 0 : channelListWidth,
                        child: ClipRect(
                          child: IgnorePointer(
                            ignoring: fullscreen,
                            child: Visibility(
                              visible: !fullscreen,
                              maintainState: true,
                              maintainAnimation: true,
                              maintainSize: false,
                              child: ChannelList(
                                title: ui.activeGroup,
                                channels: visibleChannels,
                                // The sidebar already shows the selected group,
                                // so the per-channel group label is redundant —
                                // except while searching, where results span
                                // groups.
                                showGroup: ui.search.trim().isNotEmpty,
                                selected: playback.nowPlaying,
                                scrollController: _channelScrollController,
                                onPlay: playback.play,
                                epgUrl: source.epgUrl,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: AnimatedPadding(
                          duration: fullscreenAnimationDuration,
                          curve: fullscreenAnimationCurve,
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onDoubleTap: playback.toggleFullscreen,
                                  child: Align(
                                    alignment: Alignment.center,
                                    child: AspectRatio(
                                      aspectRatio: playback.videoAspectRatio,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          const ColoredBox(color: Colors.black),
                                          if (playback.hasPlaybackEngine)
                                            ValueListenableBuilder<int?>(
                                              key: ValueKey(
                                                playback.engineGeneration,
                                              ),
                                              valueListenable:
                                                  playback.videoController.id,
                                              builder: (context, textureId, _) {
                                                if (textureId == null) {
                                                  return const SizedBox.shrink();
                                                }
                                                // The outer AspectRatio already
                                                // matches the decoded display
                                                // size. Paint the native texture
                                                // directly into that rect so
                                                // media_kit's additional rect +
                                                // FittedBox layer cannot expose
                                                // a black strip underneath it.
                                                return Texture(
                                                  textureId: textureId,
                                                  filterQuality:
                                                      FilterQuality.low,
                                                );
                                              },
                                            ),
                                          // Hold the last decoded frame over
                                          // the video while reconnecting so a
                                          // segmented stream doesn't flash
                                          // black between segments.
                                          if (playback.reconnecting &&
                                              playback.lastFrame != null)
                                            Positioned.fill(
                                              child: Image.memory(
                                                playback.lastFrame!,
                                                fit: BoxFit.contain,
                                                gaplessPlayback: true,
                                              ),
                                            ),
                                          if (playback
                                              .dashSubtitleText
                                              .isNotEmpty)
                                            Positioned.fill(
                                              child: IgnorePointer(
                                                child: LayoutBuilder(
                                                  builder: (context, constraints) {
                                                    final fontSize =
                                                        PlaybackController
                                                            .subtitleFontSizeAt720p *
                                                        constraints.maxHeight /
                                                        720;
                                                    return Align(
                                                      alignment: Alignment
                                                          .bottomCenter,
                                                      child: Padding(
                                                        padding:
                                                            EdgeInsets.fromLTRB(
                                                              32,
                                                              0,
                                                              32,
                                                              fullscreen
                                                                  ? 54
                                                                  : 24,
                                                            ),
                                                        child: Text(
                                                          playback
                                                              .dashSubtitleText,
                                                          textAlign:
                                                              TextAlign.center,
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                            fontFamily:
                                                                PlaybackController
                                                                    .subtitleFontFamily,
                                                            fontSize: fontSize,
                                                            height: 1.2,
                                                            fontWeight:
                                                                FontWeight
                                                                    .normal,
                                                            shadows: const [
                                                              Shadow(
                                                                color: Colors
                                                                    .black,
                                                                offset: Offset(
                                                                  -1,
                                                                  -1,
                                                                ),
                                                                blurRadius: 1,
                                                              ),
                                                              Shadow(
                                                                color: Colors
                                                                    .black,
                                                                offset: Offset(
                                                                  1,
                                                                  -1,
                                                                ),
                                                                blurRadius: 1,
                                                              ),
                                                              Shadow(
                                                                color: Colors
                                                                    .black,
                                                                offset: Offset(
                                                                  -1,
                                                                  1,
                                                                ),
                                                                blurRadius: 1,
                                                              ),
                                                              Shadow(
                                                                color: Colors
                                                                    .black,
                                                                offset: Offset(
                                                                  1,
                                                                  1,
                                                                ),
                                                                blurRadius: 1,
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                            ),
                                          if (playback.reconnecting)
                                            const Positioned.fill(
                                              child: Center(
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    color: Colors.black54,
                                                    borderRadius:
                                                        BorderRadius.all(
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
                                                            AlwaysStoppedAnimation<
                                                              Color
                                                            >(Colors.white),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          // Loading spinner for a normal open
                                          // (plain video or MPD) that hasn't
                                          // rendered its first frame yet, or a
                                          // mid-stream stall (mpv buffering).
                                          // The reconnect overlay above owns the
                                          // segment-boundary case, so `loading`
                                          // is false while reconnecting.
                                          if (playback.loading)
                                            const Positioned.fill(
                                              child: Center(
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    color: Colors.black54,
                                                    borderRadius:
                                                        BorderRadius.all(
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
                                                            AlwaysStoppedAnimation<
                                                              Color
                                                            >(Colors.white),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          if (fullscreen)
                                            FullscreenControls(
                                              visible: !playback.cursorHidden,
                                              isPlaying: playback.isPlaying,
                                              muted: playback.muted,
                                              title: playback.nowPlaying?.name,
                                              position: playback.position,
                                              duration: playback.duration,
                                              onSeekChanged:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback.onSeekChanged,
                                              onSeekEnd:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback.onSeekEnd,
                                              onPlayPause:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback.togglePlayPause,
                                              onStop:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback.stopPlayback,
                                              onMute:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback.toggleMute,
                                              onSnapshot:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback.takeSnapshot,
                                              subtitlesEnabled:
                                                  playback.subtitlesEnabled,
                                              subtitlesAvailable:
                                                  playback.subtitlesAvailable,
                                              subtitleTracks:
                                                  playback.subtitleTracks,
                                              selectedSubtitle:
                                                  playback.activeSubtitleTrack,
                                              onToggleSubtitles:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback
                                                        .setSubtitlesEnabled,
                                              onSubtitleTrack:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback
                                                        .selectSubtitleTrack,
                                              deinterlace: playback.deinterlace,
                                              onDeinterlace:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback.toggleDeinterlace,
                                              onExitFullscreen:
                                                  playback.toggleFullscreen,
                                              channel: playback.nowPlaying,
                                              epgUrl: source.epgUrl,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (!fullscreen)
                                PlaybackControls(
                                  streamUrlController:
                                      playback.streamUrlController,
                                  nowPlaying: playback.nowPlaying,
                                  playbackInfo: playback.playbackInfo,
                                  isPlaying: playback.isPlaying,
                                  muted: playback.muted,
                                  volume: playback.volume,
                                  position: playback.position,
                                  duration: playback.duration,
                                  onSeekChanged: playback.nowPlaying == null
                                      ? null
                                      : playback.onSeekChanged,
                                  onSeekEnd: playback.nowPlaying == null
                                      ? null
                                      : playback.onSeekEnd,
                                  subtitlesEnabled: playback.subtitlesEnabled,
                                  subtitlesAvailable:
                                      playback.subtitlesAvailable,
                                  subtitleTracks: playback.subtitleTracks,
                                  selectedSubtitle:
                                      playback.activeSubtitleTrack,
                                  onToggleSubtitles: playback.nowPlaying == null
                                      ? null
                                      : playback.setSubtitlesEnabled,
                                  onSubtitleTrack: playback.nowPlaying == null
                                      ? null
                                      : playback.selectSubtitleTrack,
                                  deinterlace: playback.deinterlace,
                                  onReplay: playback.nowPlaying == null
                                      ? null
                                      : () =>
                                            playback.play(playback.nowPlaying!),
                                  onPlayPause: playback.nowPlaying == null
                                      ? null
                                      : playback.togglePlayPause,
                                  onStop: playback.nowPlaying == null
                                      ? null
                                      : playback.stopPlayback,
                                  onMute: playback.nowPlaying == null
                                      ? null
                                      : playback.toggleMute,
                                  onVolume: playback.nowPlaying == null
                                      ? null
                                      : playback.setVolume,
                                  onSnapshot: playback.nowPlaying == null
                                      ? null
                                      : playback.takeSnapshot,
                                  onDeinterlace: playback.nowPlaying == null
                                      ? null
                                      : playback.toggleDeinterlace,
                                  onFullscreen: playback.toggleFullscreen,
                                  epgUrl: source.epgUrl,
                                  onGuide: playback.nowPlaying == null
                                      ? null
                                      : () => showEpgSchedule(
                                          context,
                                          channel: playback.nowPlaying!,
                                          epgUrl: source.epgUrl,
                                        ),
                                  onDebugLog: playback.nowPlaying == null
                                      ? null
                                      : () => showDebugLog(context),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!isTemporary) return player;
    // While viewing the throwaway paste source, Ctrl+V swaps the stream in
    // place instead of leaving the player.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
            pasteAndReplace(context, source),
      },
      child: player,
    );
  }

  Future<void> _keepTemporary(BuildContext context) async {
    final ui = context.read<UiController>();
    final sources = context.read<SourcesController>();
    await sources.keepTemporary();
    // No longer a throwaway: clear the flag so the Ctrl+V-in-place shortcut and
    // the save button both stop treating it as temporary.
    ui.temporarySourceId = null;
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Saved to library')));
  }

  Future<void> _showSourcesPage(BuildContext context) async {
    final ui = context.read<UiController>();
    final playback = context.read<PlaybackController>();
    final sources = context.read<SourcesController>();
    final epg = context.read<EpgController>();
    final epgUrl = widget.source.epgUrl;
    await playback.stopPlayback(releaseEngine: true);
    ui.showSourcesPage();
    playback.resetFullscreenState();
    // Discard the in-memory paste source so it never lingers in the saved
    // sources list once we're back home.
    ui.temporarySourceId = null;
    sources.discardTemporary();
    epg.releaseGuide(epgUrl);
    // Wait until PlayerPage and its Image widgets are unmounted, then release
    // decoded channel logos. They are cheap to reload and otherwise account for
    // up to the app-wide 128 MiB image-cache limit after returning home.
    await WidgetsBinding.instance.endOfFrame;
    ChannelLogo.clearMemoryCache();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }
}
