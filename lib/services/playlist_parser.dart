import 'dart:convert';
import 'dart:typed_data';

import 'package:charset_converter/charset_converter.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../models/playlist.dart';

List<Channel> parsePlaylist(String text) {
  final lines = const LineSplitter()
      .convert(text)
      .map((line) => line.trim())
      .toList();
  final channels = <Channel>[];
  var pendingName = '';
  var pendingGroup = ungroupedGroup;
  String? pendingLogo;
  String? extGrp;
  String? pendingManifestType;
  String? pendingLicenseType;
  String? pendingLicenseKey;

  void resetPending() {
    pendingName = '';
    pendingGroup = ungroupedGroup;
    pendingLogo = null;
    extGrp = null;
    pendingManifestType = null;
    pendingLicenseType = null;
    pendingLicenseKey = null;
  }

  for (final line in lines) {
    if (line.isEmpty || line == '#EXTM3U') continue;
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
          manifestType: pendingManifestType,
          licenseType: pendingLicenseType,
          licenseKey: pendingLicenseKey,
        ),
      );
      resetPending();
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
