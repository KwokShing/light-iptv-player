// An approximate representation of a SegmentBase manifest element.
//
// Direct Dart port of ExoPlayer's `SegmentBase` and its subclasses
// (androidx.media3.exoplayer.dash.manifest.SegmentBase): SingleSegmentBase,
// MultiSegmentBase, SegmentList, SegmentTemplate and SegmentTimelineElement.
// This is the algorithmic heart of DASH addressing (segmentNum <-> time <->
// URL). ExoPlayer's BigInteger segment-count maths is preserved using Dart's
// arbitrary-precision `int`.

import 'dash_c.dart';
import 'dash_segment_index.dart';
import 'ranged_uri.dart';
import 'representation.dart';
import 'url_template.dart';

abstract class SegmentBase {
  final RangedUri? initialization;
  final int timescale;
  final int presentationTimeOffset;

  SegmentBase(this.initialization, this.timescale, this.presentationTimeOffset);

  /// Location of initialization data for [representation], or null.
  RangedUri? getInitialization(Representation representation) => initialization;

  /// Presentation time offset in microseconds.
  int getPresentationTimeOffsetUs() =>
      Util.scaleLargeTimestamp(presentationTimeOffset, C.microsPerSecond, timescale);
}

/// A [SegmentBase] that defines a single segment.
class SingleSegmentBase extends SegmentBase {
  final int indexStart;
  final int indexLength;

  SingleSegmentBase(
    super.initialization,
    super.timescale,
    super.presentationTimeOffset,
    this.indexStart,
    this.indexLength,
  );

  SingleSegmentBase.defaults()
      : this(null, 1, 0, 0, 0);

  RangedUri? getIndex() =>
      indexLength <= 0 ? null : RangedUri(null, indexStart, indexLength);
}

/// A [SegmentBase] consisting of multiple segments.
abstract class MultiSegmentBase extends SegmentBase {
  final int startNumber;
  final int duration;
  final List<SegmentTimelineElement>? segmentTimeline;
  final int timeShiftBufferDepthUs;
  final int periodStartUnixTimeUs;
  final int availabilityTimeOffsetUs;

  MultiSegmentBase(
    super.initialization,
    super.timescale,
    super.presentationTimeOffset,
    this.startNumber,
    this.duration,
    this.segmentTimeline,
    this.availabilityTimeOffsetUs,
    this.timeShiftBufferDepthUs,
    this.periodStartUnixTimeUs,
  );

  /// See [DashSegmentIndex.getSegmentNum].
  int getSegmentNum(int timeUs, int periodDurationUs) {
    final firstSegmentNum = getFirstSegmentNum();
    final segmentCount = getSegmentCount(periodDurationUs);
    if (segmentCount == 0) {
      return firstSegmentNum;
    }
    if (segmentTimeline == null) {
      // Segments of equal duration (last one possibly excepted).
      final durationUs = (duration * C.microsPerSecond) ~/ timescale;
      final segmentNum = startNumber + timeUs ~/ durationUs;
      if (segmentNum < firstSegmentNum) return firstSegmentNum;
      return segmentCount == DashSegmentIndex.indexUnbounded
          ? segmentNum
          : (segmentNum < firstSegmentNum + segmentCount - 1
              ? segmentNum
              : firstSegmentNum + segmentCount - 1);
    } else {
      // Bounded index: binary search.
      var lowIndex = firstSegmentNum;
      var highIndex = firstSegmentNum + segmentCount - 1;
      while (lowIndex <= highIndex) {
        final midIndex = lowIndex + (highIndex - lowIndex) ~/ 2;
        final midTimeUs = getSegmentTimeUs(midIndex);
        if (midTimeUs < timeUs) {
          lowIndex = midIndex + 1;
        } else if (midTimeUs > timeUs) {
          highIndex = midIndex - 1;
        } else {
          return midIndex;
        }
      }
      return lowIndex == firstSegmentNum ? lowIndex : highIndex;
    }
  }

  /// See [DashSegmentIndex.getDurationUs].
  int getSegmentDurationUs(int sequenceNumber, int periodDurationUs) {
    final timeline = segmentTimeline;
    if (timeline != null) {
      final d = timeline[sequenceNumber - startNumber].duration;
      return (d * C.microsPerSecond) ~/ timescale;
    } else {
      final segmentCount = getSegmentCount(periodDurationUs);
      return segmentCount != DashSegmentIndex.indexUnbounded &&
              sequenceNumber == getFirstSegmentNum() + segmentCount - 1
          ? periodDurationUs - getSegmentTimeUs(sequenceNumber)
          : (duration * C.microsPerSecond) ~/ timescale;
    }
  }

  /// See [DashSegmentIndex.getTimeUs].
  int getSegmentTimeUs(int sequenceNumber) {
    int unscaledSegmentTime;
    final timeline = segmentTimeline;
    if (timeline != null) {
      unscaledSegmentTime =
          timeline[sequenceNumber - startNumber].startTime - presentationTimeOffset;
    } else {
      unscaledSegmentTime = (sequenceNumber - startNumber) * duration;
    }
    return Util.scaleLargeTimestamp(unscaledSegmentTime, C.microsPerSecond, timescale);
  }

  /// [RangedUri] for [index] in [representation]. See
  /// [DashSegmentIndex.getSegmentUrl].
  RangedUri getSegmentUrl(Representation representation, int index);

  /// See [DashSegmentIndex.getFirstSegmentNum].
  int getFirstSegmentNum() => startNumber;

  /// See [DashSegmentIndex.getFirstAvailableSegmentNum].
  int getFirstAvailableSegmentNum(int periodDurationUs, int nowUnixTimeUs) {
    final segmentCount = getSegmentCount(periodDurationUs);
    if (segmentCount != DashSegmentIndex.indexUnbounded ||
        timeShiftBufferDepthUs == C.timeUnset) {
      return getFirstSegmentNum();
    }
    final liveEdgeTimeInPeriodUs = nowUnixTimeUs - periodStartUnixTimeUs;
    final timeShiftBufferStartInPeriodUs =
        liveEdgeTimeInPeriodUs - timeShiftBufferDepthUs;
    final timeShiftBufferStartSegmentNum =
        getSegmentNum(timeShiftBufferStartInPeriodUs, periodDurationUs);
    final first = getFirstSegmentNum();
    return first > timeShiftBufferStartSegmentNum
        ? first
        : timeShiftBufferStartSegmentNum;
  }

  /// See [DashSegmentIndex.getAvailableSegmentCount].
  int getAvailableSegmentCount(int periodDurationUs, int nowUnixTimeUs) {
    final segmentCount = getSegmentCount(periodDurationUs);
    if (segmentCount != DashSegmentIndex.indexUnbounded) {
      return segmentCount;
    }
    final liveEdgeTimeInPeriodUs = nowUnixTimeUs - periodStartUnixTimeUs;
    final availabilityTimeOffsetUs =
        liveEdgeTimeInPeriodUs + this.availabilityTimeOffsetUs;
    final firstIncompleteSegmentNum =
        getSegmentNum(availabilityTimeOffsetUs, periodDurationUs);
    final firstAvailableSegmentNum =
        getFirstAvailableSegmentNum(periodDurationUs, nowUnixTimeUs);
    return firstIncompleteSegmentNum - firstAvailableSegmentNum;
  }

  /// See [DashSegmentIndex.getNextSegmentAvailableTimeUs].
  int getNextSegmentAvailableTimeUs(int periodDurationUs, int nowUnixTimeUs) {
    if (segmentTimeline != null) {
      return C.timeUnset;
    }
    final firstIncompleteSegmentNum =
        getFirstAvailableSegmentNum(periodDurationUs, nowUnixTimeUs) +
            getAvailableSegmentCount(periodDurationUs, nowUnixTimeUs);
    return getSegmentTimeUs(firstIncompleteSegmentNum) +
        getSegmentDurationUs(firstIncompleteSegmentNum, periodDurationUs) -
        availabilityTimeOffsetUs;
  }

  bool isExplicit() => segmentTimeline != null;

  /// See [DashSegmentIndex.getSegmentCount].
  int getSegmentCount(int periodDurationUs);
}

/// A [MultiSegmentBase] that uses a SegmentList to define its segments.
class SegmentList extends MultiSegmentBase {
  final List<RangedUri>? mediaSegments;

  SegmentList(
    RangedUri? initialization,
    int timescale,
    int presentationTimeOffset,
    int startNumber,
    int duration,
    List<SegmentTimelineElement>? segmentTimeline,
    int availabilityTimeOffsetUs,
    this.mediaSegments,
    int timeShiftBufferDepthUs,
    int periodStartUnixTimeUs,
  ) : super(
          initialization,
          timescale,
          presentationTimeOffset,
          startNumber,
          duration,
          segmentTimeline,
          availabilityTimeOffsetUs,
          timeShiftBufferDepthUs,
          periodStartUnixTimeUs,
        );

  @override
  RangedUri getSegmentUrl(Representation representation, int sequenceNumber) =>
      mediaSegments![sequenceNumber - startNumber];

  @override
  int getSegmentCount(int periodDurationUs) => mediaSegments!.length;

  @override
  bool isExplicit() => true;
}

/// A [MultiSegmentBase] that uses a SegmentTemplate to define its segments.
class SegmentTemplate extends MultiSegmentBase {
  final UrlTemplate? initializationTemplate;
  final UrlTemplate? mediaTemplate;
  final int endNumber;

  SegmentTemplate(
    RangedUri? initialization,
    int timescale,
    int presentationTimeOffset,
    int startNumber,
    this.endNumber,
    int duration,
    List<SegmentTimelineElement>? segmentTimeline,
    int availabilityTimeOffsetUs,
    this.initializationTemplate,
    this.mediaTemplate,
    int timeShiftBufferDepthUs,
    int periodStartUnixTimeUs,
  ) : super(
          initialization,
          timescale,
          presentationTimeOffset,
          startNumber,
          duration,
          segmentTimeline,
          availabilityTimeOffsetUs,
          timeShiftBufferDepthUs,
          periodStartUnixTimeUs,
        );

  @override
  RangedUri? getInitialization(Representation representation) {
    final template = initializationTemplate;
    if (template != null) {
      final urlString = template.buildUri(
          representation.format.id ?? '', 0, representation.format.bitrate, 0);
      return RangedUri(urlString, 0, C.lengthUnset);
    }
    return super.getInitialization(representation);
  }

  @override
  RangedUri getSegmentUrl(Representation representation, int sequenceNumber) {
    int time;
    final timeline = segmentTimeline;
    if (timeline != null) {
      time = timeline[sequenceNumber - startNumber].startTime;
    } else {
      time = (sequenceNumber - startNumber) * duration;
    }
    final uriString = mediaTemplate!.buildUri(
      representation.format.id ?? '',
      sequenceNumber,
      representation.format.bitrate,
      time,
    );
    return RangedUri(uriString, 0, C.lengthUnset);
  }

  @override
  int getSegmentCount(int periodDurationUs) {
    final timeline = segmentTimeline;
    if (timeline != null) {
      return timeline.length;
    } else if (endNumber != C.indexUnset) {
      return endNumber - startNumber + 1;
    } else if (periodDurationUs != C.timeUnset) {
      // Ceiling division of (periodDurationUs * timescale) /
      // (duration * MICROS_PER_SECOND). Dart ints are arbitrary precision, so
      // this matches ExoPlayer's BigInteger path exactly.
      final numerator = periodDurationUs * timescale;
      final denominator = duration * C.microsPerSecond;
      return Util.ceilDivide(numerator, denominator);
    } else {
      return DashSegmentIndex.indexUnbounded;
    }
  }
}

/// A timeline segment from the MPD's SegmentTimeline list.
class SegmentTimelineElement {
  final int startTime;
  final int duration;

  SegmentTimelineElement(this.startTime, this.duration);

  @override
  bool operator ==(Object other) =>
      other is SegmentTimelineElement &&
      startTime == other.startTime &&
      duration == other.duration;

  @override
  int get hashCode => 31 * startTime + duration;
}
