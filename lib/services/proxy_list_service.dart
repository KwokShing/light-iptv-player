import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/proxy_settings.dart';

/// The wire protocol a free proxy speaks. The app can route HTTP and SOCKS5;
/// SOCKS4 is filtered out at fetch time since it can't be used directly.
enum FreeProxyProtocol { http, socks5 }

extension FreeProxyProtocolX on FreeProxyProtocol {
  /// Short uppercase label for display badges.
  String get label => switch (this) {
        FreeProxyProtocol.http => 'HTTP',
        FreeProxyProtocol.socks5 => 'SOCKS5',
      };

  /// The app [ProxyType] this maps to.
  ProxyType get proxyType => switch (this) {
        FreeProxyProtocol.http => ProxyType.http,
        FreeProxyProtocol.socks5 => ProxyType.socks5,
      };
}

/// A single free proxy endpoint fetched from the public free-proxy-list source.
class FreeProxy {
  const FreeProxy({
    required this.host,
    required this.port,
    required this.protocol,
    this.latencyMs,
  });

  final String host;
  final int port;
  final FreeProxyProtocol protocol;

  /// Latency in ms reported by the source, or null when unknown.
  final int? latencyMs;

  String get hostPort => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is FreeProxy &&
      other.host == host &&
      other.port == port &&
      other.protocol == protocol;

  @override
  int get hashCode => Object.hash(host, port, protocol);
}

/// A country available in the free-proxy-list, identified by its ISO 3166-1
/// alpha-2 code (lowercased for URLs) and a human-readable label.
class ProxyCountry {
  const ProxyCountry(this.code, this.label);

  /// ISO 3166-1 alpha-2 code, lowercase (e.g. `cn`).
  final String code;
  final String label;
}

/// A cached fetch result: the country queried, the returned proxies, and the
/// proxy the user last selected (if any).
class ProxyListCache {
  ProxyListCache({
    required this.countryCode,
    required this.proxies,
    this.selected,
  });

  final String countryCode;
  final List<FreeProxy> proxies;
  FreeProxy? selected;
}

/// Fetches free proxy endpoints (with reported latency, protocol and country)
/// from the public, unauthenticated Databay proxy-list API.
///
/// See: https://github.com/databay-labs/free-proxy-list#-free-public-api
class ProxyListService {
  ProxyListService._();

  /// Countries offered in the dialog dropdown. China is listed first so it is
  /// the default selection.
  static const List<ProxyCountry> countries = [
    ProxyCountry('cn', 'China (CN)'),
    ProxyCountry('us', 'United States (US)'),
    ProxyCountry('hk', 'Hong Kong (HK)'),
    ProxyCountry('tw', 'Taiwan (TW)'),
    ProxyCountry('jp', 'Japan (JP)'),
    ProxyCountry('kr', 'South Korea (KR)'),
    ProxyCountry('sg', 'Singapore (SG)'),
    ProxyCountry('de', 'Germany (DE)'),
    ProxyCountry('gb', 'United Kingdom (GB)'),
    ProxyCountry('fr', 'France (FR)'),
    ProxyCountry('nl', 'Netherlands (NL)'),
    ProxyCountry('ru', 'Russia (RU)'),
    ProxyCountry('in', 'India (IN)'),
    ProxyCountry('ca', 'Canada (CA)'),
    ProxyCountry('br', 'Brazil (BR)'),
  ];

  static const ProxyCountry defaultCountry = ProxyCountry('cn', 'China (CN)');

  /// In-memory cache of the last successful fetch, so reopening the proxy
  /// dialog restores the previous results (and selection) instead of an empty
  /// list. Persists until the next successful [fetchAll] via the dialog's
  /// Fetch button. Not persisted across app restarts.
  static ProxyListCache? lastFetch;

  /// Public, unauthenticated Databay proxy-list API. Returns a measured
  /// latency per proxy, so no local speed test is needed.
  static const String _apiBase = 'https://databay.com/api/v1/proxy-list';

  /// Fetches proxies for [countryCode] from the Databay API, tagged with their
  /// protocol and the latency the API reports. Only strict-SSL, elite-anonymity
  /// proxies are requested (`ssl=strict&anonymity=elite`) — these preserve the
  /// target site's certificate (no MITM) and hide the client's IP. SOCKS4 is
  /// filtered out. Sorted by latency ascending (unknown last). Throws with a
  /// short message on network/parse failure.
  ///
  /// The request is sent DIRECT (bypassing any configured app proxy) so the
  /// list can always be refreshed even while a broken proxy is active.
  static Future<List<FreeProxy>> fetchAll({
    required String countryCode,
  }) async {
    final cc = countryCode.trim().toLowerCase();

    List<FreeProxy> proxies;
    try {
      proxies = await _fetchFromApi(cc);
    } catch (apiError) {
      // The API can be flaky (empty/non-JSON body, redirects). Fall back to the
      // per-country .txt files, which lack latency but are reliable.
      try {
        proxies = await _fetchFromTxt(cc);
      } catch (_) {
        // Surface the original API error, it's usually the more informative one.
        throw Exception('$apiError');
      }
    }

    proxies.sort((a, b) {
      final la = a.latencyMs;
      final lb = b.latencyMs;
      if (la == null && lb == null) return 0;
      if (la == null) return 1;
      if (lb == null) return -1;
      return la.compareTo(lb);
    });
    lastFetch = ProxyListCache(countryCode: cc, proxies: proxies);
    return proxies;
  }

  static Future<List<FreeProxy>> _fetchFromApi(String cc) async {
    final uri = Uri.parse(_apiBase).replace(queryParameters: {
      'country': cc,
      'ssl': 'strict',
      'anonymity': 'elite',
      'format': 'json',
      'limit': '200',
    });
    final body = await _getDirect(uri);
    if (body.trim().isEmpty) {
      throw Exception('Empty response from proxy API');
    }
    return _parseApi(body);
  }

  /// Fallback: per-country plain-text lists (`IP:PORT` per line) for HTTP and
  /// SOCKS5. No latency is available from these files.
  static Future<List<FreeProxy>> _fetchFromTxt(String cc) async {
    final result = <FreeProxy>[];
    final seen = <FreeProxy>{};
    var anySuccess = false;
    for (final entry in const [
      (FreeProxyProtocol.http, 'http'),
      (FreeProxyProtocol.socks5, 'socks5'),
    ]) {
      final protocol = entry.$1;
      final name = entry.$2;
      final urls = [
        Uri.parse(
          'https://cdn.jsdelivr.net/gh/databay-labs/free-proxy-list/by-country/$cc/$name.txt',
        ),
        Uri.parse(
          'https://raw.githubusercontent.com/databay-labs/free-proxy-list/master/by-country/$cc/$name.txt',
        ),
      ];
      for (final url in urls) {
        try {
          final body = await _getDirect(url);
          anySuccess = true;
          for (final line in body.split('\n')) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) continue;
            final colon = trimmed.lastIndexOf(':');
            if (colon <= 0 || colon >= trimmed.length - 1) continue;
            final host = trimmed.substring(0, colon).trim();
            final port = int.tryParse(trimmed.substring(colon + 1).trim());
            if (host.isEmpty || port == null || port <= 0 || port > 65535) {
              continue;
            }
            final proxy =
                FreeProxy(host: host, port: port, protocol: protocol);
            if (seen.add(proxy)) result.add(proxy);
          }
          break; // Got this protocol; skip its fallback mirror.
        } catch (_) {
          // Try next mirror / protocol.
        }
      }
    }
    if (!anySuccess) throw Exception('Failed to fetch proxy list');
    return result;
  }

  /// GETs [uri] DIRECT (bypassing any configured app proxy) and returns the
  /// decoded body. Follows redirects and sends browser-like headers so the
  /// endpoint doesn't reject or return an empty body.
  static Future<String> _getDirect(Uri uri) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.autoUncompress = true;
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.userAgentHeader, 'light-iptv-player');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
      final response = await request.close().timeout(
            const Duration(seconds: 15),
          );
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw Exception('Request timed out');
    } finally {
      client.close(force: true);
    }
  }

  static List<FreeProxy> _parseApi(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw Exception('Proxy API returned invalid JSON');
    }
    // The API may return either a bare list or an object wrapping `data`.
    final List<dynamic> records = decoded is List
        ? decoded
        : (decoded is Map<String, dynamic>
            ? (decoded['data'] as List<dynamic>? ??
                decoded['proxies'] as List<dynamic>? ??
                const [])
            : const []);

    final seen = <FreeProxy>{};
    final result = <FreeProxy>[];
    for (final raw in records) {
      if (raw is! Map<String, dynamic>) continue;
      final host = (raw['ip'] as String?)?.trim() ?? '';
      final port = (raw['port'] as num?)?.toInt() ??
          int.tryParse('${raw['port']}') ??
          0;
      if (host.isEmpty || port <= 0 || port > 65535) continue;

      // SOCKS4 and anything unsupported is dropped here.
      final protocol = _protocolFromApi(raw['protocol']);
      if (protocol == null) continue;

      // The API field is `latency` (ms); tolerate `latency_ms` too.
      final latency = (raw['latency'] as num?)?.toInt() ??
          (raw['latency_ms'] as num?)?.toInt();
      final proxy = FreeProxy(
        host: host,
        port: port,
        protocol: protocol,
        latencyMs: latency,
      );
      if (seen.add(proxy)) result.add(proxy);
    }
    return result;
  }

  /// Maps the API's protocol string (e.g. `"Http"`, `"SOCKS5"`) to a supported
  /// protocol, or null to drop it (SOCKS4, HTTPS-only, unknown).
  static FreeProxyProtocol? _protocolFromApi(Object? value) {
    switch ('$value'.toLowerCase()) {
      case 'http':
      case 'https':
        return FreeProxyProtocol.http;
      case 'socks5':
        return FreeProxyProtocol.socks5;
      default:
        return null; // socks4 and anything else.
    }
  }
}
