import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Metadata describing a GitHub release.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.zipUrl,
    required this.htmlUrl,
    required this.notes,
    required this.prerelease,
  });

  /// Release version without the leading `v` (e.g. `1.2.0`).
  final String version;

  /// Raw git tag of the release (e.g. `v1.2.0` or `dev-...`).
  final String tag;

  /// Direct download URL of the Windows zip asset.
  final String zipUrl;

  /// Web page of the release for "view details".
  final String htmlUrl;

  /// Release notes body.
  final String notes;

  /// Whether GitHub marked this release as a pre-release.
  final bool prerelease;
}

/// Handles checking GitHub for a newer release (including pre-releases) and
/// downloading the Windows zip into the application's root directory so the
/// user can extract it over the existing install.
class UpdateService {
  static const String owner = 'KwokShing';
  static const String repo = 'light-iptv-player';
  static const String assetName = 'light-iptv-player-windows-x64.zip';

  static const String _userAgent = 'light-iptv-player-updater';

  /// Fetches the most recent published release. Unlike `releases/latest`, the
  /// list endpoint includes pre-releases (our `dev-*` builds); drafts are
  /// excluded for unauthenticated requests. The first item with a Windows zip
  /// asset is the newest, since GitHub returns releases newest-first.
  static Future<ReleaseInfo?> fetchLatestRelease() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/releases?per_page=10',
    );
    final response = await http.get(
      uri,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': _userAgent,
      },
    );
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return null;
    for (final item in decoded.whereType<Map<String, dynamic>>()) {
      if (item['draft'] == true) continue;
      final info = _parseRelease(item);
      if (info != null) return info;
    }
    return null;
  }

  static ReleaseInfo? _parseRelease(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String?)?.trim() ?? '';
    if (tag.isEmpty) return null;

    String? zipUrl;
    final assets = json['assets'];
    if (assets is List) {
      for (final asset in assets.whereType<Map<String, dynamic>>()) {
        if (asset['name'] == assetName) {
          zipUrl = asset['browser_download_url'] as String?;
          break;
        }
      }
    }
    if (zipUrl == null || zipUrl.isEmpty) return null;

    return ReleaseInfo(
      version: tag.replaceFirst(RegExp(r'^v'), ''),
      tag: tag,
      zipUrl: zipUrl,
      htmlUrl: (json['html_url'] as String?) ?? '',
      notes: (json['body'] as String?) ?? '',
      prerelease: json['prerelease'] == true,
    );
  }

  /// Returns true when [remote] is a strictly higher semantic version than
  /// [current]. Pre-release and build suffixes are ignored. Non-numeric tags
  /// (such as `dev-...`) parse to 0 and therefore won't be considered newer by
  /// this method alone — tag-identity comparison is used for those instead.
  static bool isNewer(String remote, String current) {
    List<int> parse(String value) {
      final cleaned = value.trim().replaceFirst(RegExp(r'^v'), '');
      final core = cleaned.split(RegExp(r'[-+]')).first;
      return core
          .split('.')
          .map((part) => int.tryParse(part.trim()) ?? 0)
          .toList();
    }

    final r = parse(remote);
    final c = parse(current);
    final length = r.length > c.length ? r.length : c.length;
    for (var i = 0; i < length; i++) {
      final rv = i < r.length ? r[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (rv != cv) return rv > cv;
    }
    return false;
  }

  /// Downloads [url] into the application's root directory (the folder that
  /// contains the running executable), saved as [assetName], and returns the
  /// saved file. Progress is reported in 0..1 when the content length is known.
  static Future<File> download(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = _userAgent;
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw HttpException('Download failed (HTTP ${response.statusCode})');
      }

      final total = response.contentLength ?? 0;
      final installDir = File(Platform.resolvedExecutable).parent.path;
      final file = File('$installDir\\$assetName');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
      return file;
    } finally {
      client.close();
    }
  }

  /// Opens Windows Explorer with the downloaded zip selected so the user can
  /// extract it over the installation. Best-effort; failures are ignored.
  static Future<void> revealInExplorer(File file) async {
    try {
      await Process.start('explorer.exe', ['/select,${file.path}']);
    } catch (_) {}
  }
}
