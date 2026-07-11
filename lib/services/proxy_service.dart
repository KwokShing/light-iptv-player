import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/proxy_settings.dart';
import 'socks_http_bridge.dart';

/// Global HttpOverrides that routes every dart:io HttpClient (and therefore
/// every `package:http` request: playlist fetches, ping probes, the ClearKey
/// DASH proxy's origin requests, update checks) through the user-configured
/// proxy — directly for HTTP proxies, via the local SOCKS bridge for SOCKS5.
///
/// The `findProxy` callback reads [ProxyService] state at request time, so
/// long-lived clients created before a settings change (e.g. PingService's
/// static client) pick up new settings without being recreated.
class ProxyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      final endpoint = ProxyService.effectiveProxyEndpoint();
      if (endpoint == null || isLoopbackHost(uri.host)) return 'DIRECT';
      return 'PROXY $endpoint';
    };
    // Answer proxy 407 challenges with the current credentials (HTTP proxies
    // only — SOCKS auth happens inside the bridge's upstream handshake).
    // Registered as a callback (rather than addProxyCredentials up front) so
    // credential changes apply to already-created clients too.
    client.authenticateProxy = (host, port, scheme, realm) {
      final settings = ProxyService.current;
      if (!settings.active ||
          settings.type != ProxyType.http ||
          !settings.hasCredentials) {
        return Future.value(false);
      }
      client.addProxyCredentials(
        host,
        port,
        realm ?? '',
        HttpClientBasicCredentials(settings.username, settings.password),
      );
      return Future.value(true);
    };
    return client;
  }
}

/// Requests to the local ClearKey DASH proxy / SOCKS bridge (and anything
/// else bound to loopback) must never be sent to the remote proxy.
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]') {
    return true;
  }
  final address = InternetAddress.tryParse(host);
  return address?.isLoopback ?? false;
}

/// Holds the currently active proxy settings for the whole app. Written by
/// ProxyController on load/save; read by [ProxyHttpOverrides] and by
/// PlaybackController when applying mpv's `http-proxy` option.
class ProxyService {
  ProxyService._();

  static ProxySettings current = const ProxySettings();

  /// The HTTP->SOCKS5 bridge, running only while a SOCKS5 proxy is active.
  /// Lifecycle is managed by ProxyController.
  static final SocksHttpBridge bridge = SocksHttpBridge();

  /// The HTTP-proxy endpoint (`host:port`) traffic should be sent to right
  /// now: the user's proxy for HTTP, the local bridge for SOCKS5, or null for
  /// direct connections.
  static String? effectiveProxyEndpoint() {
    final settings = current;
    if (!settings.active) return null;
    if (settings.type == ProxyType.http) return settings.hostPort;
    final port = bridge.port;
    return port == 0 ? null : '127.0.0.1:$port';
  }

  /// mpv `http-proxy` URL matching [effectiveProxyEndpoint], or null when no
  /// proxy is active.
  static String? mpvProxyUrl() {
    final settings = current;
    if (!settings.active) return null;
    if (settings.type == ProxyType.http) return settings.httpProxyUrl;
    final port = bridge.port;
    return port == 0 ? null : 'http://127.0.0.1:$port';
  }

  /// Verifies the given settings by fetching a tiny well-known URL through
  /// the proxy. Returns null on success, or a short error description.
  static Future<String?> testConnection(ProxySettings settings) async {
    if (!settings.isConfigured) return 'Host and port are required';
    return settings.type == ProxyType.socks5
        ? _testSocks5(settings)
        : _testHttp(settings);
  }

  static Future<String?> _testHttp(ProxySettings settings) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = ((_) => 'PROXY ${settings.hostPort}');
    if (settings.hasCredentials) {
      client.addProxyCredentials(
        settings.host.trim(),
        settings.port,
        '',
        HttpClientBasicCredentials(settings.username, settings.password),
      );
    }
    try {
      final request = await client
          .getUrl(Uri.parse('https://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
      await response.drain<void>();
      if (response.statusCode == 204 || response.statusCode == 200) {
        return null;
      }
      return 'Unexpected status ${response.statusCode}';
    } on TimeoutException {
      return 'Connection timed out';
    } on SocketException catch (e) {
      return e.message.isEmpty ? 'Connection failed' : e.message;
    } catch (e) {
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  /// SOCKS5 test: full handshake (including auth) plus a plain-HTTP request
  /// through the tunnel, exercising exactly what the bridge will do.
  static Future<String?> _testSocks5(ProxySettings settings) async {
    SocketReader? reader;
    try {
      reader = await socks5Connect(
        proxyHost: settings.host.trim(),
        proxyPort: settings.port,
        targetHost: 'www.gstatic.com',
        targetPort: 80,
        username: settings.username,
        password: settings.password,
      );
      reader.socket.add(
        ascii.encode(
          'GET /generate_204 HTTP/1.1\r\n'
          'Host: www.gstatic.com\r\n'
          'Connection: close\r\n\r\n',
        ),
      );
      final head = latin1.decode(
        await reader.readHttpHead().timeout(const Duration(seconds: 10)),
      );
      final statusLine = head.split('\r\n').first;
      final status = statusLine.split(' ');
      final code = status.length > 1 ? int.tryParse(status[1]) : null;
      if (code == 204 || code == 200) return null;
      return 'Unexpected response: $statusLine';
    } on TimeoutException {
      return 'Connection timed out';
    } on SocketException catch (e) {
      return e.message.isEmpty ? 'Connection failed' : e.message;
    } catch (e) {
      return '$e';
    } finally {
      reader?.destroy();
    }
  }
}
