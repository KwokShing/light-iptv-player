import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/proxy_settings.dart';

/// Buffered reader over a [Socket]: supports exact-length reads (for the
/// SOCKS5 handshake), reading an HTTP header block, and then detaching so the
/// remaining bytes can be piped raw to another socket.
class SocketReader {
  SocketReader(this.socket) {
    _sub = socket.listen(_onData, onError: _onError, onDone: _onDone);
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buffer = <int>[];
  Completer<void>? _signal;
  bool _done = false;
  Object? _error;

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    _signal?.complete();
    _signal = null;
  }

  void _onError(Object error) {
    _error = error;
    _done = true;
    _signal?.complete();
    _signal = null;
  }

  void _onDone() {
    _done = true;
    _signal?.complete();
    _signal = null;
  }

  Future<void> _waitForData() async {
    final completer = Completer<void>();
    _signal = completer;
    await completer.future;
  }

  /// Reads exactly [n] bytes, waiting for more data as needed.
  Future<Uint8List> readBytes(int n) async {
    while (_buffer.length < n) {
      if (_done) {
        throw _error is Exception
            ? _error! as Exception
            : const SocketException('Connection closed');
      }
      await _waitForData();
    }
    final out = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return out;
  }

  /// Reads up to and including the CRLFCRLF that terminates an HTTP header
  /// block. Any body bytes already received stay buffered for [detach].
  Future<List<int>> readHttpHead({int maxBytes = 64 * 1024}) async {
    while (true) {
      final end = _indexOfHeaderEnd(_buffer);
      if (end >= 0) {
        final head = _buffer.sublist(0, end + 4);
        _buffer.removeRange(0, end + 4);
        return head;
      }
      if (_buffer.length > maxBytes) {
        throw const HttpException('Request header too large');
      }
      if (_done) {
        throw _error is Exception
            ? _error! as Exception
            : const SocketException('Connection closed before header end');
      }
      await _waitForData();
    }
  }

  static int _indexOfHeaderEnd(List<int> bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// Stops buffered reading and streams all remaining data (already-buffered
  /// bytes first) to [onData]. Used to switch into raw piping mode once the
  /// handshake / header parsing is done.
  void detach(
    void Function(Uint8List data) onData, {
    required void Function() onDone,
  }) {
    if (_buffer.isNotEmpty) {
      onData(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
    if (_done) {
      onDone();
      return;
    }
    _sub.onData(onData);
    _sub.onDone(onDone);
    _sub.onError((Object _) => onDone());
  }

  void destroy() {
    _sub.cancel();
    socket.destroy();
  }
}

/// Opens a TCP connection to [targetHost]:[targetPort] tunnelled through a
/// SOCKS5 proxy (RFC 1928), with optional username/password authentication
/// (RFC 1929). Hostnames are passed to the proxy unresolved (ATYP=DOMAIN) so
/// DNS happens in the proxy's region — important for geo-targeted CDNs.
Future<SocketReader> socks5Connect({
  required String proxyHost,
  required int proxyPort,
  required String targetHost,
  required int targetPort,
  String username = '',
  String password = '',
  Duration timeout = const Duration(seconds: 12),
}) async {
  final socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
  socket.setOption(SocketOption.tcpNoDelay, true);
  final reader = SocketReader(socket);
  try {
    await _socks5Handshake(
      reader,
      targetHost: targetHost,
      targetPort: targetPort,
      username: username,
      password: password,
    ).timeout(timeout);
    return reader;
  } catch (_) {
    reader.destroy();
    rethrow;
  }
}

Future<void> _socks5Handshake(
  SocketReader reader, {
  required String targetHost,
  required int targetPort,
  required String username,
  required String password,
}) async {
  final socket = reader.socket;
  final hasAuth = username.isNotEmpty;

  // Greeting: offer no-auth, plus username/password when credentials exist.
  socket.add([0x05, hasAuth ? 2 : 1, 0x00, if (hasAuth) 0x02]);
  final greeting = await reader.readBytes(2);
  if (greeting[0] != 0x05) {
    throw const SocketException('Not a SOCKS5 proxy');
  }
  switch (greeting[1]) {
    case 0x00:
      break;
    case 0x02:
      if (!hasAuth) {
        throw const SocketException('SOCKS5 proxy requires a username/password');
      }
      final user = utf8.encode(username);
      final pass = utf8.encode(password);
      if (user.length > 255 || pass.length > 255) {
        throw const SocketException('SOCKS5 credentials too long');
      }
      socket.add([0x01, user.length, ...user, pass.length, ...pass]);
      final auth = await reader.readBytes(2);
      if (auth[1] != 0x00) {
        throw const SocketException('SOCKS5 authentication failed');
      }
    default:
      throw const SocketException('SOCKS5: no acceptable authentication method');
  }

  // CONNECT request.
  final request = <int>[0x05, 0x01, 0x00];
  final ip = InternetAddress.tryParse(targetHost);
  if (ip != null && ip.type == InternetAddressType.IPv4) {
    request
      ..add(0x01)
      ..addAll(ip.rawAddress);
  } else if (ip != null && ip.type == InternetAddressType.IPv6) {
    request
      ..add(0x04)
      ..addAll(ip.rawAddress);
  } else {
    final domain = utf8.encode(targetHost);
    if (domain.isEmpty || domain.length > 255) {
      throw SocketException('SOCKS5: invalid target host "$targetHost"');
    }
    request
      ..add(0x03)
      ..add(domain.length)
      ..addAll(domain);
  }
  request
    ..add((targetPort >> 8) & 0xff)
    ..add(targetPort & 0xff);
  socket.add(request);

  final reply = await reader.readBytes(4);
  if (reply[0] != 0x05) {
    throw const SocketException('SOCKS5: malformed reply');
  }
  if (reply[1] != 0x00) {
    throw SocketException('SOCKS5 connect failed: ${_replyText(reply[1])}');
  }
  // Consume the bound address so the tunnel starts at a clean byte boundary.
  switch (reply[3]) {
    case 0x01:
      await reader.readBytes(4 + 2);
    case 0x04:
      await reader.readBytes(16 + 2);
    case 0x03:
      final len = (await reader.readBytes(1))[0];
      await reader.readBytes(len + 2);
    default:
      throw const SocketException('SOCKS5: malformed reply address');
  }
}

String _replyText(int code) => switch (code) {
      0x01 => 'general failure',
      0x02 => 'connection not allowed by ruleset',
      0x03 => 'network unreachable',
      0x04 => 'host unreachable',
      0x05 => 'connection refused',
      0x06 => 'TTL expired',
      0x07 => 'command not supported',
      0x08 => 'address type not supported',
      _ => 'error $code',
    };

/// A minimal loopback HTTP proxy whose upstream is a SOCKS5 tunnel.
///
/// Neither dart:io's `findProxy` (only "PROXY host:port") nor mpv/ffmpeg's
/// `http-proxy` speak SOCKS, so when the user configures a SOCKS5 proxy the
/// app points both at this bridge instead: it accepts standard HTTP-proxy
/// traffic (CONNECT tunnels for https, absolute-form requests for plain http)
/// and forwards each connection through the configured SOCKS5 server.
///
/// Bound to 127.0.0.1 on an ephemeral port, so nothing off-machine can reach
/// it. It carries no credentials of its own; SOCKS auth happens upstream.
class SocksHttpBridge {
  ServerSocket? _server;
  ProxySettings? _settings;
  final Set<Socket> _liveSockets = <Socket>{};

  /// Loopback port the bridge is listening on, or 0 when stopped.
  int get port => _server?.port ?? 0;

  bool get running => _server != null;

  /// Starts the bridge for [settings], reusing the running server when the
  /// upstream endpoint is unchanged.
  Future<void> ensureStarted(ProxySettings settings) async {
    final current = _settings;
    if (_server != null && current != null && current.sameEndpoint(settings)) {
      _settings = settings;
      return;
    }
    await stop();
    _settings = settings;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      (client) => unawaited(_handleClient(client)),
      onError: (Object e) => debugPrint('SOCKS bridge: accept error: $e'),
    );
    debugPrint(
      'SOCKS bridge: listening on 127.0.0.1:${server.port} '
      '-> socks5://${settings.hostPort}',
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _settings = null;
    if (server != null) {
      await server.close();
      debugPrint('SOCKS bridge: stopped');
    }
    for (final socket in _liveSockets.toList()) {
      socket.destroy();
    }
    _liveSockets.clear();
  }

  Future<void> _handleClient(Socket client) async {
    _liveSockets.add(client);
    client.done.whenComplete(() => _liveSockets.remove(client)).catchError((_) {});
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final reader = SocketReader(client);
    SocketReader? remote;
    try {
      final settings = _settings;
      if (settings == null) throw const SocketException('Bridge stopped');

      final head = latin1.decode(
        await reader.readHttpHead().timeout(const Duration(seconds: 30)),
      );
      final lines = head.split('\r\n');
      final parts = lines.first.split(' ');
      if (parts.length < 3) throw const HttpException('Malformed request line');
      final method = parts[0];
      final target = parts[1];
      final version = parts[2];

      if (method == 'CONNECT') {
        final (host, port) = _parseAuthority(target, defaultPort: 443);
        remote = await _connectUpstream(settings, host, port);
        client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      } else {
        final uri = Uri.tryParse(target);
        if (uri == null || !uri.isScheme('http') || uri.host.isEmpty) {
          client.add(
            ascii.encode('HTTP/1.1 400 Bad Request\r\n\r\n'),
          );
          await client.flush();
          throw const HttpException('Unsupported proxy request');
        }
        remote = await _connectUpstream(
          settings,
          uri.host,
          uri.hasPort ? uri.port : 80,
        );
        // Rewrite the absolute-form request line to origin-form and force
        // Connection: close — after this first request the connection is a
        // blind pipe, so later keep-alive requests couldn't be rewritten.
        final path =
            '${uri.path.isEmpty ? '/' : uri.path}'
            '${uri.hasQuery ? '?${uri.query}' : ''}';
        final rewritten = StringBuffer('$method $path $version\r\n');
        for (final line in lines.skip(1)) {
          if (line.isEmpty) continue;
          final name = line.split(':').first.trim().toLowerCase();
          if (name == 'proxy-connection' ||
              name == 'connection' ||
              name == 'proxy-authorization') {
            continue;
          }
          rewritten.write('$line\r\n');
        }
        rewritten.write('Connection: close\r\n\r\n');
        remote.socket.add(latin1.encode(rewritten.toString()));
      }

      // Blind bidirectional pipe from here on.
      final remoteSocket = remote.socket;
      _liveSockets.add(remoteSocket);
      remoteSocket.done
          .whenComplete(() => _liveSockets.remove(remoteSocket))
          .catchError((_) {});
      reader.detach(
        remoteSocket.add,
        onDone: () => _flushAndDestroy(remoteSocket),
      );
      remote.detach(
        client.add,
        onDone: () => _flushAndDestroy(client),
      );
    } catch (e) {
      debugPrint('SOCKS bridge: connection failed: $e');
      remote?.destroy();
      reader.destroy();
    }
  }

  Future<SocketReader> _connectUpstream(
    ProxySettings settings,
    String host,
    int port,
  ) {
    return socks5Connect(
      proxyHost: settings.host.trim(),
      proxyPort: settings.port,
      targetHost: host,
      targetPort: port,
      username: settings.username,
      password: settings.password,
    );
  }

  static void _flushAndDestroy(Socket socket) {
    socket.flush().whenComplete(socket.destroy).catchError((_) {
      socket.destroy();
    });
  }

  /// Parses a CONNECT authority ("host:port", including "[v6]:port").
  static (String, int) _parseAuthority(String value, {required int defaultPort}) {
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end < 0) throw const HttpException('Malformed CONNECT target');
      final host = value.substring(1, end);
      final rest = value.substring(end + 1);
      final port = rest.startsWith(':')
          ? int.tryParse(rest.substring(1)) ?? defaultPort
          : defaultPort;
      return (host, port);
    }
    final colon = value.lastIndexOf(':');
    if (colon < 0) return (value, defaultPort);
    return (
      value.substring(0, colon),
      int.tryParse(value.substring(colon + 1)) ?? defaultPort,
    );
  }
}
