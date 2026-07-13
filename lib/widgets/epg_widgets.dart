import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/epg_controller.dart';
import '../models/playlist.dart';
import '../theme.dart';

/// A single app-wide clock that ticks once a minute (plus an immediate value),
/// so every EPG widget advances its now/next and progress in lockstep without
/// each running its own timer. Widgets rebuild by listening to it.
class EpgClock {
  EpgClock._() {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      now.value = DateTime.now();
    });
  }

  static final EpgClock instance = EpgClock._();

  final ValueNotifier<DateTime> now = ValueNotifier(DateTime.now());
  late final Timer _timer;

  void dispose() => _timer.cancel();
}

String _formatClock(DateTime local) {
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Compact "now" + progress line shown under a channel name in the list.
/// Renders nothing (zero height) when the channel has no guide data, so rows
/// without EPG stay clean.
class ChannelEpgLine extends StatelessWidget {
  const ChannelEpgLine({super.key, required this.channel, required this.epgUrl});

  final Channel channel;
  final String? epgUrl;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgController>();
    return ValueListenableBuilder<DateTime>(
      valueListenable: EpgClock.instance.now,
      builder: (context, now, _) {
        final nowNext = epg.nowNext(epgUrl, channel, at: now);
        final current = nowNext.now;
        if (current == null) {
          // No programme covers "now": if there's an upcoming one, hint it.
          final next = nowNext.next;
          if (next == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '${_formatClock(next.start.toLocal())}  ${next.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11.5,
                height: 1.1,
              ),
            ),
          );
        }
        final progress = current.progressAt(now.toUtc());
        return Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                current.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 3),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: AppColors.border,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.accent,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Single-line, inline now/next for the compact transport bar. Lays out the
/// current programme title, its time range, a flexible progress bar and the
/// upcoming programme all on one horizontal line so the video pane can stay
/// large. Renders nothing when the channel has no guide data.
class NowNextInline extends StatelessWidget {
  const NowNextInline({super.key, required this.channel, required this.epgUrl});

  final Channel channel;
  final String? epgUrl;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgController>();
    return ValueListenableBuilder<DateTime>(
      valueListenable: EpgClock.instance.now,
      builder: (context, now, _) {
        final nowNext = epg.nowNext(epgUrl, channel, at: now);
        final current = nowNext.now;
        final next = nowNext.next;
        if (nowNext.isEmpty) return const SizedBox.shrink();

        return Row(
          children: [
            if (current != null) ...[
              const _EpgDot(),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  current.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_formatClock(current.start.toLocal())}'
                '–${_formatClock(current.stop.toLocal())}',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: current.progressAt(now.toUtc()),
                    minHeight: 3,
                    backgroundColor: AppColors.border,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.accent,
                    ),
                  ),
                ),
              ),
            ],
            if (next != null) ...[
              const SizedBox(width: 12),
              Text(
                'NEXT',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _formatClock(next.start.toLocal()),
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  next.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _EpgDot extends StatelessWidget {
  const _EpgDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        color: AppColors.live,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Dark, single-line "now" indicator shown under the channel title in the
/// fullscreen overlay.
class FullscreenEpgLine extends StatelessWidget {
  const FullscreenEpgLine({
    super.key,
    required this.channel,
    required this.epgUrl,
  });

  final Channel channel;
  final String? epgUrl;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgController>();
    return ValueListenableBuilder<DateTime>(
      valueListenable: EpgClock.instance.now,
      builder: (context, now, _) {
        final current = epg.nowNext(epgUrl, channel, at: now).now;
        if (current == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '${_formatClock(current.start.toLocal())}'
            ' – ${_formatClock(current.stop.toLocal())}   ${current.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }
}
