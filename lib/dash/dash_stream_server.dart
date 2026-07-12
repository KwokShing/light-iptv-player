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

import 'dash_c.dart';
import 'dash_manifest.dart';
import 'dash_manifest_parser.dart';
import 'dash_segment_index.dart';
import 'mp4/boxes.dart';
import 'mp4/cenc.dart';
import 'mp4/fmp4_muxer.dart';
import 'representation.dart';

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

class DashStreamServer {
  HttpServer? _server;
  // A tuned HttpClient (not package:http's default) so the many small segment
  // requests reuse keep-alive connections instead of re-doing TCP+TLS each
  // time. Per the perf logs, per-segment download latency — not decryption —
  // was the bottleneck, and that is dominated by connection setup on a CDN.
  final http.Client _client = _buildClient();

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

  // Per-session tfdt origins (normalised trackId -> first decode time), used to
  // rebase the output timeline to 0. Reset on each start().
  final Map<int, int> _tfdtOrigins = {};

  // Guards against overlapping streaming sessions when mpv reconnects.
  int _sessionSeq = 0;

  // Many DASH/IPTV CDNs treat clients by User-Agent — several serve full speed
  // to Android players but throttle desktop UAs (the likely cause of "Android
  // plays 1080p fine, PC crawls"). Present an Android UA to match the fast path.
  static const Map<String, String> _originHeaders = {
    'User-Agent':
        'Dalvik/2.1.0 (Linux; U; Android 11; MI 6X Build/RQ3A.211001.001) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.45 '
        'Mobile Safari/537.36',
    'Connection': 'keep-alive',
  };

  bool get isRunning => _server != null;

  String get _base => 'http://127.0.0.1:${_server?.port ?? 0}';

  /// Starts the server for [mpdUrl] with ClearKey [keys] (kidHex -> keyHex).
  /// Returns the local URL to hand to mpv.
  Future<String> start(String mpdUrl, Map<String, String> keys) async {
    await stop();
    _mpdUrl = mpdUrl;
    _resolvedMpdUrl = '';
    _tfdtOrigins.clear();
    _renditionsLogged = false;
    _keys = {
      for (final e in keys.entries)
        e.key.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase():
            e.value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase(),
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (Object e) => debugPrint('dash: $e'));
    return '$_base/stream.mp4';
  }

  Future<void> stop() async {
    _sessionSeq++;
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  void dispose() {
    stop();
    _client.close();
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
  static const int _prefetchDepth = 6;

  // How far behind the live edge to start, in segments. Our multi-segment
  // parallel download is much faster than real-time, so it quickly catches up
  // to the edge; starting well behind establishes a permanent latency buffer
  // (we then consume at 1x while the edge also advances at 1x, holding the
  // gap). Each segment is several seconds, so this trades live latency for
  // stall-free playback.
  static const int _liveEdgeBackoff = 20;

  // Max bytes of muxed fragments buffered between the producer (download/decrypt
  // /mux) and the consumer (flush to mpv). The producer keeps working ahead up
  // to this cap even while mpv drains slowly, so "fetch the next segment before
  // the current finishes playing" actually happens. Large enough to hold many
  // seconds of the low-bitrate rendition and ride out slow-download outliers.
  static const int _maxBufferedBytes = 128 * 1024 * 1024;

  Future<void> _serveStream(HttpRequest req, int session) async {
    final initial = await _fetchManifest();
    if (initial == null) {
      req.response.statusCode = HttpStatus.badGateway;
      return;
    }
    var manifest = initial;

    final video = _selectVideo(manifest);
    final audio = _selectAudio(manifest);
    _renditionsLogged = true;
    if (video == null) {
      debugPrint('dash: no video representation found');
      req.response.statusCode = HttpStatus.badGateway;
      return;
    }
    debugPrint('dash: selected video=${video.representation.format} '
        'audio=${audio?.representation.format}');

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType('video', 'mp4');
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
    req.response.bufferOutput = false;

    // 1) init segments (fetched in parallel) -> merged init.
    final inits = await Future.wait<Uint8List?>([
      _loadInit(video),
      if (audio != null) _loadInit(audio),
    ]);
    final videoInitRaw = inits[0];
    final audioInitRaw = audio != null && inits.length > 1 ? inits[1] : null;
    if (videoInitRaw == null) {
      debugPrint('dash: failed to load video init');
      return;
    }
    final mergedInit = muxInit(videoInitRaw, audioInitRaw);
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

    var segmentNum = _initialSegmentNum(manifest, video, periodDurationUs, nowUs);
    final followingLiveEdge = _isLiveEdge(manifest, video, periodDurationUs);

    var videoTrack = video;
    var audioTrack = audio;

    // Ready-to-send fragments waiting to be written to mpv, and how many bytes
    // they hold. The producer appends; the consumer removes.
    final buffered = <Uint8List>[];
    var bufferedBytes = 0;
    var producerDone = false;
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
          pipeline[seg] = _loadMuxedFragment(videoTrack, audioTrack, seg, seg);
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
                    manifest, videoTrack, periodDurationUs);
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
            await Future<void>.delayed(Duration(
                milliseconds: edgeMisses <= 1 ? 500 : 1500));
            if (session != _sessionSeq) return;
            final refreshed = await _fetchManifest(fromOrigin: true);
            if (refreshed != null) {
              manifest = refreshed;
              periodDurationUs = manifest.getPeriodDurationUs(periodIndex);
              final newVideo = _selectVideo(manifest);
              final newAudio = _selectAudio(manifest);
              if (newVideo != null) {
                newVideo.crypto = videoTrack.crypto;
                videoTrack = newVideo;
              }
              final currentAudio = audioTrack;
              if (newAudio != null && currentAudio != null) {
                newAudio.crypto = currentAudio.crypto;
                audioTrack = newAudio;
              }
              // If the segment we want still isn't in the refreshed timeline,
              // jump to the fresh manifest's live edge and resume there. This
              // is the "reload the pipeline" behaviour: rather than waiting
              // forever for a number the new session may never use, re-anchor
              // to the new edge.
              final newLast = _lastAvailableSegmentNum(
                  manifest, videoTrack, periodDurationUs);
              if (newLast != DashSegmentIndex.indexUnbounded &&
                  segmentNum > newLast) {
                if (edgeMisses >= 3) {
                  final resumeAt = newLast - _liveEdgeBackoff;
                  final firstSeg = videoTrack.index.getFirstSegmentNum();
                  segmentNum = resumeAt < firstSeg ? firstSeg : resumeAt;
                  edgeMisses = 0;
                  debugPrint('dash: live-edge re-anchor -> seg=$segmentNum '
                      '(newLast=$newLast)');
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
    }

    final producer = produce().whenComplete(() {
      producerDone = true;
      signalData(); // wake the consumer so it can finish.
    });
    await Future.wait([producer, consume()]);
  }

  // Downloads a video (and optional audio) segment concurrently, decrypts both,
  // and muxes them into one fMP4 fragment stamped with [sequence]. The tiny
  // audio segment is fetched alongside the video; cross-fragment concurrency is
  // bounded by the prefetch pipeline. Returns null if the video segment is
  // missing (e.g. beyond the live edge) or muxing fails.
  Future<Uint8List?> _loadMuxedFragment(
      _SelectedTrack video, _SelectedTrack? audio, int segmentNum, int sequence) async {
    final results = await Future.wait<Uint8List?>([
      _loadSegment(video, segmentNum),
      if (audio != null) _loadSegment(audio, segmentNum),
    ]);
    final videoSeg = results[0];
    final audioSeg = audio != null && results.length > 1 ? results[1] : null;
    if (videoSeg == null) return null;
    try {
      return muxFragment(videoSeg, audioSeg, sequence);
    } catch (error) {
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

  _SelectedTrack? _selectTrack(DashManifest manifest, int trackType,
      {required bool lowestBitrate}) {
    if (manifest.periodCount == 0) return null;
    final period = manifest.getPeriod(0);
    for (final as_ in period.adaptationSets) {
      if (as_.type != trackType) continue;
      final reps = as_.representations;
      if (reps.isEmpty) continue;
      final kindName = trackType == C.trackTypeVideo ? 'video' : 'audio';
      if (!_renditionsLogged) {
        final renditions = reps
            .map((r) =>
                '${r.format.bitrate}bps ${r.format.width}x${r.format.height}')
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

  int _initialSegmentNum(DashManifest manifest, _SelectedTrack track,
      int periodDurationUs, int nowUs) {
    final index = track.index;

    if (manifest.dynamic) {
      // Live: start a few segments behind the live edge.
      final firstAvailable =
          index.getFirstAvailableSegmentNum(periodDurationUs, nowUs);
      final available = index.getAvailableSegmentCount(periodDurationUs, nowUs);
      if (available == DashSegmentIndex.indexUnbounded || available <= 0) {
        return firstAvailable;
      }
      final lastAvailable = firstAvailable + available - 1;
      final start = lastAvailable - _liveEdgeBackoff;
      return start < firstAvailable ? firstAvailable : start;
    }

    // Static manifest. A short VOD (a handful of segments) plays from the
    // start; but many "live" IPTV feeds ship a static MPD carrying a very long
    // SegmentTimeline whose end is the live edge. Starting at segment 0 there
    // means downloading/muxing hundreds of past segments before catching up —
    // the multi-minute stall we saw. So if the timeline is long, jump to near
    // its end and treat it like live.
    final first = index.getFirstSegmentNum();
    final count = index.getSegmentCount(periodDurationUs);
    if (count == DashSegmentIndex.indexUnbounded) {
      return first;
    }
    if (count > _liveLikeThreshold) {
      final lastAvailable = first + count - 1;
      final start = lastAvailable - _liveEdgeBackoff;
      return start < first ? first : start;
    }
    return first;
  }

  // A static manifest whose timeline is this long (segments) is treated as a
  // growing live feed rather than a finite VOD.
  static const int _liveLikeThreshold = 20; // ~40-60s of 2-3s segments

  // Whether playback should follow a live edge (refresh the manifest for new
  // segments at the end) rather than stopping when the current window is
  // exhausted.
  bool _isLiveEdge(
      DashManifest manifest, _SelectedTrack track, int periodDurationUs) {
    if (manifest.dynamic) return true;
    final count = track.index.getSegmentCount(periodDurationUs);
    if (count == DashSegmentIndex.indexUnbounded) return true;
    return count > _liveLikeThreshold;
  }

  int _lastAvailableSegmentNum(
      DashManifest manifest, _SelectedTrack track, int periodDurationUs) {
    final index = track.index;
    final nowUsLive = DateTime.now().toUtc().millisecondsSinceEpoch * 1000;
    final count = index.getSegmentCount(periodDurationUs);
    if (count == DashSegmentIndex.indexUnbounded) {
      final firstAvailable =
          index.getFirstAvailableSegmentNum(periodDurationUs, nowUsLive);
      final available =
          index.getAvailableSegmentCount(periodDurationUs, nowUsLive);
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
    try {
      final res = await _client.get(Uri.parse(url), headers: _originHeaders);
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

  // Fetches and parses the manifest. When [fromOrigin] is true, re-resolves
  // from the original entry URL (e.g. a `…php?id=` endpoint that 302s to a
  // fresh CDN .mpd) instead of re-hitting the pinned .mpd. The pinned .mpd is
  // often a one-shot snapshot whose SegmentTimeline never grows, so at the live
  // edge we must go back to the origin to obtain newer segments — effectively
  // reloading the stream the way a channel switch would.
  Future<DashManifest?> _fetchManifest({bool fromOrigin = false}) async {
    final source =
        (!fromOrigin && _resolvedMpdUrl.isNotEmpty) ? _resolvedMpdUrl : _mpdUrl;
    try {
      final fetched = await _fetchFollowingRedirects(source);
      _resolvedMpdUrl = fetched.$1;
      final body = utf8.decode(fetched.$2, allowMalformed: true);
      return const DashManifestParser().parse(fetched.$1, body);
    } catch (error, st) {
      debugPrint('dash: manifest fetch/parse failed: $error\n$st');
      return null;
    }
  }

  Future<(String, Uint8List)> _fetchFollowingRedirects(String url) async {
    var current = Uri.parse(url);
    for (var i = 0; i < 10; i++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(_originHeaders);
      final streamed = await _client.send(request);
      final loc = streamed.headers['location'];
      if (streamed.statusCode >= 300 &&
          streamed.statusCode < 400 &&
          loc != null) {
        await streamed.stream.drain<void>();
        current = current.resolve(loc);
        continue;
      }
      final bytes = await streamed.stream.toBytes();
      return (current.toString(), bytes);
    }
    throw Exception('Too many redirects fetching $url');
  }
}


