import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../controllers/playback_controller.dart';
import '../controllers/ui_controller.dart';
import '../models/playlist.dart';
import '../theme.dart';
import '../widgets/channel_list.dart';
import '../widgets/playback_controls.dart';
import '../widgets/proxy_button.dart';
import '../widgets/top_bar.dart';

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

    return Focus(
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
                    trailing: const [ProxyButton()],
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
                                          Video(
                                            key: ValueKey(
                                              playback.engineGeneration,
                                            ),
                                            controller:
                                                playback.videoController,
                                            fit: BoxFit.contain,
                                            controls: NoVideoControls,
                                            subtitleViewConfiguration:
                                                const SubtitleViewConfiguration(
                                                  visible: false,
                                                ),
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
                                              deinterlace:
                                                  playback.deinterlace,
                                              onDeinterlace:
                                                  playback.nowPlaying == null
                                                  ? null
                                                  : playback.toggleDeinterlace,
                                              onExitFullscreen:
                                                  playback.toggleFullscreen,
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
                                  hwActive: playback.hwActive,
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
  }

  Future<void> _showSourcesPage(BuildContext context) async {
    final ui = context.read<UiController>();
    final playback = context.read<PlaybackController>();
    await playback.stopPlayback();
    ui.showSourcesPage();
    playback.resetFullscreenState();
  }
}
