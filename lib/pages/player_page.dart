import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../controllers/playback_controller.dart';
import '../controllers/ui_controller.dart';
import '../models/playlist.dart';
import '../widgets/channel_list.dart';
import '../widgets/playback_controls.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.source});
  final PlaylistSource source;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final ScrollController _channelScrollController = ScrollController();

  @override
  void dispose() {
    _channelScrollController.dispose();
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
                          : Sidebar(
                              source: source,
                              groups: groups,
                              activeGroup: ui.activeGroup,
                              onBack: () => _showSourcesPage(context),
                              onSearch: ui.setSearch,
                              onGroup: ui.setGroup,
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
                        child: ChannelList(
                          title: ui.activeGroup,
                          channels: visibleChannels,
                          // The sidebar already shows the selected group, so the
                          // per-channel group label is redundant — except while
                          // searching, where results span groups.
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
                    padding: fullscreen
                        ? EdgeInsets.zero
                        : const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onDoubleTap: playback.toggleFullscreen,
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: playback.videoAspectRatio,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Video(
                                      controller: playback.videoController,
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
                                              borderRadius: BorderRadius.all(
                                                Radius.circular(16),
                                              ),
                                            ),
                                            child: Padding(
                                              padding: EdgeInsets.all(20),
                                              child: SizedBox(
                                                width: 48,
                                                height: 48,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 3,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                            Color
                                                          >(Color(0xff8357f7)),
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
                                        onSeekEnd: playback.nowPlaying == null
                                            ? null
                                            : playback.onSeekEnd,
                                        onPlayPause: playback.nowPlaying == null
                                            ? null
                                            : playback.togglePlayPause,
                                        onStop: playback.nowPlaying == null
                                            ? null
                                            : playback.stopPlayback,
                                        onMute: playback.nowPlaying == null
                                            ? null
                                            : playback.toggleMute,
                                        onSnapshot: playback.nowPlaying == null
                                            ? null
                                            : playback.takeSnapshot,
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
                            streamUrlController: playback.streamUrlController,
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
                            onReplay: playback.nowPlaying == null
                                ? null
                                : () => playback.play(playback.nowPlaying!),
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
                            onFullscreen: playback.toggleFullscreen,
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

  Future<void> _showSourcesPage(BuildContext context) async {
    final ui = context.read<UiController>();
    final playback = context.read<PlaybackController>();
    await playback.stopPlayback();
    ui.showSourcesPage();
    playback.resetFullscreenState();
  }
}
