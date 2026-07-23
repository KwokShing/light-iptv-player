import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'debug_log_service.dart';
import 'user_agent_service.dart';

/// Detects AV3A (AVS3-P3 / Audio Vivid) signalling in manifests, MP4 sample
/// entries, raw AV3A files, or MPEG-TS PMTs (stream_type 0xD5).
bool looksLikeAv3a(String source, List<int> bytes, String text) {
  final path = (Uri.tryParse(source)?.path ?? source).toLowerCase();
  if (path.endsWith('.av3a')) return true;
  final lower = text.toLowerCase();
  if (lower.contains('av3a') ||
      lower.contains('avs3-p3') ||
      lower.contains('audio vivid')) {
    return true;
  }
  // The 'av3a' fourcc (0x61 0x76 0x33 0x61) marks the codec in an MP4/fMP4
  // sample-entry box. A binary init segment decoded as text can lose it to
  // replacement characters, so scan the raw bytes directly as a backstop.
  if (_containsAscii(bytes, const [0x61, 0x76, 0x33, 0x61])) return true;
  return _mpegTsContainsAv3a(bytes);
}

bool _containsAscii(List<int> bytes, List<int> needle) {
  if (needle.isEmpty || bytes.length < needle.length) return false;
  final last = bytes.length - needle.length;
  for (var i = 0; i <= last; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

bool _mpegTsContainsAv3a(List<int> bytes) {
  final pmtPids = <int>{};
  for (
    var offset = _tsSyncOffset(bytes);
    offset >= 0 && offset + 188 <= bytes.length;
    offset += 188
  ) {
    final packet = bytes.sublist(offset, offset + 188);
    final pid = ((packet[1] & 0x1f) << 8) | packet[2];
    final payload = _tsPayload(packet);
    if (payload == null || payload.isEmpty) continue;
    final start = (packet[1] & 0x40) != 0 ? 1 + payload[0] : 0;
    if (start >= payload.length) continue;
    if (pid == 0 && payload[start] == 0x00) {
      if (start + 2 >= payload.length) continue;
      final sectionLength =
          ((payload[start + 1] & 0x0f) << 8) | payload[start + 2];
      final end = (start + 3 + sectionLength - 4).clamp(0, payload.length);
      for (var i = start + 8; i + 3 < end; i += 4) {
        final program = (payload[i] << 8) | payload[i + 1];
        if (program != 0) {
          pmtPids.add(((payload[i + 2] & 0x1f) << 8) | payload[i + 3]);
        }
      }
    } else if (pmtPids.contains(pid) && payload[start] == 0x02) {
      if (_pmtContainsAv3a(payload, start)) return true;
    }
  }
  return false;
}

int _tsSyncOffset(List<int> bytes) {
  for (var i = 0; i < 188 && i + 376 < bytes.length; i++) {
    if (bytes[i] == 0x47 && bytes[i + 188] == 0x47 && bytes[i + 376] == 0x47) {
      return i;
    }
  }
  return -1;
}

List<int>? _tsPayload(List<int> packet) {
  final adaptationControl = (packet[3] >> 4) & 0x03;
  if (adaptationControl == 0 || adaptationControl == 2) return null;
  var offset = 4;
  if (adaptationControl == 3) offset += 1 + packet[4];
  return offset < packet.length ? packet.sublist(offset) : null;
}

bool _pmtContainsAv3a(List<int> section, int start) {
  if (start + 12 > section.length) return false;
  final sectionLength = ((section[start + 1] & 0x0f) << 8) | section[start + 2];
  final sectionEnd = (start + 3 + sectionLength - 4).clamp(0, section.length);
  final programInfoLength =
      ((section[start + 10] & 0x0f) << 8) | section[start + 11];
  var offset = start + 12 + programInfoLength;
  while (offset + 4 < sectionEnd) {
    if (section[offset] == 0xd5) return true;
    final infoLength =
        ((section[offset + 3] & 0x0f) << 8) | section[offset + 4];
    offset += 5 + infoLength;
  }
  return false;
}

/// Converts AV3A audio to stereo AAC while stream-copying video, then exposes
/// the synchronized Matroska output to libmpv through a loopback HTTP endpoint.
class Av3aStreamServer {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  Process? _process;
  String? _source;
  String? _proxyUrl;
  int _generation = 0;

  Future<String> start(String source, {String? proxyUrl}) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'AV3A playback is currently available on Windows only',
      );
    }
    if (!await _ffmpegFile.exists()) {
      throw StateError(
        'The AV3A FFmpeg runtime is missing from the application directory',
      );
    }
    await stop();
    _source = source;
    final uri = Uri.tryParse(source);
    final isLoopback =
        uri != null &&
        const {
          'localhost',
          '127.0.0.1',
          '::1',
        }.contains(uri.host.toLowerCase());
    _proxyUrl = isLoopback ? null : proxyUrl;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _requests = server.listen(_handleRequest);
    return 'http://127.0.0.1:${server.port}/stream.mkv';
  }

  File get _ffmpegFile => File(
    '${File(Platform.resolvedExecutable).parent.path}'
    '${Platform.pathSeparator}av3a_ffmpeg${Platform.pathSeparator}ffmpeg.exe',
  );

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'GET' || request.uri.path != '/stream.mkv') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final source = _source;
    if (source == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    final generation = ++_generation;
    await _stopProcess();
    final response = request.response
      ..bufferOutput = false
      ..headers.contentType = ContentType('video', 'x-matroska')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      final args = <String>[
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'warning',
        if (UserAgentService.current != null) ...[
          '-user_agent',
          UserAgentService.current!,
        ],
        if (_proxyUrl != null && _proxyUrl!.isNotEmpty) ...[
          '-http_proxy',
          _proxyUrl!,
        ],
        // A live HLS AV3A service can present its audio stream sparsely, so the
        // audio elementary stream may not appear inside a small initial probe
        // window. When FFmpeg finishes probing without having seen it, the
        // optional `-map 0:a:0?` below silently produces a video-only output —
        // the "sometimes no sound" symptom. Probe generously (100 MB / 30 s)
        // and raise the analyzed-packet ceiling so the AV3A audio stream is
        // reliably discovered before mapping.
        '-analyzeduration',
        '30000000',
        '-probesize',
        '100000000',
        '-max_probe_packets',
        '5000',
        '-i',
        _localPath(source),
        // Keep the source PTS relationship. `-copyts` preserves original
        // timestamps and `-start_at_zero` shifts both streams by the same
        // amount, so a non-zero first video PTS (common on HLS) no longer
        // offsets audio against video.
        '-copyts',
        '-start_at_zero',
        '-map',
        '0:v:0?',
        '-map',
        '0:a:0?',
        '-sn',
        '-dn',
        '-c:v',
        'copy',
        '-c:a',
        'aac',
        // A/V sync is carried by PTS, so transcode latency alone should not
        // desync anything. The residual drift comes from the AAC encoder's
        // priming delay and resampling. Rather than guess a fixed offset, let
        // the resampler align audio to the video timeline and continuously
        // correct drift: async=1 stretches/pads to keep audio locked to its
        // timestamps, and min_hard_comp bounds how large a gap is hard-cut vs.
        // smoothly compensated. This is FFmpeg's standard sync mechanism and
        // needs no magic constant.
        '-af',
        'aresample=async=1:min_hard_comp=0.100:first_pts=0',
        '-ac',
        '2',
        '-ar',
        '48000',
        '-b:a',
        '256k',
        '-max_interleave_delta',
        '1000000',
        '-flush_packets',
        '1',
        // Matroska identifies AAC unambiguously. The previous MPEG-TS bridge
        // was interpreted as MP3 by libmpv on some AV3A services, producing a
        // Header missing loop and freezing video while audio was the clock.
        '-f',
        'matroska',
        'pipe:1',
      ];
      final process = await Process.start(_ffmpegFile.path, args);
      if (_generation != generation) {
        process.kill();
        return;
      }
      _process = process;
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) {
              debugPrint('[av3a-ffmpeg] $line');
              DebugLogService.instance.add(line, source: 'av3a-ffmpeg');
            }
          });
      await response.addStream(process.stdout);
      final exitCode = await process.exitCode;
      if (exitCode != 0 && _generation == generation) {
        DebugLogService.instance.add(
          'AV3A transcoder exited with code $exitCode',
          level: DebugLogLevel.error,
          source: 'av3a-ffmpeg',
        );
      }
    } catch (error) {
      DebugLogService.instance.add(
        'AV3A conversion failed: $error',
        level: DebugLogLevel.error,
        source: 'app',
      );
    } finally {
      if (_generation == generation) await _stopProcess();
      try {
        await response.close();
      } catch (_) {}
    }
  }

  String _localPath(String source) {
    final uri = Uri.tryParse(source);
    if (uri != null && uri.isScheme('file')) {
      return uri.toFilePath(windows: Platform.isWindows);
    }
    return source;
  }

  Future<void> _stopProcess() async {
    final process = _process;
    _process = null;
    if (process != null) process.kill();
  }

  Future<void> stop() async {
    _generation++;
    await _stopProcess();
    await _requests?.cancel();
    _requests = null;
    await _server?.close(force: true);
    _server = null;
    _source = null;
    _proxyUrl = null;
  }

  void dispose() {
    unawaited(stop());
  }
}
