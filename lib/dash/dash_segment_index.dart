// Indexes the segments within a media stream.
//
// Direct Dart port of ExoPlayer's `DashSegmentIndex`
// (androidx.media3.exoplayer.dash.DashSegmentIndex). Maps between segment
// number, media time and segment URL, and exposes the availability window for
// dynamic (live) manifests.

import 'ranged_uri.dart';

abstract class DashSegmentIndex {
  static const int indexUnbounded = -1;

  /// Segment number of the segment containing [timeUs] (clamped to the range),
  /// given the enclosing [periodDurationUs].
  int getSegmentNum(int timeUs, int periodDurationUs);

  /// Start time (microseconds) of [segmentNum].
  int getTimeUs(int segmentNum);

  /// Duration (microseconds) of [segmentNum].
  int getDurationUs(int segmentNum, int periodDurationUs);

  /// [RangedUri] locating [segmentNum].
  RangedUri getSegmentUrl(int segmentNum);

  /// The number of the first defined segment.
  int getFirstSegmentNum();

  /// The number of the first available segment.
  int getFirstAvailableSegmentNum(int periodDurationUs, int nowUnixTimeUs);

  /// Number of segments defined, or [indexUnbounded].
  int getSegmentCount(int periodDurationUs);

  /// Number of currently available segments.
  int getAvailableSegmentCount(int periodDurationUs, int nowUnixTimeUs);

  /// Time (microseconds) at which a new segment becomes available, or
  /// [C.timeUnset] if not applicable.
  int getNextSegmentAvailableTimeUs(int periodDurationUs, int nowUnixTimeUs);

  /// Whether segments are defined explicitly (i.e. via a SegmentTimeline).
  bool isExplicit();
}
