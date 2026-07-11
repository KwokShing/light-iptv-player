/// Proxy protocol spoken by the user's proxy server.
enum ProxyType {
  /// Plain HTTP proxy (CONNECT for https, absolute-form for http). Used
  /// directly by both dart:io and mpv.
  http,

  /// SOCKS5 proxy. Neither dart:io's `findProxy` nor mpv/ffmpeg speak SOCKS,
  /// so traffic is routed through a local loopback HTTP->SOCKS5 bridge
  /// (see SocksHttpBridge).
  socks5,
}

/// User-configured proxy applied to playlist fetches, latency probes,
/// the ClearKey DASH proxy's origin requests and mpv's own stream requests,
/// so streams that are geo-restricted can be watched through a proxy in the
/// right region.
class ProxySettings {
  const ProxySettings({
    this.enabled = false,
    this.type = ProxyType.http,
    this.host = '',
    this.port = 8080,
    this.username = '',
    this.password = '',
  });

  final bool enabled;
  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  /// Whether a usable endpoint has been entered.
  bool get isConfigured => host.trim().isNotEmpty && port > 0 && port <= 65535;

  /// Whether traffic should actually be routed through the proxy.
  bool get active => enabled && isConfigured;

  bool get hasCredentials => username.isNotEmpty;

  /// `host:port` as used by dart:io's `findProxy` ("PROXY host:port").
  String get hostPort => '${host.trim()}:$port';

  /// Full proxy URL for mpv's `http-proxy` property when [type] is HTTP.
  /// Credentials are inlined (URL-encoded) because mpv/ffmpeg take them from
  /// the URL. For SOCKS5 use ProxyService.mpvProxyUrl() instead, which points
  /// at the local bridge.
  String get httpProxyUrl {
    final auth = hasCredentials
        ? '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}@'
        : '';
    return 'http://$auth$hostPort';
  }

  /// Whether [other] describes the same upstream endpoint (used to decide if
  /// the SOCKS bridge needs a restart).
  bool sameEndpoint(ProxySettings other) {
    return type == other.type &&
        host.trim() == other.host.trim() &&
        port == other.port &&
        username == other.username &&
        password == other.password;
  }

  ProxySettings copyWith({
    bool? enabled,
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
  }) {
    return ProxySettings(
      enabled: enabled ?? this.enabled,
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'type': type == ProxyType.socks5 ? 'socks5' : 'http',
        'host': host,
        'port': port,
        'username': username,
        'password': password,
      };

  factory ProxySettings.fromJson(Map<String, dynamic> json) {
    return ProxySettings(
      enabled: json['enabled'] == true,
      type: json['type'] == 'socks5' ? ProxyType.socks5 : ProxyType.http,
      host: (json['host'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 8080,
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
    );
  }
}
