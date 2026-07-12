// Represents a DASH media presentation description (MPD), ISO/IEC 23009-1:2014
// Section 5.3.1.2.
//
// Dart port of ExoPlayer's `DashManifest`
// (androidx.media3.exoplayer.dash.manifest.DashManifest). The FilterableManifest
// `copy(streamKeys)` machinery is omitted — track selection here happens on the
// live object tree rather than by rewriting the manifest.

import 'dash_c.dart';
import 'period.dart';

class DashManifest {
  final int availabilityStartTimeMs;
  final int durationMs;
  final int minBufferTimeMs;
  final bool dynamic;
  final int minUpdatePeriodMs;
  final int timeShiftBufferDepthMs;
  final int suggestedPresentationDelayMs;
  final int publishTimeMs;
  final String? location;
  final List<Period> _periods;

  DashManifest({
    required this.availabilityStartTimeMs,
    required this.durationMs,
    required this.minBufferTimeMs,
    required this.dynamic,
    required this.minUpdatePeriodMs,
    required this.timeShiftBufferDepthMs,
    required this.suggestedPresentationDelayMs,
    required this.publishTimeMs,
    this.location,
    List<Period> periods = const [],
  }) : _periods = periods; // ignore: prefer_initializing_formals

  int get periodCount => _periods.length;

  Period getPeriod(int index) => _periods[index];

  int getPeriodDurationMs(int index) {
    if (index == _periods.length - 1) {
      return durationMs == C.timeUnset
          ? C.timeUnset
          : durationMs - _periods[index].startMs;
    }
    return _periods[index + 1].startMs - _periods[index].startMs;
  }

  int getPeriodDurationUs(int index) => Util.msToUs(getPeriodDurationMs(index));
}
