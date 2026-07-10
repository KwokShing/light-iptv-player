import 'package:flutter/material.dart';

import '../services/ping_service.dart';

/// Compact icon button used across the transport bars.
class TransportButton extends StatelessWidget {
  const TransportButton({
    super.key,
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
class SeekBar extends StatelessWidget {
  const SeekBar({
    super.key,
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
              onChanged: enabled ? (value) => onChanged!(value / 1000) : null,
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

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 58});
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

class Tag extends StatelessWidget {
  const Tag({super.key, required this.label, this.green = false});
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

class ChannelLogo extends StatelessWidget {
  const ChannelLogo({super.key, this.url, this.load = true});
  final String? url;
  final bool load;

  // URLs whose logo has already been fetched + decoded this session. Such
  // logos live in the in-memory ImageCache, so we render them immediately even
  // while scrolling (painting from memory is cheap and never re-downloads).
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
        // light background made them nearly invisible.
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
                cacheWidth: 96,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
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

/// Shows a channel's reachability. Green "123 ms" text means the host answered;
/// a red dot means it timed out (>5s) or refused the connection.
class ChannelPing extends StatefulWidget {
  const ChannelPing({super.key, required this.url, required this.active});

  final String url;
  final bool active;

  @override
  State<ChannelPing> createState() => _ChannelPingState();
}

class _ChannelPingState extends State<ChannelPing> {
  PingResult? _result;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _result = PingService.cached(widget.url);
    _maybePing();
  }

  @override
  void didUpdateWidget(ChannelPing oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tiles are recycled as the list scrolls, so the same state can be handed a
    // different channel. Reset to that channel's cached result and probe again.
    if (oldWidget.url != widget.url) {
      _result = PingService.cached(widget.url);
      _requested = false;
    }
    _maybePing();
  }

  void _maybePing() {
    if (_result != null || _requested || !widget.active) return;
    _requested = true;
    final url = widget.url;
    PingService.ping(url).then((result) {
      if (!mounted || widget.url != url) return;
      setState(() => _result = result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result == null) {
      // Not measured yet (or currently probing): keep the slot empty.
      return const SizedBox(width: 8);
    }
    if (!result.reachable) {
      return Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Color(0xffe23c3c),
          shape: BoxShape.circle,
        ),
      );
    }
    return Text(
      '${result.ms} ms',
      style: const TextStyle(
        color: Color(0xff1faa59),
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
    );
  }
}
