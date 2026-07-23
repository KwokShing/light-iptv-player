/// Helpers for Xtream Codes panels. An Xtream account is a server base URL
/// plus a username/password; the panel exposes standard endpoints:
///
///   * `get.php?username=&password=&type=m3u_plus&output=ts` — the full
///     channel list as an extended M3U we can feed straight into the existing
///     playlist parser.
///   * `xmltv.php?username=&password=` — the XMLTV guide for those channels.
///
/// Keeping this thin lets Xtream sources reuse the whole M3U/EPG pipeline
/// (parsing, DASH/ClearKey hints, EPG matching) without a bespoke API client.
library;

/// Normalises a user-entered Xtream server into a scheme+host(+port) base URL
/// with no trailing slash or path. Accepts values with or without a scheme and
/// tolerates a pasted `get.php`/`player_api.php` URL by trimming the path.
String normalizeXtreamServer(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return value;
  if (!value.contains('://')) {
    value = 'http://$value';
  }
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) {
    // Fall back to stripping a trailing slash/path if it wasn't parseable.
    final slash = value.indexOf('/', value.indexOf('://') + 3);
    return slash < 0 ? value : value.substring(0, slash);
  }
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port';
}

/// The `get.php` M3U endpoint for the given account. [outputExtension] selects
/// the stream container hint Xtream embeds in generated URLs (`ts` for MPEG-TS,
/// `m3u8` for HLS); `ts` is the broadly compatible default.
String xtreamPlaylistUrl(
  String server,
  String username,
  String password, {
  String outputExtension = 'ts',
}) {
  final base = normalizeXtreamServer(server);
  return '$base/get.php?username=${Uri.encodeQueryComponent(username)}'
      '&password=${Uri.encodeQueryComponent(password)}'
      '&type=m3u_plus&output=$outputExtension';
}

/// The `xmltv.php` EPG endpoint for the given account.
String xtreamEpgUrl(String server, String username, String password) {
  final base = normalizeXtreamServer(server);
  return '$base/xmltv.php?username=${Uri.encodeQueryComponent(username)}'
      '&password=${Uri.encodeQueryComponent(password)}';
}
