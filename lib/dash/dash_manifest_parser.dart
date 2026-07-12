// Parses a DASH manifest (MPD) into a [DashManifest] object tree.
//
// Dart port of the parts of ExoPlayer's `DashManifestParser`
// (androidx.media3.exoplayer.dash.manifest.DashManifestParser) needed to drive
// the mpv-fed clear-fMP4 pipeline. Where ExoPlayer uses Android's pull-style
// `XmlPullParser`, this uses the `xml` package's DOM (`XmlDocument`) and walks
// it recursively — the element/attribute mapping matches the original.
//
// Omitted vs. the original (not needed here): EventStream/emsg, Label,
// Accessibility/Role plumbing, UTCTiming/ServiceDescription, SCTE214
// supplemental codecs, and the full ContentProtection SchemeData extraction
// (we only detect that protection exists and record the cenc:default_KID).

import 'package:xml/xml.dart';

import 'adaptation_set.dart';
import 'base_url.dart';
import 'dash_c.dart';
import 'dash_manifest.dart';
import 'descriptor.dart';
import 'format.dart';
import 'period.dart';
import 'ranged_uri.dart';
import 'representation.dart';
import 'segment_base.dart';
import 'url_template.dart';

/// Result of parsing an AdaptationSet's Representation, carrying the pieces the
/// parent needs to build the final [Representation].
class _RepresentationInfo {
  _RepresentationInfo(
    this.format,
    this.baseUrls,
    this.segmentBase,
    this.cacheKey,
    this.revisionId,
    this.essentialProperties,
    this.supplementalProperties,
  );

  final Format format;
  final List<BaseUrl> baseUrls;
  final SegmentBase segmentBase;
  final String? cacheKey;
  final int revisionId;
  final List<Descriptor> essentialProperties;
  final List<Descriptor> supplementalProperties;
}

class DashManifestParser {
  const DashManifestParser();

  /// Parses [xmlText], resolving relative URLs against [baseUri] (the final URL
  /// the MPD was fetched from).
  DashManifest parse(String baseUri, String xmlText) {
    final doc = XmlDocument.parse(_sanitize(xmlText));
    final root = doc.rootElement;
    if (root.name.local != 'MPD') {
      throw FormatException('Document root is not an MPD element');
    }
    return _parseMediaPresentationDescription(root, baseUri);
  }

  // Some CDNs prepend a UTF-8 BOM or stray whitespace/newlines before the XML
  // declaration, and a few append trailing bytes after </MPD>. Either makes
  // `XmlDocument.parse` reject the document ("Expected a single root element").
  // Strip the BOM and, if a root <MPD> element is present, slice out exactly
  // that element so extraneous surrounding content can't break parsing.
  static String _sanitize(String xmlText) {
    var text = xmlText;
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1); // strip BOM
    }
    text = text.trimLeft();

    final start = text.indexOf('<MPD');
    if (start < 0) return text;
    final endTag = text.lastIndexOf('</MPD>');
    if (endTag >= start) {
      return text.substring(start, endTag + '</MPD>'.length);
    }
    // Self-closing or malformed close: fall back to everything from <MPD on,
    // keeping any XML declaration only if it precedes <MPD (dropped here since
    // xml can parse a bare element too).
    return text.substring(start);
  }

  // ---------------------------------------------------------------------------
  // MPD
  // ---------------------------------------------------------------------------

  DashManifest _parseMediaPresentationDescription(XmlElement mpd, String docBase) {
    final availabilityStartTime =
        _parseDateTime(mpd, 'availabilityStartTime', C.timeUnset);
    var durationMs = _parseDuration(mpd, 'mediaPresentationDuration', C.timeUnset);
    final minBufferTimeMs = _parseDuration(mpd, 'minBufferTime', C.timeUnset);
    final dynamic = mpd.getAttribute('type') == 'dynamic';
    final minUpdateTimeMs =
        dynamic ? _parseDuration(mpd, 'minimumUpdatePeriod', C.timeUnset) : C.timeUnset;
    final timeShiftBufferDepthMs =
        dynamic ? _parseDuration(mpd, 'timeShiftBufferDepth', C.timeUnset) : C.timeUnset;
    final suggestedPresentationDelayMs = dynamic
        ? _parseDuration(mpd, 'suggestedPresentationDelay', C.timeUnset)
        : C.timeUnset;
    final publishTimeMs = _parseDateTime(mpd, 'publishTime', C.timeUnset);

    var docBaseUrl = docBase;
    String? location;
    final periods = <Period>[];
    var nextPeriodStartMs = dynamic ? C.timeUnset : 0;
    var seenEarlyAccessPeriod = false;

    for (final child in mpd.childElements) {
      switch (child.name.local) {
        case 'BaseURL':
          docBaseUrl = UriUtil.resolve(docBaseUrl, child.innerText.trim());
          break;
        case 'Location':
          location = UriUtil.resolve(docBase, child.innerText.trim());
          break;
        case 'Period':
          if (seenEarlyAccessPeriod) break;
          final result = _parsePeriod(
            child,
            docBaseUrl,
            nextPeriodStartMs,
            availabilityStartTime,
            timeShiftBufferDepthMs,
          );
          final period = result.$1;
          if (period.startMs == C.timeUnset) {
            if (dynamic) {
              seenEarlyAccessPeriod = true;
            } else {
              throw FormatException(
                  'Unable to determine start of period ${periods.length}');
            }
          } else {
            final periodDurationMs = result.$2;
            nextPeriodStartMs = periodDurationMs == C.timeUnset
                ? C.timeUnset
                : period.startMs + periodDurationMs;
            periods.add(period);
          }
          break;
        default:
          break;
      }
    }

    if (durationMs == C.timeUnset) {
      if (nextPeriodStartMs != C.timeUnset) {
        durationMs = nextPeriodStartMs;
      } else if (!dynamic) {
        throw FormatException('Unable to determine duration of static manifest.');
      }
    }
    if (periods.isEmpty) {
      throw FormatException('No periods found.');
    }

    return DashManifest(
      availabilityStartTimeMs: availabilityStartTime,
      durationMs: durationMs,
      minBufferTimeMs: minBufferTimeMs,
      dynamic: dynamic,
      minUpdatePeriodMs: minUpdateTimeMs,
      timeShiftBufferDepthMs: timeShiftBufferDepthMs,
      suggestedPresentationDelayMs: suggestedPresentationDelayMs,
      publishTimeMs: publishTimeMs,
      location: location,
      periods: periods,
    );
  }

  // ---------------------------------------------------------------------------
  // Period
  // ---------------------------------------------------------------------------

  (Period, int) _parsePeriod(
    XmlElement period,
    String parentBaseUrl,
    int defaultStartMs,
    int availabilityStartTimeMs,
    int timeShiftBufferDepthMs,
  ) {
    final id = period.getAttribute('id');
    final startMs = _parseDuration(period, 'start', defaultStartMs);
    final periodStartUnixTimeMs = availabilityStartTimeMs != C.timeUnset
        ? availabilityStartTimeMs + startMs
        : C.timeUnset;
    final durationMs = _parseDuration(period, 'duration', C.timeUnset);

    var baseUrl = parentBaseUrl;
    SegmentBase? segmentBase;
    Descriptor? assetIdentifier;
    final adaptationSets = <AdaptationSet>[];

    for (final child in period.childElements) {
      switch (child.name.local) {
        case 'BaseURL':
          baseUrl = UriUtil.resolve(baseUrl, child.innerText.trim());
          break;
        case 'SegmentBase':
          segmentBase = _parseSegmentBase(child, null);
          break;
        case 'SegmentList':
          segmentBase = _parseSegmentList(child, null, periodStartUnixTimeMs,
              durationMs, timeShiftBufferDepthMs);
          break;
        case 'SegmentTemplate':
          segmentBase = _parseSegmentTemplate(child, null, const [],
              periodStartUnixTimeMs, durationMs, timeShiftBufferDepthMs);
          break;
        case 'AssetIdentifier':
          assetIdentifier = _parseDescriptor(child);
          break;
        default:
          break;
      }
    }

    for (final child in period.childElements) {
      if (child.name.local == 'AdaptationSet') {
        adaptationSets.add(_parseAdaptationSet(
          child,
          baseUrl,
          segmentBase,
          durationMs,
          periodStartUnixTimeMs,
          timeShiftBufferDepthMs,
        ));
      }
    }

    return (Period(id, startMs, adaptationSets, assetIdentifier), durationMs);
  }

  // ---------------------------------------------------------------------------
  // AdaptationSet
  // ---------------------------------------------------------------------------

  AdaptationSet _parseAdaptationSet(
    XmlElement as_,
    String parentBaseUrl,
    SegmentBase? segmentBase,
    int periodDurationMs,
    int periodStartUnixTimeMs,
    int timeShiftBufferDepthMs,
  ) {
    final id = _parseLong(as_, 'id', AdaptationSet.idUnset);
    var contentType = _parseContentType(as_);

    final mimeType = as_.getAttribute('mimeType');
    final codecs = as_.getAttribute('codecs');
    final width = _parseInt(as_, 'width', C.lengthUnset);
    final height = _parseInt(as_, 'height', C.lengthUnset);
    final frameRate = _parseFrameRate(as_, -1);
    var audioChannels = C.rateUnset;
    final audioSamplingRate = _parseInt(as_, 'audioSamplingRate', C.rateUnset);
    var language = as_.getAttribute('lang');

    var baseUrl = parentBaseUrl;
    final essentialProperties = <Descriptor>[];
    final supplementalProperties = <Descriptor>[];
    final accessibilityDescriptors = <Descriptor>[];
    final inbandEventStreams = <Descriptor>[];
    final representationElements = <XmlElement>[];
    var hasContentProtection = false;
    String? defaultKid;

    for (final child in as_.childElements) {
      switch (child.name.local) {
        case 'BaseURL':
          baseUrl = UriUtil.resolve(baseUrl, child.innerText.trim());
          break;
        case 'ContentProtection':
          hasContentProtection = true;
          defaultKid ??= _parseDefaultKid(child);
          break;
        case 'ContentComponent':
          language = _checkLanguageConsistency(
              language, child.getAttribute('lang'));
          contentType = _checkContentTypeConsistency(
              contentType, _parseContentType(child));
          break;
        case 'AudioChannelConfiguration':
          audioChannels = _parseAudioChannelConfiguration(child);
          break;
        case 'Accessibility':
          accessibilityDescriptors.add(_parseDescriptor(child));
          break;
        case 'EssentialProperty':
          essentialProperties.add(_parseDescriptor(child));
          break;
        case 'SupplementalProperty':
          supplementalProperties.add(_parseDescriptor(child));
          break;
        case 'InbandEventStream':
          inbandEventStreams.add(_parseDescriptor(child));
          break;
        case 'SegmentBase':
          segmentBase = _parseSegmentBase(child, segmentBase as SingleSegmentBase?);
          break;
        case 'SegmentList':
          segmentBase = _parseSegmentList(
              child,
              segmentBase as SegmentList?,
              periodStartUnixTimeMs,
              periodDurationMs,
              timeShiftBufferDepthMs);
          break;
        case 'SegmentTemplate':
          segmentBase = _parseSegmentTemplate(
              child,
              segmentBase as SegmentTemplate?,
              supplementalProperties,
              periodStartUnixTimeMs,
              periodDurationMs,
              timeShiftBufferDepthMs);
          break;
        case 'Representation':
          representationElements.add(child);
          break;
        default:
          break;
      }
    }

    final representationInfos = <_RepresentationInfo>[];
    for (final repEl in representationElements) {
      final info = _parseRepresentation(
        repEl,
        baseUrl,
        mimeType,
        codecs,
        width,
        height,
        frameRate,
        audioChannels,
        audioSamplingRate,
        language,
        contentType,
        essentialProperties,
        supplementalProperties,
        inbandEventStreams,
        segmentBase,
        periodStartUnixTimeMs,
        periodDurationMs,
        timeShiftBufferDepthMs,
      );
      contentType = _checkContentTypeConsistency(
          contentType, _trackTypeForFormat(info.format));
      representationInfos.add(info);
    }

    final representations = <Representation>[];
    for (final info in representationInfos) {
      representations.add(Representation.newInstance(
        info.revisionId,
        info.format,
        info.baseUrls,
        info.segmentBase,
        inbandEventStreams: inbandEventStreams,
        essentialProperties: info.essentialProperties,
        supplementalProperties: info.supplementalProperties,
        cacheKey: info.cacheKey,
      ));
    }

    // hasContentProtection/defaultKid are attached to the AdaptationSet via a
    // synthesized supplemental descriptor so the scheduler can look them up
    // without the full ExoPlayer DRM model.
    if (hasContentProtection) {
      supplementalProperties.add(Descriptor(
          'urn:lip:contentprotection', defaultKid, null));
    }

    return AdaptationSet(
      id,
      contentType,
      representations,
      accessibilityDescriptors,
      essentialProperties,
      supplementalProperties,
    );
  }

  // ---------------------------------------------------------------------------
  // Representation
  // ---------------------------------------------------------------------------

  _RepresentationInfo _parseRepresentation(
    XmlElement rep,
    String parentBaseUrl,
    String? adaptationSetMimeType,
    String? adaptationSetCodecs,
    int adaptationSetWidth,
    int adaptationSetHeight,
    double adaptationSetFrameRate,
    int adaptationSetAudioChannels,
    int adaptationSetAudioSamplingRate,
    String? adaptationSetLanguage,
    int adaptationSetContentType,
    List<Descriptor> adaptationSetEssentialProperties,
    List<Descriptor> adaptationSetSupplementalProperties,
    List<Descriptor> adaptationSetInbandEventStreams,
    SegmentBase? segmentBase,
    int periodStartUnixTimeMs,
    int periodDurationMs,
    int timeShiftBufferDepthMs,
  ) {
    final id = rep.getAttribute('id');
    final bandwidth = _parseInt(rep, 'bandwidth', C.rateUnset);

    final mimeType = rep.getAttribute('mimeType') ?? adaptationSetMimeType;
    final codecs = rep.getAttribute('codecs') ?? adaptationSetCodecs;
    final width = _parseInt(rep, 'width', adaptationSetWidth);
    final height = _parseInt(rep, 'height', adaptationSetHeight);
    final frameRate = _parseFrameRate(rep, adaptationSetFrameRate);
    var audioChannels = adaptationSetAudioChannels;
    final audioSamplingRate =
        _parseInt(rep, 'audioSamplingRate', adaptationSetAudioSamplingRate);

    var baseUrl = parentBaseUrl;
    final essentialProperties =
        List<Descriptor>.from(adaptationSetEssentialProperties);
    final supplementalProperties =
        List<Descriptor>.from(adaptationSetSupplementalProperties);

    for (final child in rep.childElements) {
      switch (child.name.local) {
        case 'BaseURL':
          baseUrl = UriUtil.resolve(baseUrl, child.innerText.trim());
          break;
        case 'AudioChannelConfiguration':
          audioChannels = _parseAudioChannelConfiguration(child);
          break;
        case 'SegmentBase':
          segmentBase = _parseSegmentBase(child, segmentBase as SingleSegmentBase?);
          break;
        case 'SegmentList':
          segmentBase = _parseSegmentList(
              child,
              segmentBase as SegmentList?,
              periodStartUnixTimeMs,
              periodDurationMs,
              timeShiftBufferDepthMs);
          break;
        case 'SegmentTemplate':
          segmentBase = _parseSegmentTemplate(
              child,
              segmentBase as SegmentTemplate?,
              supplementalProperties,
              periodStartUnixTimeMs,
              periodDurationMs,
              timeShiftBufferDepthMs);
          break;
        case 'EssentialProperty':
          essentialProperties.add(_parseDescriptor(child));
          break;
        case 'SupplementalProperty':
          supplementalProperties.add(_parseDescriptor(child));
          break;
        default:
          break;
      }
    }

    final format = Format(
      id: id,
      containerMimeType: mimeType,
      sampleMimeType: mimeType,
      codecs: codecs,
      bitrate: bandwidth,
      width: width,
      height: height,
      frameRate: frameRate,
      sampleRate: audioSamplingRate,
      channelCount: audioChannels,
      language: adaptationSetLanguage,
    );

    final SegmentBase resolvedSegmentBase =
        segmentBase ?? SingleSegmentBase.defaults();

    return _RepresentationInfo(
      format,
      [BaseUrl(baseUrl)],
      resolvedSegmentBase,
      null,
      Representation.revisionIdDefault,
      essentialProperties,
      supplementalProperties,
    );
  }

  // ---------------------------------------------------------------------------
  // SegmentBase / SegmentList / SegmentTemplate
  // ---------------------------------------------------------------------------

  SingleSegmentBase _parseSegmentBase(XmlElement el, SingleSegmentBase? parent) {
    final timescale = _parseLong(el, 'timescale', parent?.timescale ?? 1);
    final presentationTimeOffset = _parseLong(
        el, 'presentationTimeOffset', parent?.presentationTimeOffset ?? 0);

    var indexStart = parent?.indexStart ?? 0;
    var indexLength = parent?.indexLength ?? 0;
    final indexRangeText = el.getAttribute('indexRange');
    if (indexRangeText != null) {
      final parts = indexRangeText.split('-');
      indexStart = int.parse(parts[0]);
      indexLength = int.parse(parts[1]) - indexStart + 1;
    }

    RangedUri? initialization = parent?.initialization;
    final initEl = _firstChild(el, 'Initialization');
    if (initEl != null) {
      initialization = _parseInitialization(initEl);
    }

    return SingleSegmentBase(
      initialization,
      timescale,
      presentationTimeOffset,
      indexStart,
      indexLength,
    );
  }

  SegmentList _parseSegmentList(
    XmlElement el,
    SegmentList? parent,
    int periodStartUnixTimeMs,
    int periodDurationMs,
    int timeShiftBufferDepthMs,
  ) {
    final timescale = _parseLong(el, 'timescale', parent?.timescale ?? 1);
    final presentationTimeOffset = _parseLong(
        el, 'presentationTimeOffset', parent?.presentationTimeOffset ?? 0);
    final duration = _parseLong(el, 'duration', parent?.duration ?? C.timeUnset);
    final startNumber = _parseLong(el, 'startNumber', parent?.startNumber ?? 1);
    const availabilityTimeOffsetUs = C.timeUnset;

    RangedUri? initialization = parent?.initialization;
    List<SegmentTimelineElement>? timeline = parent?.segmentTimeline;
    List<RangedUri>? segments = parent?.mediaSegments;

    for (final child in el.childElements) {
      switch (child.name.local) {
        case 'Initialization':
          initialization = _parseInitialization(child);
          break;
        case 'SegmentTimeline':
          timeline = _parseSegmentTimeline(child, timescale, periodDurationMs);
          break;
        case 'SegmentURL':
          segments ??= <RangedUri>[];
          segments.add(_parseSegmentUrl(child));
          break;
        default:
          break;
      }
    }

    return SegmentList(
      initialization,
      timescale,
      presentationTimeOffset,
      startNumber,
      duration,
      timeline,
      availabilityTimeOffsetUs,
      segments,
      Util.msToUs(timeShiftBufferDepthMs),
      Util.msToUs(periodStartUnixTimeMs),
    );
  }

  SegmentTemplate _parseSegmentTemplate(
    XmlElement el,
    SegmentTemplate? parent,
    List<Descriptor> adaptationSetSupplementalProperties,
    int periodStartUnixTimeMs,
    int periodDurationMs,
    int timeShiftBufferDepthMs,
  ) {
    final timescale = _parseLong(el, 'timescale', parent?.timescale ?? 1);
    final presentationTimeOffset = _parseLong(
        el, 'presentationTimeOffset', parent?.presentationTimeOffset ?? 0);
    final duration = _parseLong(el, 'duration', parent?.duration ?? C.timeUnset);
    final startNumber = _parseLong(el, 'startNumber', parent?.startNumber ?? 1);
    final endNumber = _parseLastSegmentNumberSupplementalProperty(
        adaptationSetSupplementalProperties);
    const availabilityTimeOffsetUs = C.timeUnset;

    final mediaTemplate =
        _parseUrlTemplate(el, 'media', parent?.mediaTemplate);
    final initializationTemplate =
        _parseUrlTemplate(el, 'initialization', parent?.initializationTemplate);

    RangedUri? initialization;
    List<SegmentTimelineElement>? timeline;
    for (final child in el.childElements) {
      switch (child.name.local) {
        case 'Initialization':
          initialization = _parseInitialization(child);
          break;
        case 'SegmentTimeline':
          timeline = _parseSegmentTimeline(child, timescale, periodDurationMs);
          break;
        default:
          break;
      }
    }

    if (parent != null) {
      initialization ??= parent.initialization;
      timeline ??= parent.segmentTimeline;
    }

    return SegmentTemplate(
      initialization,
      timescale,
      presentationTimeOffset,
      startNumber,
      endNumber,
      duration,
      timeline,
      availabilityTimeOffsetUs,
      initializationTemplate,
      mediaTemplate,
      Util.msToUs(timeShiftBufferDepthMs),
      Util.msToUs(periodStartUnixTimeMs),
    );
  }

  List<SegmentTimelineElement> _parseSegmentTimeline(
      XmlElement el, int timescale, int periodDurationMs) {
    final segmentTimeline = <SegmentTimelineElement>[];
    var startTime = 0;
    var elementDuration = C.timeUnset;
    var elementRepeatCount = 0;
    var havePrevious = false;

    for (final s in el.childElements) {
      if (s.name.local != 'S') continue;
      final newStartTime = _parseLong(s, 't', C.timeUnset);
      if (havePrevious) {
        startTime = _addSegmentTimelineElements(segmentTimeline, startTime,
            elementDuration, elementRepeatCount, newStartTime);
      }
      if (newStartTime != C.timeUnset) {
        startTime = newStartTime;
      }
      elementDuration = _parseLong(s, 'd', C.timeUnset);
      elementRepeatCount = _parseInt(s, 'r', 0);
      havePrevious = true;
    }
    if (havePrevious) {
      final periodDuration =
          Util.scaleLargeTimestamp(periodDurationMs, timescale, 1000);
      _addSegmentTimelineElements(segmentTimeline, startTime, elementDuration,
          elementRepeatCount, periodDuration);
    }
    return segmentTimeline;
  }

  int _addSegmentTimelineElements(
    List<SegmentTimelineElement> segmentTimeline,
    int startTime,
    int elementDuration,
    int elementRepeatCount,
    int endTime,
  ) {
    final count = elementRepeatCount >= 0
        ? 1 + elementRepeatCount
        : Util.ceilDivide(endTime - startTime, elementDuration);
    var t = startTime;
    for (var i = 0; i < count; i++) {
      segmentTimeline.add(SegmentTimelineElement(t, elementDuration));
      t += elementDuration;
    }
    return t;
  }

  UrlTemplate? _parseUrlTemplate(
      XmlElement el, String name, UrlTemplate? defaultValue) {
    final value = el.getAttribute(name);
    if (value != null) return UrlTemplate.compile(value);
    return defaultValue;
  }

  RangedUri _parseInitialization(XmlElement el) =>
      _parseRangedUrl(el, 'sourceURL', 'range');

  RangedUri _parseSegmentUrl(XmlElement el) =>
      _parseRangedUrl(el, 'media', 'mediaRange');

  RangedUri _parseRangedUrl(
      XmlElement el, String urlAttribute, String rangeAttribute) {
    final urlText = el.getAttribute(urlAttribute);
    var rangeStart = 0;
    var rangeLength = C.lengthUnset;
    final rangeText = el.getAttribute(rangeAttribute);
    if (rangeText != null) {
      final parts = rangeText.split('-');
      rangeStart = int.parse(parts[0]);
      if (parts.length == 2) {
        rangeLength = int.parse(parts[1]) - rangeStart + 1;
      }
    }
    return RangedUri(urlText, rangeStart, rangeLength);
  }

  int _parseLastSegmentNumberSupplementalProperty(
      List<Descriptor> supplementalProperties) {
    for (final d in supplementalProperties) {
      if (d.schemeIdUri.toLowerCase() ==
          'http://dashif.org/guidelines/last-segment-number') {
        return int.parse(d.value!);
      }
    }
    return C.indexUnset;
  }

  // ---------------------------------------------------------------------------
  // Descriptors and small attribute helpers
  // ---------------------------------------------------------------------------

  Descriptor _parseDescriptor(XmlElement el) => Descriptor(
        el.getAttribute('schemeIdUri') ?? '',
        el.getAttribute('value'),
        el.getAttribute('id'),
      );

  // Extracts the cenc:default_KID (hex, no dashes) from a ContentProtection
  // element, or null. Used only as a hint for the scheduler.
  String? _parseDefaultKid(XmlElement el) {
    for (final attr in el.attributes) {
      if (attr.name.local == 'default_KID') {
        return attr.value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
      }
    }
    return null;
  }

  int _parseContentType(XmlElement el) {
    final contentType = el.getAttribute('contentType');
    if (contentType != null && contentType.isNotEmpty) {
      switch (contentType) {
        case 'video':
          return C.trackTypeVideo;
        case 'audio':
          return C.trackTypeAudio;
        case 'text':
          return C.trackTypeText;
        default:
          return C.trackTypeUnknown;
      }
    }
    return MimeTypes.trackType(el.getAttribute('mimeType'));
  }

  int _trackTypeForFormat(Format format) =>
      MimeTypes.trackType(format.sampleMimeType);

  int _checkContentTypeConsistency(int firstType, int secondType) {
    if (firstType == C.trackTypeUnknown) return secondType;
    if (secondType == C.trackTypeUnknown) return firstType;
    return firstType;
  }

  String? _checkLanguageConsistency(String? first, String? second) =>
      first ?? second;

  int _parseAudioChannelConfiguration(XmlElement el) {
    final value = el.getAttribute('value');
    return value == null ? C.rateUnset : (int.tryParse(value) ?? C.rateUnset);
  }

  double _parseFrameRate(XmlElement el, double defaultValue) {
    final frameRateAttribute = el.getAttribute('frameRate');
    if (frameRateAttribute == null) return defaultValue;
    final parts = frameRateAttribute.split('/');
    if (parts.length == 2) {
      final num = double.tryParse(parts[0]);
      final den = double.tryParse(parts[1]);
      if (num != null && den != null && den != 0) return num / den;
      return defaultValue;
    }
    return double.tryParse(frameRateAttribute) ?? defaultValue;
  }

  int _parseInt(XmlElement el, String name, int defaultValue) {
    final value = el.getAttribute(name);
    return value == null ? defaultValue : (int.tryParse(value) ?? defaultValue);
  }

  int _parseLong(XmlElement el, String name, int defaultValue) =>
      _parseInt(el, name, defaultValue);

  int _parseDuration(XmlElement el, String name, int defaultValue) {
    final value = el.getAttribute(name);
    if (value == null) return defaultValue;
    return _parseXsDuration(value);
  }

  static final RegExp _durationPattern = RegExp(
      r'^(-)?P(([0-9]*)Y)?(([0-9]*)M)?(([0-9]*)D)?'
      r'(T(([0-9]*)H)?(([0-9]*)M)?(([0-9.]*)S)?)?$');

  int _parseXsDuration(String value) {
    final m = _durationPattern.firstMatch(value);
    if (m == null) return C.timeUnset;
    final negative = m.group(1) != null;
    var durationSeconds = 0.0;
    durationSeconds += _toDouble(m.group(3)) * 60 * 60 * 24 * 365;
    durationSeconds += _toDouble(m.group(5)) * 60 * 60 * 24 * 30;
    durationSeconds += _toDouble(m.group(7)) * 60 * 60 * 24;
    durationSeconds += _toDouble(m.group(10)) * 60 * 60;
    durationSeconds += _toDouble(m.group(12)) * 60;
    durationSeconds += _toDouble(m.group(14));
    final ms = (durationSeconds * 1000).round();
    return negative ? -ms : ms;
  }

  double _toDouble(String? value) =>
      (value == null || value.isEmpty) ? 0 : (double.tryParse(value) ?? 0);

  int _parseDateTime(XmlElement el, String name, int defaultValue) {
    final value = el.getAttribute(name);
    if (value == null) return defaultValue;
    final parsed = DateTime.tryParse(value);
    return parsed == null ? defaultValue : parsed.toUtc().millisecondsSinceEpoch;
  }

  XmlElement? _firstChild(XmlElement el, String name) {
    for (final c in el.childElements) {
      if (c.name.local == name) return c;
    }
    return null;
  }
}

