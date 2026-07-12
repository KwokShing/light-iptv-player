// A DASH representation.
//
// Dart port of ExoPlayer's `Representation`
// (androidx.media3.exoplayer.dash.manifest.Representation) and its
// SingleSegmentRepresentation / MultiSegmentRepresentation subclasses, plus the
// SingleSegmentIndex helper (from SingleSegmentIndex.java). MultiSegment
// representations implement [DashSegmentIndex] directly, exactly like the
// original.

import 'base_url.dart';
import 'dash_c.dart';
import 'dash_segment_index.dart';
import 'descriptor.dart';
import 'format.dart';
import 'ranged_uri.dart';
import 'segment_base.dart';

abstract class Representation {
  static const int revisionIdDefault = -1;

  final int revisionId;
  final Format format;
  final List<BaseUrl> baseUrls;
  final int presentationTimeOffsetUs;
  final List<Descriptor> inbandEventStreams;
  final List<Descriptor> essentialProperties;
  final List<Descriptor> supplementalProperties;
  final RangedUri? _initializationUri;

  // Dart can't compute fields depending on `this` before super(), so subclasses
  // resolve the segment-derived fields (init URI, presentation offset)
  // themselves and pass them here.
  Representation._raw(
    this.revisionId,
    this.format,
    this.baseUrls,
    List<Descriptor>? inbandEventStreams,
    this.essentialProperties,
    this.supplementalProperties,
    this._initializationUri,
    this.presentationTimeOffsetUs,
  ) : inbandEventStreams = inbandEventStreams ?? const [];

  static Representation newInstance(
    int revisionId,
    Format format,
    List<BaseUrl> baseUrls,
    SegmentBase segmentBase, {
    List<Descriptor>? inbandEventStreams,
    List<Descriptor> essentialProperties = const [],
    List<Descriptor> supplementalProperties = const [],
    String? cacheKey,
  }) {
    if (segmentBase is SingleSegmentBase) {
      return SingleSegmentRepresentation(
        revisionId,
        format,
        baseUrls,
        segmentBase,
        inbandEventStreams,
        essentialProperties,
        supplementalProperties,
        cacheKey,
        C.lengthUnset,
      );
    } else if (segmentBase is MultiSegmentBase) {
      return MultiSegmentRepresentation(
        revisionId,
        format,
        baseUrls,
        segmentBase,
        inbandEventStreams,
        essentialProperties,
        supplementalProperties,
      );
    } else {
      throw ArgumentError(
          'segmentBase must be SingleSegmentBase or MultiSegmentBase');
    }
  }

  /// Location of the representation's initialization data, or null.
  RangedUri? getInitializationUri() => _initializationUri;

  /// Location of the representation's segment index, or null if provided
  /// directly.
  RangedUri? getIndexUri();

  /// An index the representation provides directly, or null.
  DashSegmentIndex? getIndex();

  /// A cache key for the representation, or null.
  String? getCacheKey();
}

/// A DASH representation consisting of a single segment.
class SingleSegmentRepresentation extends Representation {
  final String uri;
  final int contentLength;
  final String? _cacheKey;
  final RangedUri? _indexUri;
  final SingleSegmentIndex? _segmentIndex;

  SingleSegmentRepresentation._(
    super.revisionId,
    super.format,
    super.baseUrls,
    super.inbandEventStreams,
    super.essentialProperties,
    super.supplementalProperties,
    super.initializationUri,
    super.presentationTimeOffsetUs,
    this.uri,
    this.contentLength,
    this._cacheKey,
    this._indexUri,
    this._segmentIndex,
  ) : super._raw();

  factory SingleSegmentRepresentation(
    int revisionId,
    Format format,
    List<BaseUrl> baseUrls,
    SingleSegmentBase segmentBase,
    List<Descriptor>? inbandEventStreams,
    List<Descriptor> essentialProperties,
    List<Descriptor> supplementalProperties,
    String? cacheKey,
    int contentLength,
  ) {
    final uri = baseUrls[0].url;
    final indexUri = segmentBase.getIndex();
    final presentationTimeOffsetUs = segmentBase.getPresentationTimeOffsetUs();
    // getInitialization does not depend on `this` for SingleSegmentBase.
    final initializationUri = segmentBase.initialization;
    // If we have an index uri then the index is external; otherwise we can do
    // no better than a single-segment index.
    final segmentIndex =
        indexUri != null ? null : SingleSegmentIndex(RangedUri(null, 0, contentLength));
    return SingleSegmentRepresentation._(
      revisionId,
      format,
      baseUrls,
      inbandEventStreams,
      essentialProperties,
      supplementalProperties,
      initializationUri,
      presentationTimeOffsetUs,
      uri,
      contentLength,
      cacheKey,
      indexUri,
      segmentIndex,
    );
  }

  @override
  RangedUri? getIndexUri() => _indexUri;

  @override
  DashSegmentIndex? getIndex() => _segmentIndex;

  @override
  String? getCacheKey() => _cacheKey;
}

/// A DASH representation consisting of multiple segments; is its own
/// [DashSegmentIndex].
class MultiSegmentRepresentation extends Representation
    implements DashSegmentIndex {
  final MultiSegmentBase segmentBase;

  MultiSegmentRepresentation._(
    super.revisionId,
    super.format,
    super.baseUrls,
    super.inbandEventStreams,
    super.essentialProperties,
    super.supplementalProperties,
    super.initializationUri,
    super.presentationTimeOffsetUs,
    this.segmentBase,
  ) : super._raw();

  factory MultiSegmentRepresentation(
    int revisionId,
    Format format,
    List<BaseUrl> baseUrls,
    MultiSegmentBase segmentBase,
    List<Descriptor>? inbandEventStreams,
    List<Descriptor> essentialProperties,
    List<Descriptor> supplementalProperties,
  ) {
    final presentationTimeOffsetUs = segmentBase.getPresentationTimeOffsetUs();
    final rep = MultiSegmentRepresentation._(
      revisionId,
      format,
      baseUrls,
      inbandEventStreams,
      essentialProperties,
      supplementalProperties,
      null, // set below once the instance exists
      presentationTimeOffsetUs,
      segmentBase,
    );
    return rep;
  }

  // The template-based initialization depends on `this` (the representation's
  // format id/bitrate), so resolve it lazily rather than in the constructor.
  @override
  RangedUri? getInitializationUri() => segmentBase.getInitialization(this);

  @override
  RangedUri? getIndexUri() => null;

  @override
  DashSegmentIndex getIndex() => this;

  @override
  String? getCacheKey() => null;

  // DashSegmentIndex implementation, delegating to the MultiSegmentBase.

  @override
  RangedUri getSegmentUrl(int segmentNum) =>
      segmentBase.getSegmentUrl(this, segmentNum);

  @override
  int getSegmentNum(int timeUs, int periodDurationUs) =>
      segmentBase.getSegmentNum(timeUs, periodDurationUs);

  @override
  int getTimeUs(int segmentNum) => segmentBase.getSegmentTimeUs(segmentNum);

  @override
  int getDurationUs(int segmentNum, int periodDurationUs) =>
      segmentBase.getSegmentDurationUs(segmentNum, periodDurationUs);

  @override
  int getFirstSegmentNum() => segmentBase.getFirstSegmentNum();

  @override
  int getFirstAvailableSegmentNum(int periodDurationUs, int nowUnixTimeUs) =>
      segmentBase.getFirstAvailableSegmentNum(periodDurationUs, nowUnixTimeUs);

  @override
  int getSegmentCount(int periodDurationUs) =>
      segmentBase.getSegmentCount(periodDurationUs);

  @override
  int getAvailableSegmentCount(int periodDurationUs, int nowUnixTimeUs) =>
      segmentBase.getAvailableSegmentCount(periodDurationUs, nowUnixTimeUs);

  @override
  int getNextSegmentAvailableTimeUs(int periodDurationUs, int nowUnixTimeUs) =>
      segmentBase.getNextSegmentAvailableTimeUs(periodDurationUs, nowUnixTimeUs);

  @override
  bool isExplicit() => segmentBase.isExplicit();
}

/// A [DashSegmentIndex] that defines a single segment. Dart port of
/// ExoPlayer's `SingleSegmentIndex`.
class SingleSegmentIndex implements DashSegmentIndex {
  final RangedUri uri;

  SingleSegmentIndex(this.uri);

  @override
  int getSegmentNum(int timeUs, int periodDurationUs) => 0;

  @override
  int getTimeUs(int segmentNum) => 0;

  @override
  int getDurationUs(int segmentNum, int periodDurationUs) => periodDurationUs;

  @override
  RangedUri getSegmentUrl(int segmentNum) => uri;

  @override
  int getFirstSegmentNum() => 0;

  @override
  int getFirstAvailableSegmentNum(int periodDurationUs, int nowUnixTimeUs) => 0;

  @override
  int getSegmentCount(int periodDurationUs) => 1;

  @override
  int getAvailableSegmentCount(int periodDurationUs, int nowUnixTimeUs) => 1;

  @override
  int getNextSegmentAvailableTimeUs(int periodDurationUs, int nowUnixTimeUs) =>
      C.timeUnset;

  @override
  bool isExplicit() => true;
}
