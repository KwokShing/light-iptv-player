import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Metadata describing the latest published GitHub release.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.zipUrl,
    required this.htmlUrl,
    required this.notes,
  });

  /// Release version without the leading `v` (e.g. `1.2.0`).
  final String version;

  /// Raw git tag of the release (e.g. `v1.2.0`).
  final String tag;

  /// Direct download URL of the Windows zip asset.
  final String zipUrl;

  /// Web page of the release for "view details".
  final String htmlUrl;

  /// Release notes body.
  final String notes;
}

/// Handles checking GitHub for a newer release, downloading it, and swapping
/// the running installation in place via a detached PowerShell helper.
class UpdateService {
  static const String owner = 'KwokShing';
  static const String repo = 'light-iptv-player';
  static const String assetName = 'light-iptv-player-windows-x64.zip';

  static const String _userAgent = 'light-iptv-player-updater';

  /// Fetches the latest non-prerelease release. The GitHub `releases/latest`
  /// endpoint already excludes drafts and prereleases (such as our `dev-*`
  /// tags), so only official `v*` releases are considered.
  static Future<ReleaseInfo?> fetchLatestRelease() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/releases/latest',
    );
    final response = await http.get(
      uri,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': _userAgent,
      },
    );
    if (response.statusCode != 200) return null;

    final json = jsonDecode(response.body) as Map<String, dynamic>;
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
    );
  }

  /// Returns true when [remote] is a strictly higher semantic version than
  /// [current]. Pre-release and build suffixes are ignored.
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

  /// Downloads [url] to a temp file, reporting progress in 0..1 when the
  /// content length is known.
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
      final file = File('${Directory.systemTemp.path}\\$assetName');
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

  /// Writes a detached PowerShell script that waits for this process to exit,
  /// overwrites the install directory with the downloaded zip contents, and
  /// relaunches the app. Then quits the current app so files can be replaced.
  static Future<void> applyAndRestart(File zip) async {
    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final scriptPath =
        '${Directory.systemTemp.path}\\light-iptv-player-update.ps1';

    await File(scriptPath).writeAsString(_updaterScript);

    await Process.start('powershell.exe', [
      '-ExecutionPolicy',
      'Bypass',
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-File',
      scriptPath,
      '-AppPid',
      '$pid',
      '-Zip',
      zip.path,
      '-Dest',
      installDir,
      '-Exe',
      exePath,
    ], mode: ProcessStartMode.detached);

    // Give the detached process a moment to spin up before we exit.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  static const String _updaterScript = r'''
param(
  [int]$AppPid,
  [string]$Zip,
  [string]$Dest,
  [string]$Exe
)

$ErrorActionPreference = 'SilentlyContinue'

# Wait for the running app to fully exit so its files are no longer locked.
try { Wait-Process -Id $AppPid -Timeout 30 } catch {}
Start-Sleep -Milliseconds 800

$extract = Join-Path $env:TEMP 'light-iptv-player-update-extract'
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }

# Expand the downloaded zip and copy its contents over the install directory.
Expand-Archive -Path $Zip -DestinationPath $extract -Force
Copy-Item -Path (Join-Path $extract '*') -Destination $Dest -Recurse -Force

# Clean up temporary files.
Remove-Item -Recurse -Force $extract
Remove-Item -Force $Zip

# Relaunch the updated app.
Start-Process -FilePath $Exe

# Remove this script.
Remove-Item -Force $MyInvocation.MyCommand.Path
''';
}
