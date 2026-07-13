import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/playlist.dart';
import '../theme.dart';
import 'common.dart';
import 'epg_widgets.dart';

class PlaybackControls extends StatelessWidget {
  const PlaybackControls({
    super.key,
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
    required this.deinterlace,
    required this.onReplay,
    required this.onPlayPause,
    required this.onStop,
    required this.onMute,
    required this.onVolume,
    required this.onSnapshot,
    required this.onDeinterlace,
    required this.onFullscreen,
    this.epgUrl,
    this.onGuide,
    this.onDebugLog,
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
  final bool deinterlace;
  final VoidCallback? onReplay;
  final VoidCallback? onPlayPause;
  final VoidCallback? onStop;
  final VoidCallback? onMute;
  final ValueChanged<double>? onVolume;
  final VoidCallback? onSnapshot;
  final VoidCallback? onDeinterlace;
  final VoidCallback? onFullscreen;
  final String? epgUrl;
  final VoidCallback? onGuide;
  final VoidCallback? onDebugLog;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final hasChannel = nowPlaying != null;
        final hasEpg = hasChannel && epgUrl != null;
        return Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          decoration: cardDecoration(radius: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Info line: channel name, inline EPG now/next, and the current
              // stream URL (horizontally scrollable) with a copy button — all
              // on one row so the card stays short and the video pane is large.
              if (hasChannel && (nowPlaying?.name.isNotEmpty ?? false))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(
                          nowPlaying!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (hasEpg) ...[
                        const SizedBox(width: 10),
                        Container(
                          width: 1,
                          height: 14,
                          color: AppColors.border,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: NowNextInline(
                            channel: nowPlaying!,
                            epgUrl: epgUrl,
                          ),
                        ),
                      ] else
                        const Spacer(),
                      if (streamUrlController.text.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 320,
                          child: _StreamUrlBar(url: streamUrlController.text),
                        ),
                      ],
                    ],
                  ),
                ),
              // Control line: transport buttons, volume, seek bar and the
              // status/action cluster — a single horizontal row.
              Row(
                children: [
                  TransportButton(
                    icon: isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    tooltip: isPlaying ? 'Pause (Space)' : 'Play (Space)',
                    onPressed: onPlayPause,
                    primary: true,
                  ),
                  TransportButton(
                    icon: Icons.stop_rounded,
                    tooltip: 'Stop (S)',
                    onPressed: onStop,
                  ),
                  TransportButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Reload stream',
                    onPressed: onReplay,
                  ),
                  const SizedBox(width: 4),
                  TransportButton(
                    icon: muted || volume == 0
                        ? Icons.volume_off_rounded
                        : volume < 50
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded,
                    tooltip: muted ? 'Unmute (M)' : 'Mute (M)',
                    onPressed: onMute,
                  ),
                  SizedBox(
                    width: compact ? 56 : 84,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        activeTrackColor: AppColors.accent,
                        inactiveTrackColor: AppColors.border,
                        thumbColor: AppColors.accent,
                        overlayColor: const Color(0x333b6ef5),
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
                  const SizedBox(width: 8),
                  // The seek bar takes all remaining width in the middle.
                  Expanded(
                    child: SeekBar(
                      position: position,
                      duration: duration,
                      onChanged: onSeekChanged,
                      onChangeEnd: onSeekEnd,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!compact) ...[
                    Text(
                      playbackInfo,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (hasChannel)
                    TransportButton(
                      icon: Icons.bug_report_outlined,
                      tooltip: 'Debug log',
                      onPressed: onDebugLog,
                    ),
                  if (hasChannel)
                    TransportButton(
                      icon: Icons.calendar_month_rounded,
                      tooltip: 'Programme guide',
                      onPressed: onGuide,
                    ),
                  _RightControls(
                    deinterlace: deinterlace,
                    onDeinterlace: onDeinterlace,
                    onSnapshot: onSnapshot,
                    onFullscreen: onFullscreen,
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

/// The current stream URL on a single line: a copy button plus the URL in a
/// horizontal scroll view, so a long URL can be scrolled and copied without
/// wrapping or truncating the transport bar.
class _StreamUrlBar extends StatelessWidget {
  const _StreamUrlBar({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => Clipboard.setData(ClipboardData(text: url)),
          borderRadius: BorderRadius.circular(6),
          hoverColor: AppColors.surfaceMuted,
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(
              Icons.copy_rounded,
              size: 15,
              color: AppColors.textMuted,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Tooltip(
            message: url,
            waitDuration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.textPrimary,
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              height: 1.35,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                url,
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Auto-hiding transport overlay shown over the video while in fullscreen.
class FullscreenControls extends StatelessWidget {
  const FullscreenControls({
    super.key,
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
    required this.deinterlace,
    required this.onDeinterlace,
    required this.onExitFullscreen,
    this.channel,
    this.epgUrl,
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
  final bool deinterlace;
  final VoidCallback? onDeinterlace;
  final VoidCallback? onExitFullscreen;
  final Channel? channel;
  final String? epgUrl;

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
                SeekBar(
                  position: position,
                  duration: duration,
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                  dark: true,
                ),
                Row(
                  children: [
                    TransportButton(
                      icon: isPlaying ? Icons.pause : Icons.play_arrow,
                      tooltip: isPlaying ? 'Pause (Space)' : 'Play (Space)',
                      onPressed: onPlayPause,
                      color: Colors.white,
                    ),
                    TransportButton(
                      icon: Icons.stop,
                      tooltip: 'Stop (S)',
                      onPressed: onStop,
                      color: Colors.white,
                    ),
                    TransportButton(
                      icon: muted ? Icons.volume_off : Icons.volume_up,
                      tooltip: muted ? 'Unmute (M)' : 'Mute (M)',
                      onPressed: onMute,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title ?? '',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (channel != null && epgUrl != null)
                            FullscreenEpgLine(
                              channel: channel!,
                              epgUrl: epgUrl,
                            ),
                        ],
                      ),
                    ),
                    TransportButton(
                      icon: Icons.deblur_rounded,
                      tooltip: deinterlace
                          ? 'Deinterlace: On (D)'
                          : 'Deinterlace: Off (D)',
                      onPressed: onDeinterlace,
                      color: deinterlace ? AppColors.accent : Colors.white,
                    ),
                    TransportButton(
                      icon: Icons.photo_camera_outlined,
                      tooltip: 'Snapshot',
                      onPressed: onSnapshot,
                      color: Colors.white,
                    ),
                    TransportButton(
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

/// The status/action cluster pinned to the right edge of the transport bar:
/// the deinterlace, snapshot and fullscreen buttons. Grouped so it keeps a
/// stable position regardless of how long the adjacent playback-info text is.
class _RightControls extends StatelessWidget {
  const _RightControls({
    required this.deinterlace,
    required this.onDeinterlace,
    required this.onSnapshot,
    required this.onFullscreen,
  });

  final bool deinterlace;
  final VoidCallback? onDeinterlace;
  final VoidCallback? onSnapshot;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TransportButton(
          icon: Icons.deblur_rounded,
          tooltip:
              deinterlace ? 'Deinterlace: On (D)' : 'Deinterlace: Off (D)',
          onPressed: onDeinterlace,
          color: deinterlace ? AppColors.accent : null,
        ),
        TransportButton(
          icon: Icons.photo_camera_outlined,
          tooltip: 'Snapshot',
          onPressed: onSnapshot,
        ),
        TransportButton(
          icon: Icons.fullscreen_rounded,
          tooltip: 'Fullscreen (F / double-click)',
          onPressed: onFullscreen,
        ),
      ],
    );
  }
}
