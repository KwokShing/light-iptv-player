// ExoPlayer-style DASH scheduler that drives the whole pipeline itself and
// feeds libmpv one already-muxed, already-decrypted progressive fMP4 stream.
//
// This is the "exo_driven" architecture: unlike the old proxy (which rewrote
// the MPD and let mpv's ffmpeg request segments), here WE own the download
// schedule exactly like ExoPlayer's DefaultDashChunkSource — parse the MPD into
// a DashManifest tree, pick a video + audio Representation, walk segment
// numbers via DashSegmentIndex, download init + media segments, decrypt CENC
// (`cenc.dart`), mux video+audio into a single fMP4 (`fmp4_muxer.dart`), and
// stream the result to mpv over one chunked HTTP response at `/stream.mp4`.
//
// Selection policy: the highest-bitrate video Representation (best quality —
// multi-segment parallel downloading now sustains well above real-time, so the
// pipeline can keep up with the 1080p rendition) plus the first audio
// Representation.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

import 'dash_c.dart';
import 'dash_manifest.dart';
import 'dash_manifest_parser.dart';
import 'dash_segment_index.dart';
import 'mp4/boxes.dart';
import 'mp4/cenc.dart';
import 'mp4/fmp4_muxer.dart';
import '../services/user_agent_service.dart';
import 'representation.dart';

/// A text cue extracted from an `stpp` (TTML-in-MP4) DASH subtitle fragment.
/// Times are rebased to the local progressive stream handed to libmpv.
class DashSubtitleCue {
  const DashSubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;
}

/// A selected track: its representation plus the resolved base URL used to
/// resolve its segment URIs.
class _SelectedTrack {
  _SelectedTrack(this.representation, this.baseUrl, this.index, this.kind);

  final Representation representation;
  final String baseUrl;
  final DashSegmentIndex index;
  final String kind; // 'video' or 'audio', for perf logging

  TrackCrypto? crypto; // discovered from the init segment
}

class _ManifestFetchException implements Exception {
  const _ManifestFetchException(this.message, {this.retryAfter});

  final String message;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

class DashStreamServer {
  HttpServer? _server;
  // A tuned HttpClient (not package:http's default) so the many small segment
  // requests reuse keep-alive connections instead of re-doing TCP+TLS each
  // time. Per the perf logs, per-segment download latency — not decryption —
  // was the bottleneck, and that is dominated by connection setup on a CDN.
  http.Client? _client;

  static http.Client _buildClient() {
    final io = HttpClient()
      // Enough connections for _prefetchDepth whole-segment downloads plus the
      // audio track and init requests, with keep-alive reuse.
      ..maxConnectionsPerHost = 16
      ..idleTimeout = const Duration(seconds: 30)
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = true;
    return IOClient(io);
  }

  String _mpdUrl = '';
  String _resolvedMpdUrl = '';
  Map<String, String> _keys = {};
  // Playlist ClearKey entries are IPTV channels. Some origins publish short
  // static MPD snapshots instead of declaring type="dynamic"; keep refreshing
  // those snapshots at the edge rather than ending the local HTTP response.
  bool _followLiveEdge = false;

  // Per-session tfdt origins (normalised trackId -> first decode time), used to
  // rebase the output timeline to 0. Reset on each start().
  final Map<int, int> _tfdtOrigins = {};

  // Guards against overlapping streaming sessions when mpv reconnects.
  int _sessionSeq = 0;

  final StreamController<List<DashSubtitleCue>> _subtitleCueController =
      StreamController<List<DashSubtitleCue>>.broadcast();
  Stream<List<DashSubtitleCue>> get subtitleCues =>
      _subtitleCueController.stream;

  String? _ttmlSubtitleLabel;
  String? get ttmlSubtitleLabel => _ttmlSubtitleLabel;

  // Preserve the tuned Android identity by default while allowing the global
  // setting to override it for every manifest and segment request.
  Map<String, String> get _originHeaders => {
    'User-Agent': UserAgentService.resolve(
      'Dalvik/2.1.0 (Linux; U; Android 11; MI 6X Build/RQ3A.211001.001) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.45 '
      'Mobile Safari/537.36',
    ),
    'Connection': 'keep-alive',
  };

  bool get isRunning => _server != null;

  String get _base => 'http://127.0.0.1:${_server?.port ?? 0}';

  /// Starts the server for [mpdUrl] with ClearKey [keys] (kidHex -> keyHex).
  /// When [followLiveEdge] is true, a short static MPD is treated as a rolling
  /// live snapshot and refreshed instead of closing the output at its edge.
  /// Returns the local URL to hand to mpv.
  Future<String> start(
    String mpdUrl,
    Map<String, String> keys, {
    bool followLiveEdge = false,
  }) async {
    await stop();
    _client = _buildClient();
    _mpdUrl = mpdUrl;
    _resolvedMpdUrl = '';
    _followLiveEdge = followLiveEdge;
    _tfdtOrigins.clear();
    _renditionsLogged = false;
    _keys = {
      for (final e in keys.entries)
        e.key.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase(): e.value
            .replaceAll(RegExp(r'[^0-9a-fA-F]'), '')
            .toLowerCase(),
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (Object e) => debugPrint('dash: $e'));
    return '$_base/stream.mp4';
  }

  Future<void> stop() async {
    _sessionSeq++;
    _ttmlSubtitleLabel = null;
    if (!_subtitleCueController.isClosed) {
      _subtitleCueController.add(const <DashSubtitleCue>[]);
    }
    final client = _client;
    _client = null;
    client?.close();
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
    _mpdUrl = '';
    _resolvedMpdUrl = '';
    _keys = {};
    _tfdtOrigins.clear();
  }

  void dispose() {
    unawaited(stop());
    unawaited(_subtitleCueController.close());
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path != '/stream.mp4') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final session = ++_sessionSeq;
    try {
      await _serveStream(req, session);
    } catch (error, st) {
      debugPrint('dash: stream error: $error\n$st');
    }
    try {
      await req.response.close();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Streaming loop
  // ---------------------------------------------------------------------------

  // Prefetch pipeline depth: how many *whole* segments download concurrently
  // ahead of the one being written to mpv. Since this origin has no Range
  // support, each segment is one single-connection download, so this depth is
  // the only lever for aggregating bandwidth — several segments in flight at
  // once. Start moderate; tune against the CDN's concurrency tolerance.
  static const int _prefetchDepth = 3;

  // How far behind the live edge to start, in segments. Our multi-segment
  // parallel download is much faster than real-time, so it quickly catches up
  // to the edge; starting well behind establishes a permanent latency buffer
  // (we then consume at 1x while the edge also advances at 1x, holding the
  // gap). Each segment is several seconds, so this trades live latency for
  // stall-free playback.
  static const int _liveEdgeBackoff = 20;

  // Keep this bounded: each queued fragment has also existed as downloaded,
  // decrypted and muxed byte arrays, so a 128 MiB queue can produce a much
  // larger transient working set.
  static const int _maxBufferedBytes = 32 * 1024 * 1024;

  Future<void> _serveStream(HttpRequest req, int session) async {
    final initial = await _fetchManifest();
    if (initial == null) {
      req.response.statusCode = HttpStatus.badGateway;
      return;
    }
    var manifest = initial;

    final video = _selectVideo(manifest);
    final audio = _selectAudio(manifest);
    final subtitle = _selectSubtitle(manifest);
    _ttmlSubtitleLabel = subtitle != null && _isTtmlSubtitle(subtitle)
        ? subtitle.representation.format.id
        : null;
    _renditionsLogged = true;
    if (video == null) {
      debugPrint('dash: no video representation found');
      req.response.statusCode = HttpStatus.badGateway;
      return;
    }
    debugPrint(
      'dash: selected video=${video.representation.format} '
      'audio=${audio?.representation.format} '
      'subtitle=${subtitle?.representation.format}',
    );

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType('video', 'mp4');
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
    req.response.bufferOutput = false;

    // 1) init segments (fetched in parallel) -> merged init.
    final inits = await Future.wait<Uint8List?>([
      _loadInit(video),
      if (audio != null) _loadInit(audio),
      if (subtitle != null) _loadInit(subtitle),
    ]);
    final videoInitRaw = inits[0];
    var nextInit = 1;
    final audioInitRaw = audio != null ? inits[nextInit++] : null;
    final subtitleInitRaw = subtitle != null ? inits[nextInit] : null;
    if (videoInitRaw == null) {
      debugPrint('dash: failed to load video init');
      return;
    }
    // TTML is parsed below and rendered by Flutter. Do not expose its stpp
    // track to libmpv: the bundled libavcodec has no TTML subtitle converter,
    // so including it only causes decoder errors. WebVTT remains native.
    final nativeSubtitleInit = subtitle != null && _isTtmlSubtitle(subtitle)
        ? null
        : subtitleInitRaw;
    final mergedInit = muxInit(videoInitRaw, audioInitRaw, nativeSubtitleInit);
    if (session != _sessionSeq) return;
    req.response.add(mergedInit);
    await req.response.flush();

    // 2) media segment loop, decoupled into a producer and a consumer so that
    // downloading/decrypting/muxing keeps running ahead even while mpv is only
    // slowly draining the HTTP response. Fragments are buffered (up to
    // [_maxBufferedBytes]) between the two; the producer pauses when the buffer
    // is full (natural backpressure) and resumes as the consumer drains it.
    const periodIndex = 0;
    var periodDurationUs = manifest.getPeriodDurationUs(periodIndex);
    final nowUs = DateTime.now().toUtc().millisecondsSinceEpoch * 1000;

    var segmentNum = _initialSegmentNum(
      manifest,
      video,
      periodDurationUs,
      nowUs,
    );
    final followingLiveEdge = _isLiveEdge(manifest, video, periodDurationUs);

    var videoTrack = video;
    var audioTrack = audio;
    var subtitleTrack = subtitleInitRaw == null ? null : subtitle;
    int? subtitleTimelineOriginUs;
    if (subtitleTrack != null) {
      try {
        final videoStartUs = video.index.getTimeUs(segmentNum);
        final firstSubtitleSegment = _segmentCoveringTime(
          subtitleTrack.index,
          videoStartUs,
          periodDurationUs,
        );
        if (firstSubtitleSegment != null) {
          subtitleTimelineOriginUs = subtitleTrack.index.getTimeUs(
            firstSubtitleSegment,
          );
        }
      } catch (error) {
        debugPrint('dash: subtitle timeline origin failed: $error');
      }
    }

    // Ready-to-send fragments waiting to be written to mpv, and how many bytes
    // they hold. The producer appends; the consumer removes.
    final buffered = <Uint8List>[];
    var bufferedBytes = 0;
    var producerDone = false;
    // A subtitle segment can span several video segments. Schedule each one
    // only once or its decode time jumps backwards and libmpv drops the cues.
    final scheduledSubtitleSegments = <String>{};
    // Completer the consumer awaits when the buffer is empty (more data coming).
    Completer<void>? dataReady;
    // Completer the producer awaits when the buffer is full (wait for drain).
    Completer<void>? spaceReady;

    void signalData() {
      final c = dataReady;
      if (c != null && !c.isCompleted) c.complete();
      dataReady = null;
    }

    void signalSpace() {
      final c = spaceReady;
      if (c != null && !c.isCompleted) c.complete();
      spaceReady = null;
    }

    // Producer: download -> decrypt -> mux -> normalise -> enqueue, forever
    // (or until the session ends / VOD finishes).
    Future<void> produce() async {
      final pipeline = <int, Future<Uint8List?>>{};

      void fill(int upTo) {
        var n = segmentNum + pipeline.length;
        while (pipeline.length < _prefetchDepth && n <= upTo) {
          final seg = n;
          pipeline[seg] = _loadMuxedFragment(
            videoTrack,
            audioTrack,
            subtitleTrack,
            seg,
            seg,
            periodDurationUs,
            scheduledSubtitleSegments,
            session,
            subtitleTimelineOriginUs,
          );
          n++;
        }
      }

      // Consecutive times the wanted segment wasn't available yet (used to
      // wait at the live edge instead of trusting the manifest's segment count,
      // whose clock-based math on this source doesn't advance reliably).
      var edgeMisses = 0;

      while (session == _sessionSeq) {
        // Backpressure: if the buffer is full, wait for the consumer to drain.
        if (bufferedBytes >= _maxBufferedBytes) {
          spaceReady ??= Completer<void>();
          await spaceReady!.future;
          continue;
        }

        // Prefetch several whole segments ahead. We deliberately do NOT gate on
        // the manifest's computed last-available segment for live streams: on
        // this origin that number is derived from a fixed period duration and
        // never advances, so it would wedge us one segment short of the edge.
        // Instead we just try to fetch ahead and let a 404 tell us we've hit
        // the real edge.
        final ceiling = followingLiveEdge
            ? segmentNum + _prefetchDepth
            : () {
                final last = _lastAvailableSegmentNum(
                  manifest,
                  videoTrack,
                  periodDurationUs,
                );
                return last == DashSegmentIndex.indexUnbounded
                    ? segmentNum + _prefetchDepth
                    : last;
              }();

        if (!followingLiveEdge && segmentNum > ceiling && pipeline.isEmpty) {
          break; // Genuine VOD finished.
        }

        fill(ceiling);

        final pending = pipeline.remove(segmentNum);
        if (pending == null) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }

        final muxed = await pending;
        if (session != _sessionSeq) return;

        if (muxed == null) {
          if (followingLiveEdge) {
            // Segment not published yet: we've caught the live edge. Reload the
            // manifest FROM THE ORIGIN (the pinned CDN .mpd is a snapshot whose
            // timeline never grows; the origin endpoint yields a fresh session
            // with newer segments — like reloading the channel). Then continue
            // from wherever the refreshed timeline now reaches.
            edgeMisses++;
            pipeline.clear();
            scheduledSubtitleSegments.clear();
            await Future<void>.delayed(
              Duration(milliseconds: edgeMisses <= 1 ? 500 : 1500),
            );
            if (session != _sessionSeq) return;
            final refreshed = await _fetchManifest(fromOrigin: true);
            if (refreshed != null) {
              manifest = refreshed;
              periodDurationUs = manifest.getPeriodDurationUs(periodIndex);
              final newVideo = _selectVideo(manifest);
              final newAudio = _selectAudio(manifest);
              final newSubtitle = _selectSubtitle(manifest);
              if (newVideo != null) {
                newVideo.crypto = videoTrack.crypto;
                videoTrack = newVideo;
              }
              final currentAudio = audioTrack;
              if (newAudio != null && currentAudio != null) {
                newAudio.crypto = currentAudio.crypto;
                audioTrack = newAudio;
              }
              final currentSubtitle = subtitleTrack;
              if (newSubtitle != null && currentSubtitle != null) {
                newSubtitle.crypto = currentSubtitle.crypto;
                subtitleTrack = newSubtitle;
              }
              // If the segment we want still isn't in the refreshed timeline,
              // jump to the fresh manifest's live edge and resume there. This
              // is the "reload the pipeline" behaviour: rather than waiting
              // forever for a number the new session may never use, re-anchor
              // to the new edge.
              final newLast = _lastAvailableSegmentNum(
                manifest,
                videoTrack,
                periodDurationUs,
              );
              if (newLast != DashSegmentIndex.indexUnbounded &&
                  segmentNum > newLast) {
                if (edgeMisses >= 3) {
                  final resumeAt = newLast - _liveEdgeBackoff;
                  final firstSeg = videoTrack.index.getFirstSegmentNum();
                  segmentNum = resumeAt < firstSeg ? firstSeg : resumeAt;
                  edgeMisses = 0;
                  debugPrint(
                    'dash: live-edge re-anchor -> seg=$segmentNum '
                    '(newLast=$newLast)',
                  );
                }
              } else {
                edgeMisses = 0; // segment is now available; proceed.
              }
            }
            continue;
          }
          // Static/VOD: a missing segment is a gap; skip it.
          segmentNum++;
          continue;
        }

        edgeMisses = 0;
        segmentNum++;

        final normalised = normalizeFragmentTimestamps(muxed, _tfdtOrigins);
        buffered.add(normalised);
        bufferedBytes += normalised.length;
        signalData();
      }
    }

    // Consumer: drain the buffer to mpv, flushing (mpv's own backpressure only
    // gates this task, not the producer above).
    Future<void> consume() async {
      try {
        while (session == _sessionSeq) {
          if (buffered.isEmpty) {
            if (producerDone) break;
            dataReady ??= Completer<void>();
            await dataReady!.future;
            continue;
          }
          final chunk = buffered.removeAt(0);
          bufferedBytes -= chunk.length;
          signalSpace();
          try {
            req.response.add(chunk);
            await req.response.flush();
          } on SocketException {
            return; // mpv closed the connection.
          } catch (_) {
            return;
          }
        }
      } finally {
        // If mpv disconnects while the producer is blocked on a full queue,
        // invalidate this session and wake it. Without this, the producer's
        // Future and its entire fragment buffer remain reachable forever.
        if (session == _sessionSeq) _sessionSeq++;
        signalSpace();
        signalData();
      }
    }

    final producer = produce().whenComplete(() {
      producerDone = true;
      signalData(); // wake the consumer so it can finish.
    });
    await Future.wait([producer, consume()]);
  }

  // Downloads video, optional audio and optional fMP4 subtitle segments,
  // decrypts them and muxes them into one fragment. Subtitle segment numbers
  // are resolved from the video presentation time because DASH adaptation
  // sets may use different start numbers or segment durations.
  bool _isSegmentDefined(
    DashSegmentIndex index,
    int segmentNum,
    int periodDurationUs,
  ) {
    final first = index.getFirstSegmentNum();
    final count = index.getSegmentCount(periodDurationUs);
    return segmentNum >= first &&
        (count == DashSegmentIndex.indexUnbounded ||
            segmentNum < first + count);
  }

  int? _segmentCoveringTime(
    DashSegmentIndex index,
    int timeUs,
    int periodDurationUs,
  ) {
    final count = index.getSegmentCount(periodDurationUs);
    if (count == 0) return null;
    final candidate = index.getSegmentNum(timeUs, periodDurationUs);
    if (!_isSegmentDefined(index, candidate, periodDurationUs)) return null;
    final startUs = index.getTimeUs(candidate);
    final durationUs = index.getDurationUs(candidate, periodDurationUs);
    return timeUs >= startUs && timeUs < startUs + durationUs
        ? candidate
        : null;
  }

  Future<Uint8List?> _loadMuxedFragment(
    _SelectedTrack video,
    _SelectedTrack? audio,
    _SelectedTrack? subtitle,
    int segmentNum,
    int sequence,
    int periodDurationUs,
    Set<String> scheduledSubtitleSegments,
    int session,
    int? subtitleTimelineOriginUs,
  ) async {
    // A refreshed live manifest can temporarily end before the old playback
    // cursor. Let the existing edge refresh/re-anchor path handle that miss
    // instead of indexing the new timeline with an out-of-range segment.
    if (!_isSegmentDefined(video.index, segmentNum, periodDurationUs)) {
      return null;
    }

    int? subtitleSegmentNum;
    String? subtitleSegmentKey;
    if (subtitle != null) {
      try {
        final presentationTimeUs = video.index.getTimeUs(segmentNum);
        final candidate = _segmentCoveringTime(
          subtitle.index,
          presentationTimeUs,
          periodDurationUs,
        );
        if (candidate != null) {
          final segmentStartUs = subtitle.index.getTimeUs(candidate);
          final key = '${subtitle.representation.format.id}|$segmentStartUs';
          if (scheduledSubtitleSegments.add(key)) {
            subtitleSegmentNum = candidate;
            subtitleSegmentKey = key;
          }
        }
      } catch (error) {
        debugPrint('dash: subtitle segment lookup failed: $error');
      }
    }

    final results = await Future.wait<Uint8List?>([
      _loadSegment(video, segmentNum),
      if (audio != null) _loadSegment(audio, segmentNum),
      if (subtitle != null && subtitleSegmentNum != null)
        _loadSegment(subtitle, subtitleSegmentNum),
    ]);
    final videoSeg = results[0];
    var nextResult = 1;
    final audioSeg = audio != null ? results[nextResult++] : null;
    final subtitleSeg = subtitle != null && subtitleSegmentNum != null
        ? results[nextResult]
        : null;
    if (videoSeg == null ||
        (subtitleSegmentKey != null && subtitleSeg == null)) {
      if (subtitleSegmentKey != null) {
        scheduledSubtitleSegments.remove(subtitleSegmentKey);
      }
      if (videoSeg == null) return null;
    }
    try {
      final isTtml = subtitle != null && _isTtmlSubtitle(subtitle);
      // Keep downloading TTML for Dart parsing, but omit it from the fMP4
      // consumed by libmpv. This prevents unsupported native TTML decoding.
      final muxed = muxFragment(
        videoSeg,
        audioSeg,
        sequence,
        isTtml ? null : subtitleSeg,
      );
      if (isTtml &&
          subtitleSeg != null &&
          subtitleSegmentNum != null &&
          subtitleTimelineOriginUs != null &&
          session == _sessionSeq) {
        final segmentStartUs = subtitle.index.getTimeUs(subtitleSegmentNum);
        final segmentDurationUs = subtitle.index.getDurationUs(
          subtitleSegmentNum,
          periodDurationUs,
        );
        final cues = _parseStppCues(
          subtitleSeg,
          segmentStartUs: segmentStartUs,
          segmentDurationUs: segmentDurationUs,
          timelineOriginUs: subtitleTimelineOriginUs,
        );
        if (cues.isNotEmpty && !_subtitleCueController.isClosed) {
          debugPrint(
            'dash: parsed ${cues.length} TTML cues from subtitle segment '
            '$subtitleSegmentNum',
          );
          _subtitleCueController.add(cues);
        }
      }
      return muxed;
    } catch (error) {
      if (subtitleSegmentKey != null) {
        scheduledSubtitleSegments.remove(subtitleSegmentKey);
      }
      debugPrint('dash: mux failed at seg $segmentNum: $error');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Track selection
  // ---------------------------------------------------------------------------

  _SelectedTrack? _selectVideo(DashManifest manifest) =>
      _selectTrack(manifest, C.trackTypeVideo, lowestBitrate: false);

  _SelectedTrack? _selectAudio(DashManifest manifest) =>
      _selectTrack(manifest, C.trackTypeAudio, lowestBitrate: false);

  _SelectedTrack? _selectSubtitle(DashManifest manifest) => _selectTrack(
    manifest,
    C.trackTypeText,
    lowestBitrate: false,
    representationFilter: _isMuxableSubtitle,
  );

  bool _isTtmlSubtitle(_SelectedTrack track) =>
      track.representation.format.codecs
          ?.toLowerCase()
          .split(',')
          .any((codec) => codec.trim().startsWith('stpp')) ??
      false;

  bool _isMuxableSubtitle(Representation representation) {
    final mime = representation.format.containerMimeType?.toLowerCase();
    if (mime == null || !mime.endsWith('/mp4')) return false;
    final codecs = representation.format.codecs?.toLowerCase().split(',');
    if (codecs == null || codecs.isEmpty) return true;
    return codecs.any((codec) {
      final value = codec.trim();
      return value.startsWith('wvtt') || value.startsWith('stpp');
    });
  }

  _SelectedTrack? _selectTrack(
    DashManifest manifest,
    int trackType, {
    required bool lowestBitrate,
    bool Function(Representation representation)? representationFilter,
  }) {
    if (manifest.periodCount == 0) return null;
    final period = manifest.getPeriod(0);
    for (final as_ in period.adaptationSets) {
      if (as_.type != trackType) continue;
      final reps = as_.representations
          .where(
            (representation) =>
                representationFilter?.call(representation) ?? true,
          )
          .toList(growable: false);
      if (reps.isEmpty) continue;
      final kindName = switch (trackType) {
        C.trackTypeVideo => 'video',
        C.trackTypeAudio => 'audio',
        C.trackTypeText => 'subtitle',
        _ => 'unknown',
      };
      if (!_renditionsLogged) {
        final renditions = reps
            .map(
              (r) =>
                  '${r.format.bitrate}bps ${r.format.width}x${r.format.height}',
            )
            .join(', ');
        debugPrint('dash: available $kindName renditions: $renditions');
      }
      var chosen = reps.first;
      for (final r in reps) {
        final rBitrate = r.format.bitrate;
        final cBitrate = chosen.format.bitrate;
        if (lowestBitrate ? rBitrate < cBitrate : rBitrate > cBitrate) {
          chosen = r;
        }
      }
      final index = chosen.getIndex();
      if (index == null) continue;
      final baseUrl = chosen.baseUrls.first.url;
      return _SelectedTrack(chosen, baseUrl, index, kindName);
    }
    return null;
  }

  // Set true after the first selection so the (verbose) rendition list is only
  // logged once per session, not on every live-refresh re-selection.
  bool _renditionsLogged = false;

  // ---------------------------------------------------------------------------
  // Segment numbering (mirrors DefaultDashChunkSource's use of DashSegmentIndex)
  // ---------------------------------------------------------------------------

  int _initialSegmentNum(
    DashManifest manifest,
    _SelectedTrack track,
    int periodDurationUs,
    int nowUs,
  ) {
    final index = track.index;

    if (manifest.dynamic) {
      // Live: start a few segments behind the live edge.
      final firstAvailable = index.getFirstAvailableSegmentNum(
        periodDurationUs,
        nowUs,
      );
      final available = index.getAvailableSegmentCount(periodDurationUs, nowUs);
      if (available == DashSegmentIndex.indexUnbounded || available <= 0) {
        return firstAvailable;
      }
      final lastAvailable = firstAvailable + available - 1;
      final start = lastAvailable - _liveEdgeBackoff;
      return start < firstAvailable ? firstAvailable : start;
    }

    // Static manifest. A short VOD normally plays from the start; however,
    // ClearKey IPTV origins can publish a short rolling static snapshot. The
    // caller marks those with _followLiveEdge so we start near the current edge
    // and refresh in place. Long static timelines retain the older heuristic.
    final first = index.getFirstSegmentNum();
    final count = index.getSegmentCount(periodDurationUs);
    if (count == DashSegmentIndex.indexUnbounded) {
      return first;
    }
    if (_followLiveEdge || count > _liveLikeThreshold) {
      final lastAvailable = first + count - 1;
      final start = lastAvailable - _liveEdgeBackoff;
      return start < first ? first : start;
    }
    return first;
  }

  // A static manifest whose timeline is this long (segments) is treated as a
  // growing live feed rather than a finite VOD when no explicit caller hint is
  // available.
  static const int _liveLikeThreshold = 20; // ~40-60s of 2-3s segments

  // Whether playback should follow a live edge (refresh the manifest for new
  // segments at the end) rather than stopping when the current window is
  // exhausted.
  bool _isLiveEdge(
    DashManifest manifest,
    _SelectedTrack track,
    int periodDurationUs,
  ) {
    if (manifest.dynamic || _followLiveEdge) return true;
    final count = track.index.getSegmentCount(periodDurationUs);
    if (count == DashSegmentIndex.indexUnbounded) return true;
    return count > _liveLikeThreshold;
  }

  int _lastAvailableSegmentNum(
    DashManifest manifest,
    _SelectedTrack track,
    int periodDurationUs,
  ) {
    final index = track.index;
    final nowUsLive = DateTime.now().toUtc().millisecondsSinceEpoch * 1000;
    final count = index.getSegmentCount(periodDurationUs);
    if (count == DashSegmentIndex.indexUnbounded) {
      final firstAvailable = index.getFirstAvailableSegmentNum(
        periodDurationUs,
        nowUsLive,
      );
      final available = index.getAvailableSegmentCount(
        periodDurationUs,
        nowUsLive,
      );
      if (available <= 0) return DashSegmentIndex.indexUnbounded;
      return firstAvailable + available - 1;
    }
    return index.getFirstSegmentNum() + count - 1;
  }

  // ---------------------------------------------------------------------------
  // Segment loading + decryption
  // ---------------------------------------------------------------------------

  Future<Uint8List?> _loadInit(_SelectedTrack track) async {
    final initUri = track.representation.getInitializationUri();
    if (initUri == null) return null;
    final url = initUri.resolveUriString(track.baseUrl);
    final raw = await _get(url);
    if (raw == null) return null;
    // Sanitise the init: strip protection boxes, recover codec, learn crypto.
    final boxes = parseBoxes(raw, 0, raw.length);
    final crypto = sanitizeInit(boxes);
    if (crypto != null) {
      crypto.key = _resolveKey(crypto.kid);
      track.crypto = crypto;
    }
    return serializeBoxes(boxes);
  }

  Future<Uint8List?> _loadSegment(_SelectedTrack track, int segmentNum) async {
    // For SegmentTimeline-based indexes the URL for a segment beyond the
    // current timeline can't be built (it isn't listed yet). Treat that as
    // "not published yet" so the live-edge logic waits for a manifest refresh
    // instead of crashing on an out-of-range access.
    final String url;
    try {
      final segUri = track.index.getSegmentUrl(segmentNum);
      url = segUri.resolveUriString(track.baseUrl);
    } catch (_) {
      return null;
    }
    final raw = await _get(url);
    if (raw == null) return null;
    final crypto = track.crypto;
    if (crypto?.key == null) {
      return raw; // clear stream, pass through.
    }
    try {
      final boxes = parseBoxes(raw, 0, raw.length);
      return decryptFragment(boxes, crypto!);
    } catch (error) {
      debugPrint('dash: decrypt failed for $url: $error');
      return raw;
    }
  }

  Uint8List? _resolveKey(Uint8List kid) {
    final kidHex = bytesToHex(kid);
    final keyHex =
        _keys[kidHex] ?? (_keys.length == 1 ? _keys.values.first : null);
    return keyHex == null ? null : hexToBytes(keyHex);
  }

  // ---------------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------------

  // Downloads a whole segment on a single connection. This origin does not
  // support HTTP Range (it answers ranged requests with 200 + the full body),
  // so per-segment range parallelism is impossible; throughput is aggregated
  // instead by prefetching several *whole* segments concurrently (see the
  // pipeline in _serveStream, sized by _prefetchDepth).
  Future<Uint8List?> _get(String url) async {
    final client = _client;
    if (client == null) return null;
    try {
      final res = await client.get(Uri.parse(url), headers: _originHeaders);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('dash: HTTP ${res.statusCode} for $url');
        return null;
      }
      return Uint8List.fromList(res.bodyBytes);
    } catch (error) {
      debugPrint('dash: GET failed $url: $error');
      return null;
    }
  }

  // Fetches and parses the manifest, retrying transient failures. When
  // [fromOrigin] is true, re-resolves from the original entry URL (e.g. a
  // `…php?id=` endpoint that 302s to a fresh CDN .mpd) instead of re-hitting the
  // pinned .mpd. The pinned .mpd is often a one-shot snapshot whose
  // SegmentTimeline never grows, so at the live edge we must go back to the
  // origin to obtain newer segments — effectively reloading the stream the way
  // a channel switch would.
  //
  // The origin can intermittently return a rate-limit/error page with HTTP 200,
  // or an upstream HTTP error. Reject those responses before XML parsing so the
  // log identifies the actual response, then retry with bounded backoff.
  Future<DashManifest?> _fetchManifest({bool fromOrigin = false}) async {
    for (var attempt = 0; attempt < _manifestAttempts; attempt++) {
      // After a first failure, ignore the pinned .mpd and go back to origin.
      final useOrigin = fromOrigin || attempt > 0;
      final source = (!useOrigin && _resolvedMpdUrl.isNotEmpty)
          ? _resolvedMpdUrl
          : _mpdUrl;
      try {
        final fetched = await _fetchFollowingRedirects(source);
        final body = utf8.decode(fetched.$2, allowMalformed: true);
        final mpdStart = body.indexOf('<MPD');
        final mpdEnd = mpdStart < 0 ? -1 : body.indexOf('</MPD>', mpdStart);
        if (mpdStart < 0 || mpdEnd < 0) {
          throw FormatException(
            'Response is not a complete DASH MPD '
            '(content-type: ${fetched.$3 ?? 'unknown'}, '
            'body: ${_manifestBodyPreview(fetched.$2)})',
          );
        }
        final manifest = const DashManifestParser().parse(fetched.$1, body);
        _resolvedMpdUrl = fetched.$1;
        return manifest;
      } catch (error) {
        debugPrint(
          'dash: manifest fetch/parse failed '
          '(attempt ${attempt + 1}/$_manifestAttempts): $error',
        );
        if (attempt + 1 < _manifestAttempts) {
          await Future<void>.delayed(_manifestRetryDelay(error, attempt));
        }
      }
    }
    return null;
  }

  static const int _manifestAttempts = 4;

  static Duration _manifestRetryDelay(Object error, int attempt) {
    final fallback = Duration(milliseconds: 600 * (1 << attempt));
    if (error is! _ManifestFetchException || error.retryAfter == null) {
      return fallback;
    }
    final requestedMs = error.retryAfter!.inMilliseconds;
    if (requestedMs <= fallback.inMilliseconds) return fallback;
    return Duration(milliseconds: requestedMs.clamp(0, 10000));
  }

  static Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: seconds);
    try {
      final delay = HttpDate.parse(value).difference(DateTime.now().toUtc());
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {
      return null;
    }
  }

  static String _manifestBodyPreview(Uint8List bytes) {
    final prefix = bytes.length <= 512 ? bytes : bytes.sublist(0, 512);
    final text = utf8
        .decode(prefix, allowMalformed: true)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return '<empty body>';
    return text.length <= 160 ? text : '${text.substring(0, 160)}…';
  }

  Future<(String, Uint8List, String?)> _fetchFollowingRedirects(
    String url,
  ) async {
    final client = _client;
    if (client == null) throw StateError('DASH session has stopped');
    var current = Uri.parse(url);
    for (var i = 0; i < 10; i++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(_originHeaders);
      final streamed = await client.send(request);
      final loc = streamed.headers['location'];
      if (streamed.statusCode >= 300 &&
          streamed.statusCode < 400 &&
          loc != null) {
        await streamed.stream.drain<void>();
        current = current.resolve(loc);
        continue;
      }
      final bytes = await streamed.stream.toBytes();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw _ManifestFetchException(
          'Manifest HTTP ${streamed.statusCode} '
          '(body: ${_manifestBodyPreview(bytes)})',
          retryAfter: _parseRetryAfter(streamed.headers['retry-after']),
        );
      }
      return (current.toString(), bytes, streamed.headers['content-type']);
    }
    throw Exception('Too many redirects fetching $url');
  }
}

List<DashSubtitleCue> _parseStppCues(
  Uint8List fragment, {
  required int segmentStartUs,
  required int segmentDurationUs,
  required int timelineOriginUs,
}) {
  final cues = <DashSubtitleCue>[];
  for (final sample in _fragmentSamples(fragment)) {
    final xmlSource = _extractTtmlDocument(sample);
    if (xmlSource == null) continue;
    try {
      final document = XmlDocument.parse(xmlSource);
      final root = document.rootElement;
      final frameRate =
          double.tryParse(_xmlAttribute(root, 'frameRate') ?? '') ?? 30;
      final tickRate =
          double.tryParse(_xmlAttribute(root, 'tickRate') ?? '') ?? 1;
      final paragraphs = root.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'p')
          .toList(growable: false);
      final parsedBegins = paragraphs
          .map(
            (paragraph) => _parseTtmlTime(
              _xmlAttribute(paragraph, 'begin'),
              frameRate: frameRate,
              tickRate: tickRate,
            ),
          )
          .whereType<int>()
          .toList(growable: false);
      final maxBegin = parsedBegins.isEmpty
          ? 0
          : parsedBegins.reduce((a, b) => a > b ? a : b);
      // Most stpp profiles use media-timeline times. A few encoders reset each
      // TTML document to zero; detect that only when the values are clearly far
      // behind the enclosing segment to avoid shifting legitimate early cues.
      final localDocumentTimeline =
          parsedBegins.isNotEmpty &&
          segmentStartUs - maxBegin >
              (segmentDurationUs * 2 > 5000000
                  ? segmentDurationUs * 2
                  : 5000000) &&
          maxBegin <= segmentDurationUs + 1000000;
      final rebasedSegmentStartUs = segmentStartUs - timelineOriginUs;

      for (final paragraph in paragraphs) {
        final text = _ttmlText(paragraph);
        if (text.isEmpty) continue;
        final begin = _parseTtmlTime(
          _xmlAttribute(paragraph, 'begin'),
          frameRate: frameRate,
          tickRate: tickRate,
        );
        final end = _parseTtmlTime(
          _xmlAttribute(paragraph, 'end'),
          frameRate: frameRate,
          tickRate: tickRate,
        );
        final duration = _parseTtmlTime(
          _xmlAttribute(paragraph, 'dur'),
          frameRate: frameRate,
          tickRate: tickRate,
        );

        var cueStartUs = begin == null
            ? rebasedSegmentStartUs
            : localDocumentTimeline
            ? rebasedSegmentStartUs + begin
            : begin - timelineOriginUs;
        var cueEndUs = duration != null
            ? cueStartUs + duration
            : end == null
            ? rebasedSegmentStartUs + segmentDurationUs
            : localDocumentTimeline
            ? rebasedSegmentStartUs + end
            : end - timelineOriginUs;
        if (cueStartUs < 0) cueStartUs = 0;
        if (cueEndUs <= cueStartUs) cueEndUs = cueStartUs + 2000000;
        cues.add(
          DashSubtitleCue(
            start: Duration(microseconds: cueStartUs),
            end: Duration(microseconds: cueEndUs),
            text: text,
          ),
        );
      }
    } catch (error) {
      debugPrint('dash: TTML parse failed: $error');
    }
  }
  return cues;
}

List<Uint8List> _fragmentSamples(Uint8List fragment) {
  final boxes = parseBoxes(fragment, 0, fragment.length);
  final moof = boxes.where((box) => box.type == 'moof').firstOrNull;
  final mdat = boxes.where((box) => box.type == 'mdat').firstOrNull;
  final data = mdat?.payload;
  if (moof == null || data == null) return const [];

  final sizes = <int>[];
  for (final traf in moof.children.where((box) => box.type == 'traf')) {
    final tfhd = traf.child('tfhd');
    final defaultSize = tfhd?.payload == null
        ? 0
        : tfhdDefaultSampleSize(tfhd!.payload!);
    for (final trun in traf.children.where((box) => box.type == 'trun')) {
      final payload = trun.payload;
      if (payload != null) sizes.addAll(parseTrun(payload, defaultSize).sizes);
    }
  }
  if (sizes.isEmpty || sizes.any((size) => size <= 0)) return [data];

  final samples = <Uint8List>[];
  var offset = 0;
  for (final size in sizes) {
    if (offset + size > data.length) return [data];
    samples.add(data.sublist(offset, offset + size));
    offset += size;
  }
  return samples;
}

String? _extractTtmlDocument(Uint8List sample) {
  final decoded = utf8.decode(sample, allowMalformed: true);
  final rootMatch = RegExp(
    r'<(?:([A-Za-z_][\w.-]*):)?tt(?:\s|>)',
  ).firstMatch(decoded);
  if (rootMatch == null) return null;
  final prefix = rootMatch.group(1);
  final closingTag = prefix == null ? '</tt>' : '</$prefix:tt>';
  final end = decoded.indexOf(closingTag, rootMatch.start);
  if (end < 0) return null;
  return decoded.substring(rootMatch.start, end + closingTag.length);
}

String? _xmlAttribute(XmlElement element, String localName) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value;
  }
  return null;
}

String _ttmlText(XmlElement paragraph) {
  final output = StringBuffer();

  void append(XmlNode node) {
    if (node is XmlText) {
      output.write(node.value);
      return;
    }
    if (node is! XmlElement) return;
    if (node.name.local == 'br') {
      output.write('\n');
      return;
    }
    for (final child in node.children) {
      append(child);
    }
  }

  append(paragraph);
  return output
      .toString()
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

int? _parseTtmlTime(
  String? expression, {
  required double frameRate,
  required double tickRate,
}) {
  if (expression == null) return null;
  final value = expression.trim();
  if (value.isEmpty) return null;

  final clock = RegExp(
    r'^(\d+):(\d{2}):(\d{2})(?:[\.,](\d+))?(?::(\d+)(?:\.(\d+))?)?$',
  ).firstMatch(value);
  if (clock != null) {
    final hours = int.parse(clock.group(1)!);
    final minutes = int.parse(clock.group(2)!);
    final seconds = int.parse(clock.group(3)!);
    var micros = ((hours * 60 + minutes) * 60 + seconds) * 1000000;
    final fraction = clock.group(4);
    if (fraction != null) {
      micros += (double.parse('0.$fraction') * 1000000).round();
    }
    final frames = clock.group(5);
    if (frames != null && frameRate > 0) {
      micros += (int.parse(frames) * 1000000 / frameRate).round();
      final subframes = clock.group(6);
      if (subframes != null) {
        micros += (double.parse('0.$subframes') * 1000000 / frameRate).round();
      }
    }
    return micros;
  }

  final offset = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(ms|h|m|s|f|t)$',
  ).firstMatch(value);
  if (offset == null) return null;
  final amount = double.parse(offset.group(1)!);
  final seconds = switch (offset.group(2)!) {
    'h' => amount * 3600,
    'm' => amount * 60,
    's' => amount,
    'ms' => amount / 1000,
    'f' => frameRate > 0 ? amount / frameRate : 0,
    't' => tickRate > 0 ? amount / tickRate : 0,
    _ => 0,
  };
  return (seconds * 1000000).round();
}
