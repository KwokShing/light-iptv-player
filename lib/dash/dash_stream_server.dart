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
// Selection policy mirrors the old code's pragmatic choice: the lowest-bitrate
// video Representation (segments small enough to fetch+decrypt+mux in time) and
// the first audio Representation.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
  _SelectedTrack(this.representation, this.baseUrl, this.index);

  final Representation representation;
  final String baseUrl;
  final DashSegmentIndex index;

  TrackCrypto? crypto; // discovered from the init segment
}

class DashStreamServer {
  HttpServer? _server;
  final http.Client _client = http.Client();

  String _mpdUrl = '';
  String _resolvedMpdUrl = '';
  Map<String, String> _keys = {};

  // Guards against overlapping streaming sessions when mpv reconnects.
  int _sessionSeq = 0;

  static const Map<String, String> _originHeaders = {
    'User-Agent': 'Mozilla/5.0',
  };

  bool get isRunning => _server != null;

  String get _base => 'http://127.0.0.1:${_server?.port ?? 0}';

  /// Starts the server for [mpdUrl] with ClearKey [keys] (kidHex -> keyHex).
  /// Returns the local URL to hand to mpv.
  Future<String> start(String mpdUrl, Map<String, String> keys) async {
    await stop();
    _mpdUrl = mpdUrl;
    _resolvedMpdUrl = '';
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

  Future<void> _serveStream(HttpRequest req, int session) async {
    final initial = await _fetchManifest();
    if (initial == null) {
      req.response.statusCode = HttpStatus.badGateway;
      return;
    }
    var manifest = initial;

    final video = _selectVideo(manifest);
    final audio = _selectAudio(manifest);
    if (video == null) {
      debugPrint('dash: no video representation found');
      req.response.statusCode = HttpStatus.badGateway;
      return;
    }
    debugPrint('dash: selected video=${video.representation.format} '
        'audio=${audio?.representation.format}');

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType('video', 'mp4');
    // Unknown length: streamed live/progressively.
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'none');

    // 1) init segments -> merged init.
    final videoInitRaw = await _loadInit(video);
    final audioInitRaw = audio == null ? null : await _loadInit(audio);
    if (videoInitRaw == null) {
      debugPrint('dash: failed to load video init');
      return;
    }
    final mergedInit = muxInit(videoInitRaw, audioInitRaw);
    if (session != _sessionSeq) return;
    req.response.add(mergedInit);
    await req.response.flush();

    // 2) media segment loop.
    final periodIndex = 0;
    var periodDurationUs = manifest.getPeriodDurationUs(periodIndex);
    final nowUs = DateTime.now().toUtc().millisecondsSinceEpoch * 1000;

    // Starting segment: for dynamic (live) start near the live edge, minus a
    // small back-off; for static start at the first segment.
    var segmentNum = _initialSegmentNum(manifest, video, periodDurationUs, nowUs);
    var sequence = 1;

    while (session == _sessionSeq) {
      final lastAvailable = _lastAvailableSegmentNum(
          manifest, video, periodDurationUs, nowUs);
      if (lastAvailable != DashSegmentIndex.indexUnbounded &&
          segmentNum > lastAvailable) {
        if (!manifest.dynamic) {
          break; // VOD finished.
        }
        // Live: wait then refresh the manifest for newly published segments.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final refreshed = await _fetchManifest();
        if (refreshed != null) {
          manifest = refreshed;
          periodDurationUs = manifest.getPeriodDurationUs(periodIndex);
        }
        continue;
      }

      final Uint8List? videoSeg = await _loadSegment(video, segmentNum);
      final Uint8List? audioSeg =
          audio == null ? null : await _loadSegment(audio, segmentNum);
      if (session != _sessionSeq) return;

      if (videoSeg == null) {
        // Missing segment: skip forward rather than stalling forever.
        segmentNum++;
        continue;
      }

      Uint8List muxed;
      try {
        muxed = muxFragment(videoSeg, audioSeg, sequence);
      } catch (error) {
        debugPrint('dash: mux failed at seg $segmentNum: $error');
        segmentNum++;
        continue;
      }

      try {
        req.response.add(muxed);
        await req.response.flush();
      } on SocketException {
        return; // mpv closed the connection.
      } catch (_) {
        return;
      }

      segmentNum++;
      sequence++;
    }
  }

  // ---------------------------------------------------------------------------
  // Track selection
  // ---------------------------------------------------------------------------

  _SelectedTrack? _selectVideo(DashManifest manifest) =>
      _selectTrack(manifest, C.trackTypeVideo, lowestBitrate: true);

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
      return _SelectedTrack(chosen, baseUrl, index);
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Segment numbering (mirrors DefaultDashChunkSource's use of DashSegmentIndex)
  // ---------------------------------------------------------------------------

  int _initialSegmentNum(DashManifest manifest, _SelectedTrack track,
      int periodDurationUs, int nowUs) {
    final index = track.index;
    if (!manifest.dynamic) {
      return index.getFirstSegmentNum();
    }
    // Live: start a few segments behind the live edge for a small buffer.
    final firstAvailable = index.getFirstAvailableSegmentNum(periodDurationUs, nowUs);
    final available = index.getAvailableSegmentCount(periodDurationUs, nowUs);
    if (available == DashSegmentIndex.indexUnbounded || available <= 0) {
      return firstAvailable;
    }
    final lastAvailable = firstAvailable + available - 1;
    const backoff = 3;
    final start = lastAvailable - backoff;
    return start < firstAvailable ? firstAvailable : start;
  }

  int _lastAvailableSegmentNum(DashManifest manifest, _SelectedTrack track,
      int periodDurationUs, int nowUs) {
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
    final segUri = track.index.getSegmentUrl(segmentNum);
    final url = segUri.resolveUriString(track.baseUrl);
    final raw = await _get(url);
    if (raw == null) return null;
    final crypto = track.crypto;
    if (crypto?.key == null) return raw; // clear stream, pass through.
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

  Future<DashManifest?> _fetchManifest() async {
    final source = _resolvedMpdUrl.isNotEmpty ? _resolvedMpdUrl : _mpdUrl;
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


