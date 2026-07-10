import 'dart:async';

import 'package:http/http.dart' as http;

/// Result of a reachability probe against a channel's stream host.
class PingResult {
  const PingResult.reachable(this.ms) : reachable = true;
  const PingResult.unreachable() : ms = null, reachable = false;

  final int? ms;
  final bool reachable;
}

/// A minimal counting semaphore used to cap how many reachability probes run
/// at once. Without it, scrolling through a long list could open hundreds of
/// simultaneous connections and hammer both the machine and the servers.
class Semaphore {
  Semaphore(this.maxConcurrent);

  final int maxConcurrent;
  int _active = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<void> acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else if (_active > 0) {
      _active--;
    }
  }
}

/// Probes whether a channel's stream can actually be reached by issuing a
/// streamed HTTP GET for just the first bytes and measuring the time to the
/// first response (TTFB). Unlike a bare TCP handshake this confirms the real
/// stream path exists, auth passed and the server is willing to serve data —
/// a 2xx/3xx response counts as reachable, anything else (4xx/5xx, timeout or
/// network error) counts as unreachable. Results are cached per URL for the
/// session, in-flight probes are de-duplicated, and a semaphore caps how many
/// run concurrently.
class PingService {
  PingService._();

  static const Duration timeout = Duration(seconds: 5);

  // Many IPTV servers reject unknown clients, so present a player-like agent.
  static const String _userAgent = 'VLC/3.0.20 LibVLC/3.0.20';

  static final http.Client _client = http.Client();
  // Probes are almost entirely idle network waits, so a higher ceiling is cheap
  // and keeps the rows currently on screen from queueing behind slow/dead hosts
  // that hold a slot for the full timeout. Enough to cover a screenful at once.
  static final Semaphore _semaphore = Semaphore(24);

  static final Map<String, PingResult> _cache = <String, PingResult>{};
  static final Map<String, Future<PingResult>> _inFlight =
      <String, Future<PingResult>>{};

  static PingResult? cached(String url) => _cache[url];

  static Future<PingResult> ping(String url) {
    final existing = _cache[url];
    if (existing != null) return Future<PingResult>.value(existing);
    final inFlight = _inFlight[url];
    if (inFlight != null) return inFlight;

    final future = _runGuarded(url);
    _inFlight[url] = future;
    return future;
  }

  static Future<PingResult> _runGuarded(String url) async {
    await _semaphore.acquire();
    try {
      final result = await _measure(url);
      _cache[url] = result;
      return result;
    } finally {
      _semaphore.release();
      _inFlight.remove(url);
    }
  }

  static Future<PingResult> _measure(String url) async {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return const PingResult.unreachable();
    }
    if (uri.host.isEmpty || !uri.hasScheme) {
      return const PingResult.unreachable();
    }

    final request = http.Request('GET', uri)
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers['Range'] = 'bytes=0-1'
      ..headers['User-Agent'] = _userAgent
      ..headers['Accept'] = '*/*';

    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client.send(request).timeout(timeout);
      stopwatch.stop();
      // We only needed the headers (TTFB). Cancel the body so we never pull a
      // whole live stream down when the server ignores our Range request.
      unawaited(response.stream.listen(null).cancel());

      final code = response.statusCode;
      if (code >= 200 && code < 400) {
        return PingResult.reachable(stopwatch.elapsedMilliseconds);
      }
      return const PingResult.unreachable();
    } catch (_) {
      return const PingResult.unreachable();
    }
  }
}
