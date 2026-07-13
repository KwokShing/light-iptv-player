import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/epg_controller.dart';
import '../models/epg.dart';
import '../models/playlist.dart';
import '../theme.dart';
import 'epg_widgets.dart';

/// Opens the full-day programme guide for [channel] as a right-side sheet.
Future<void> showEpgSchedule(
  BuildContext context, {
  required Channel channel,
  required String? epgUrl,
}) {
  final epg = context.read<EpgController>();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Programme guide',
    barrierColor: Colors.black26,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: ChangeNotifierProvider<EpgController>.value(
        value: epg,
        child: _SchedulePanel(channel: channel, epgUrl: epgUrl),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

class _SchedulePanel extends StatefulWidget {
  const _SchedulePanel({required this.channel, required this.epgUrl});

  final Channel channel;
  final String? epgUrl;

  @override
  State<_SchedulePanel> createState() => _SchedulePanelState();
}

class _SchedulePanelState extends State<_SchedulePanel> {
  final ScrollController _scroll = ScrollController();
  late DateTime _day;
  bool _scrolledToNow = false;

  @override
  void initState() {
    super.initState();
    _day = DateTime.now();
    // The guide may still be loading; make sure a fetch is in flight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<EpgController>().ensureGuide(widget.epgUrl);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _isToday {
    final now = DateTime.now();
    return _day.year == now.year &&
        _day.month == now.month &&
        _day.day == now.day;
  }

  void _shiftDay(int days) {
    setState(() {
      _day = DateTime(_day.year, _day.month, _day.day + days);
      _scrolledToNow = false;
    });
  }

  String _dayLabel() {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final wd = weekdays[_day.weekday - 1];
    return '$wd, ${_day.day} ${months[_day.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgController>();
    final programmes = epg.programmesForDay(widget.epgUrl, widget.channel, _day);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 380,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(left: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              _dayBar(),
              const Divider(height: 1, color: AppColors.border),
              Expanded(child: _body(programmes: programmes)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Programme Guide',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMuted,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            color: AppColors.textSecondary,
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _dayBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            color: AppColors.textSecondary,
            tooltip: 'Previous day',
            onPressed: () => _shiftDay(-1),
          ),
          Expanded(
            child: Center(
              child: Text(
                _isToday ? 'Today · ${_dayLabel()}' : _dayLabel(),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            color: AppColors.textSecondary,
            tooltip: 'Next day',
            onPressed: () => _shiftDay(1),
          ),
        ],
      ),
    );
  }

  Widget _body({required List<EpgProgramme> programmes}) {
    if (programmes.isEmpty) {
      return _EmptyState(channel: widget.channel, epgUrl: widget.epgUrl);
    }

    return ValueListenableBuilder<DateTime>(
      valueListenable: EpgClock.instance.now,
      builder: (context, now, _) {
        final nowUtc = now.toUtc();
        // Find the currently-airing programme to highlight + auto-scroll to.
        var currentIndex = -1;
        for (var i = 0; i < programmes.length; i++) {
          if (programmes[i].containsInstant(nowUtc)) {
            currentIndex = i;
            break;
          }
        }
        if (_isToday && currentIndex >= 0 && !_scrolledToNow) {
          _scrolledToNow = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scroll.hasClients) return;
            _scroll.animateTo(
              (currentIndex * 76.0).clamp(0.0, _scroll.position.maxScrollExtent),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
            );
          });
        }

        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: programmes.length,
          itemBuilder: (context, index) {
            final programme = programmes[index];
            final isNow = index == currentIndex;
            return _ProgrammeRow(
              programme: programme,
              isNow: isNow,
              progress: isNow ? programme.progressAt(nowUtc) : null,
            );
          },
        );
      },
    );
  }
}

/// Explains why the schedule is empty and offers a retry, instead of leaving a
/// blank panel. Covers the four EPG states: no guide URL in the playlist, still
/// loading, a load error, or a loaded guide that has no data for this channel
/// (with the tvg-id / match diagnostics that make the mismatch obvious).
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.channel, required this.epgUrl});

  final Channel channel;
  final String? epgUrl;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgController>();
    final status = epg.statusFor(epgUrl);

    switch (status) {
      case EpgStatus.loading:
        return const Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
            ),
          ),
        );
      case EpgStatus.noUrl:
        return const _EmptyMessage(
          icon: Icons.info_outline_rounded,
          title: 'No EPG for this playlist',
          detail:
              'This playlist did not declare a guide URL '
              '(the first #EXTM3U line has no url-tvg). Try refreshing the '
              'source, or use a playlist that includes EPG data.',
        );
      case EpgStatus.error:
        return _EmptyMessage(
          icon: Icons.error_outline_rounded,
          title: 'Could not load the guide',
          detail: epg.errorFor(epgUrl) ?? 'Unknown error',
          onRetry: () => epg.ensureGuide(epgUrl, force: true),
        );
      case EpgStatus.ready:
        final guide = epg.guideFor(epgUrl);
        final tvgId = channel.tvgId;
        final detail = StringBuffer(
          'The guide loaded '
          '(${guide?.channelCount ?? 0} channels, '
          '${guide?.programmeCount ?? 0} programmes) but has no entry '
          'matching this channel.',
        );
        detail.write('\n\nChannel tvg-id: ');
        detail.write(
          (tvgId == null || tvgId.isEmpty) ? '(none)' : tvgId,
        );
        detail.write('\nChannel name: ${channel.name}');
        return _EmptyMessage(
          icon: Icons.search_off_rounded,
          title: 'No match for this channel',
          detail: detail.toString(),
          onRetry: () => epg.ensureGuide(epgUrl, force: true),
        );
    }
  }
}

class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage({
    required this.icon,
    required this.title,
    required this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  side: const BorderSide(color: AppColors.accentBorder),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProgrammeRow extends StatelessWidget {
  const _ProgrammeRow({
    required this.programme,
    required this.isNow,
    required this.progress,
  });

  final EpgProgramme programme;
  final bool isNow;
  final double? progress;

  static String _time(DateTime local) {
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final start = programme.start.toLocal();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isNow ? AppColors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isNow ? AppColors.accentBorder : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  _time(start),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: isNow ? AppColors.accent : AppColors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      programme.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: isNow
                            ? AppColors.textPrimary
                            : AppColors.textPrimary,
                      ),
                    ),
                    if (programme.description != null &&
                        programme.description!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        programme.description!,
                        maxLines: isNow ? 4 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isNow)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.live,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    'NOW',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
            ],
          ),
          if (isNow && progress != null) ...[
            const SizedBox(height: 8),
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
        ],
      ),
    );
  }
}
