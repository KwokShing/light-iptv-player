import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'debug_log_service.dart';

const _mmtTlvExtensions = ['.mmt', '.mmts', '.tlv'];

/// Whether [source] explicitly identifies an ARIB MMT/TLV stream.
bool isMmtTlvSource(String source) {
  final path = (Uri.tryParse(source)?.path ?? source).toLowerCase();
  return _mmtTlvExtensions.any(path.endsWith);
}

/// Whether an HTTP Content-Type explicitly identifies an MMT/TLV stream.
bool isMmtTlvContentType(String contentType) {
  final value = contentType.toLowerCase().split(';').first.trim();
  return value == 'video/mmt' ||
      value == 'application/mmt' ||
      value == 'video/mmts' ||
      value == 'application/mmts' ||
      value == 'video/tlv' ||
      value == 'application/tlv';
}

/// Detects consecutive ARIB TLV packets even when a live HTTP response begins
/// in the middle of a packet. Each packet is 0x7F, a constrained packet type,
/// a big-endian 16-bit payload length, then the payload.
bool looksLikeMmtTlv(List<int> bytes) {
  bool validHeader(int offset) {
    if (offset + 4 > bytes.length || bytes[offset] != 0x7f) return false;
    final type = bytes[offset + 1];
    return type <= 0x04 || type >= 0xfd;
  }

  for (var offset = 0; offset + 4 <= bytes.length; offset++) {
    if (!validHeader(offset)) continue;
    var packetOffset = offset;
    var completePackets = 0;
    while (validHeader(packetOffset)) {
      final payloadLength =
          (bytes[packetOffset + 2] << 8) | bytes[packetOffset + 3];
      packetOffset += 4 + payloadLength;
      if (packetOffset > bytes.length) break;
      completePackets++;
      if (completePackets >= 2) return true;
    }
  }
  return false;
}

/// Runs dantto4k on demand and exposes its MPEG-TS output to libmpv over a
/// loopback HTTP stream. A fresh converter is started for every request, which
/// also makes mpv's existing reconnect path work for live MMT/TLV sources.
class MmtTlvStreamServer {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  Process? _process;
  http.Client? _originClient;
  String? _source;
  int _generation = 0;

  Future<String> start(String source) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'MMT/TLV playback is currently available on Windows only',
      );
    }
    final converter = _converterFile;
    if (!await converter.exists()) {
      throw StateError(
        'dantto4k.exe is missing from the application directory',
      );
    }
    await stop();
    _source = source;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _requests = server.listen(_handleRequest);
    return 'http://127.0.0.1:${server.port}/stream.ts';
  }

  File get _converterFile {
    final executable = File(Platform.resolvedExecutable);
    return File(
      '${executable.parent.path}${Platform.pathSeparator}dantto4k.exe',
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'GET' || request.uri.path != '/stream.ts') {
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
    await _stopPipeline();
    final response = request.response
      ..bufferOutput = false
      ..headers.contentType = ContentType('video', 'mp2t')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');

    try {
      final remoteUri = Uri.tryParse(source);
      final isRemote =
          remoteUri != null &&
          (remoteUri.isScheme('http') || remoteUri.isScheme('https'));
      final input = isRemote ? '-' : _localPath(source);
      final process = await Process.start(_converterFile.path, [
        '--frontend-descrambled',
        '--no-progress',
        '--no-stats',
        input,
        '-',
      ], mode: ProcessStartMode.normal);
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
              DebugLogService.instance.add(line, source: 'dantto4k');
            }
          });

      if (isRemote) {
        _originClient = http.Client();
        unawaited(_pumpRemoteSource(remoteUri, process));
      }

      await response.addStream(process.stdout);
      final exitCode = await process.exitCode;
      if (exitCode != 0 && _generation == generation) {
        DebugLogService.instance.add(
          'MMT/TLV converter exited with code $exitCode',
          level: DebugLogLevel.error,
          source: 'dantto4k',
        );
      }
    } catch (error) {
      DebugLogService.instance.add(
        'MMT/TLV conversion failed: $error',
        level: DebugLogLevel.error,
        source: 'app',
      );
    } finally {
      if (_generation == generation) await _stopPipeline();
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _pumpRemoteSource(Uri uri, Process process) async {
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = true
        ..headers['User-Agent'] = 'Mozilla/5.0';
      final upstream = await _originClient!.send(request);
      if (upstream.statusCode < 200 || upstream.statusCode >= 300) {
        throw HttpException('HTTP ${upstream.statusCode}', uri: uri);
      }
      await upstream.stream.pipe(process.stdin);
    } catch (error) {
      DebugLogService.instance.add(
        'MMT/TLV source failed: $error',
        level: DebugLogLevel.error,
        source: 'app',
      );
      try {
        await process.stdin.close();
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

  Future<void> _stopPipeline() async {
    _originClient?.close();
    _originClient = null;
    final process = _process;
    _process = null;
    if (process != null) {
      try {
        await process.stdin.close();
      } catch (_) {}
      process.kill();
    }
  }

  Future<void> stop() async {
    _generation++;
    await _stopPipeline();
    await _requests?.cancel();
    _requests = null;
    await _server?.close(force: true);
    _server = null;
    _source = null;
  }

  void dispose() {
    unawaited(stop());
  }
}
