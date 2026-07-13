import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:charset_converter/charset_converter.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../models/playlist.dart';

/// Parsed result of a playlist: its channels plus an optional EPG (XMLTV) URL
/// declared in the M3U header (`url-tvg` / `x-tvg-url`).
class ParsedPlaylist {
  const ParsedPlaylist({required this.channels, this.epgUrl});
  final List<Channel> channels;
  final String? epgUrl;
}

ParsedPlaylist parsePlaylist(String text) {
  final lines = const LineSplitter()
      .convert(text)
      .map((line) => line.trim())
      .toList();
  if (_looksLikeTxtPlaylist(lines)) {
    return ParsedPlaylist(channels: _parseTxtPlaylist(lines));
  }
  final channels = <Channel>[];
  String? epgUrl;
  var pendingName = '';
  var pendingGroup = ungroupedGroup;
  String? pendingLogo;
  String? pendingTvgId;
  String? extGrp;
  String? pendingManifestType;
  String? pendingLicenseType;
  String? pendingLicenseKey;

  void resetPending() {
    pendingName = '';
    pendingGroup = ungroupedGroup;
    pendingLogo = null;
    pendingTvgId = null;
    extGrp = null;
    pendingManifestType = null;
    pendingLicenseType = null;
    pendingLicenseKey = null;
  }

  for (final line in lines) {
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTM3U')) {
      // The header can carry the guide URL, e.g.
      //   #EXTM3U url-tvg="http://.../epg.xml" x-tvg-url="..."
      epgUrl ??=
          _attrFromExtInf(line, 'url-tvg') ??
          _attrFromExtInf(line, 'x-tvg-url') ??
          _attrFromExtInf(line, 'tvg-url');
      continue;
    }
    if (line.startsWith('#EXTGRP:')) {
      extGrp = line.substring('#EXTGRP:'.length).trim();
      continue;
    }
    // Kodi-style DRM/adaptive hints, e.g.
    //   #KODIPROP:inputstream.adaptive.manifest_type=mpd
    //   #KODIPROP:inputstream.adaptive.license_type=clearkey
    //   #KODIPROP:inputstream.adaptive.license_key=<kid>:<key>
    // Applied to the next stream URL that follows.
    if (line.startsWith('#KODIPROP:')) {
      final body = line.substring('#KODIPROP:'.length).trim();
      final eq = body.indexOf('=');
      if (eq > 0) {
        final key = body.substring(0, eq).trim().toLowerCase();
        final value = body.substring(eq + 1).trim();
        if (key.endsWith('manifest_type')) {
          pendingManifestType = value;
        } else if (key.endsWith('license_type')) {
          pendingLicenseType = value;
        } else if (key.endsWith('license_key')) {
          pendingLicenseKey = value;
        }
      }
      continue;
    }
    if (line.startsWith('#EXTINF')) {
      pendingName = _nameFromExtInf(line);
      pendingGroup =
          _attrFromExtInf(line, 'group-title') ?? extGrp ?? ungroupedGroup;
      pendingLogo = _attrFromExtInf(line, 'tvg-logo');
      pendingTvgId = _attrFromExtInf(line, 'tvg-id');
      continue;
    }
    if (!line.startsWith('#')) {
      channels.add(
        Channel(
          name: pendingName.isEmpty ? line : pendingName,
          url: line,
          group: pendingGroup.trim().isEmpty
              ? ungroupedGroup
              : pendingGroup.trim(),
          logo: pendingLogo,
          tvgId: (pendingTvgId?.trim().isEmpty ?? true) ? null : pendingTvgId,
          manifestType: pendingManifestType,
          licenseType: pendingLicenseType,
          licenseKey: pendingLicenseKey,
        ),
      );
      resetPending();
    }
  }
  return ParsedPlaylist(
    channels: channels,
    epgUrl: (epgUrl?.trim().isEmpty ?? true) ? null : epgUrl!.trim(),
  );
}

/// Detects the "txt" playlist format common in Chinese IPTV lists (diyp/TVBox
/// style): `分组,#genre#` starts a group and each channel is `name,url`, with
/// an optional `$线路名` label after the URL. Anything with EXTM3U/EXTINF
/// markers is treated as M3U instead.
bool _looksLikeTxtPlaylist(List<String> lines) {
  var txtLines = 0;
  for (final line in lines) {
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT')) return false;
    if (_isGenreLine(line)) return true;
    if (_splitTxtLine(line) != null && ++txtLines >= 2) return true;
  }
  return false;
}

bool _isGenreLine(String line) {
  final comma = line.indexOf(',');
  return comma > 0 && line.substring(comma + 1).trim() == '#genre#';
}

/// Splits a `name,url` txt line, returning null when the line isn't one.
(String, String)? _splitTxtLine(String line) {
  final comma = line.indexOf(',');
  if (comma <= 0) return null;
  final name = line.substring(0, comma).trim();
  final url = line.substring(comma + 1).trim();
  if (name.isEmpty || !_looksLikeStreamUrl(url)) return null;
  return (name, url);
}

bool _looksLikeStreamUrl(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('rtsp://') ||
      lower.startsWith('rtmp://') ||
      lower.startsWith('rtp://') ||
      lower.startsWith('udp://');
}

List<Channel> _parseTxtPlaylist(List<String> lines) {
  final channels = <Channel>[];
  var group = ungroupedGroup;
  for (final line in lines) {
    if (line.isEmpty) continue;
    if (_isGenreLine(line)) {
      final name = line.substring(0, line.indexOf(',')).trim();
      group = name.isEmpty ? ungroupedGroup : name;
      continue;
    }
    final parts = _splitTxtLine(line);
    if (parts == null) continue;
    final (name, rawUrl) = parts;
    // A `$label` suffix names the line/carrier (e.g. `...$安徽电信`). It is
    // not part of the URL — strip it, and use it to tell same-named channels
    // apart. Some lists also join several URLs with `#`; keep each as its own
    // channel entry.
    for (final candidate in rawUrl.split('#')) {
      final dollar = candidate.indexOf(r'$');
      final url = (dollar < 0 ? candidate : candidate.substring(0, dollar))
          .trim();
      if (!_looksLikeStreamUrl(url)) continue;
      final label = dollar < 0 ? '' : candidate.substring(dollar + 1).trim();
      channels.add(
        Channel(
          name: label.isEmpty ? name : '$name ($label)',
          url: url,
          group: group,
        ),
      );
    }
  }
  return channels;
}

String _nameFromExtInf(String line) {
  final comma = line.lastIndexOf(',');
  if (comma < 0 || comma == line.length - 1) return 'Untitled Channel';
  return line.substring(comma + 1).trim();
}

String? _attrFromExtInf(String line, String name) {
  final quoted = RegExp(
    '$name="([^"]*)"',
    caseSensitive: false,
  ).firstMatch(line);
  if (quoted != null) return quoted.group(1);
  final singleQuoted = RegExp(
    "$name='([^']*)'",
    caseSensitive: false,
  ).firstMatch(line);
  if (singleQuoted != null) return singleQuoted.group(1);
  final bare = RegExp(
    '$name=([^\\s,]+)',
    caseSensitive: false,
  ).firstMatch(line);
  return bare?.group(1);
}

String newSourceId() => DateTime.now().microsecondsSinceEpoch.toString();

/// Playlist download failure with a clean, user-facing message (no
/// "Exception:" prefix when interpolated into status text).
class PlaylistFetchException implements Exception {
  const PlaylistFetchException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Fetches and decodes an online playlist with a hard timeout, so a stalled
/// connection (dead server, bad proxy, flaky network) fails visibly instead
/// of leaving refresh spinners running forever.
Future<String> fetchPlaylistText(
  String url, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final http.Response response;
  try {
    response = await http.get(Uri.parse(url)).timeout(timeout);
  } on TimeoutException {
    throw const PlaylistFetchException('Connection timed out');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw PlaylistFetchException('HTTP ${response.statusCode}');
  }
  return decodeHttpPlaylist(response);
}

Future<String> decodeHttpPlaylist(http.Response response) async {
  final contentType = response.headers['content-type'] ?? '';
  final charset = RegExp(
    r'charset=([^;\s]+)',
    caseSensitive: false,
  ).firstMatch(contentType)?.group(1);
  if (charset != null && charset.trim().isNotEmpty) {
    return decodePlaylistBytes(response.bodyBytes, preferredCharset: charset);
  }
  return decodePlaylistBytes(response.bodyBytes);
}

Future<String> decodePlaylistBytes(
  List<int> bytes, {
  String? preferredCharset,
}) async {
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }

  final charsets = <String>[
    ?preferredCharset,
    'utf-8',
    'gb18030',
    'gbk',
    'big5',
  ];

  for (final charset in charsets) {
    final decoded = await _tryDecodeWithCharset(bytes, charset);
    if (decoded != null && !decoded.contains('\uFFFD')) {
      return decoded;
    }
  }

  return utf8.decode(bytes, allowMalformed: true);
}

Future<String?> _tryDecodeWithCharset(List<int> bytes, String charset) async {
  try {
    if (charset.toLowerCase().replaceAll('_', '-') == 'utf-8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    return CharsetConverter.decode(charset, Uint8List.fromList(bytes));
  } catch (_) {
    return null;
  }
}
