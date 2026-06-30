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

  /// Downloads [url] into a fresh temporary directory, saved as [assetName],
  /// and returns the saved file. Progress is reported in 0..1 when the content
  /// length is known.
  ///
  /// The download lands in a temp folder (not next to the executable) because
  /// the running install directory is replaced wholesale during [applyUpdate].
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
      final tempDir = Directory.systemTemp.createTempSync('litv_update_');
      final file = File('${tempDir.path}\\$assetName');
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

  /// Performs an in-place upgrade, mirroring v2rayN's external-helper approach.
  ///
  /// A running `.exe` can't overwrite its own files on Windows, so this writes
  /// a small PowerShell updater to a temp folder and launches it in its own
  /// detached console window. The updater waits for this process to exit,
  /// extracts [zip] over the install directory, removes the downloaded archive,
  /// and relaunches the application.
  ///
  /// The caller is expected to quit the app immediately after this returns (see
  /// [quit]) so the updater can replace the locked files.
  static Future<void> applyUpdate(File zip) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('In-place update is only supported on Windows.');
    }

    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final ownerPid = pid;

    final script = _buildUpdaterScript(
      zipPath: zip.path,
      installDir: installDir,
      exePath: exePath,
      ownerPid: ownerPid,
    );

    final scriptDir = Directory.systemTemp.createTempSync('litv_updater_');
    final scriptFile = File('${scriptDir.path}\\apply_update.ps1');
    await scriptFile.writeAsString(script);

    // Launch the updater in its own console window, fully detached so it
    // outlives this process. `cmd /c start` spawns the new window; the updater
    // then waits for us to exit before touching any files.
    await Process.start(
      'cmd.exe',
      [
        '/c',
        'start',
        'Light IPTV Player Updater',
        'powershell.exe',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }

  /// Terminates the current process so the external updater can replace files.
  static Never quit() => exit(0);

  /// Escapes a string for safe embedding inside a single-quoted PowerShell
  /// literal (the only PowerShell escape needed there is doubling quotes).
  static String _psLiteral(String value) =>
      "'${value.replaceAll("'", "''")}'";

  static String _buildUpdaterScript({
    required String zipPath,
    required String installDir,
    required String exePath,
    required int ownerPid,
  }) {
    final zip = _psLiteral(zipPath);
    final install = _psLiteral(installDir);
    final exe = _psLiteral(exePath);

    // Robocopy flags: /E recurse incl. empty dirs, /R:10 /W:1 retry on locked
    // files (the exe may take a moment to release), quiet output. Robocopy
    // exit codes 0-7 indicate success.
    return '''
\$ErrorActionPreference = 'Stop'
\$zip     = $zip
\$install = $install
\$exe     = $exe
\$ownerPid = $ownerPid

Write-Host 'Upgrading Light IPTV Player...'

# Wait for the running app to exit, then make sure it's gone.
try { Wait-Process -Id \$ownerPid -Timeout 15 -ErrorAction SilentlyContinue } catch {}
try { Stop-Process -Id \$ownerPid -Force -ErrorAction SilentlyContinue } catch {}

for (\$i = 3; \$i -gt 0; \$i--) { Write-Host \$i; Start-Sleep -Seconds 1 }

Write-Host 'Extracting the update package...'
\$staging = Join-Path \$env:TEMP ('litv_stage_' + [guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath \$zip -DestinationPath \$staging -Force

# Support both layouts: files at the zip root, or wrapped in a single folder.
\$items = Get-ChildItem -LiteralPath \$staging
if (\$items.Count -eq 1 -and \$items[0].PSIsContainer) {
    \$source = \$items[0].FullName
} else {
    \$source = \$staging
}

Write-Host 'Replacing application files...'
robocopy \$source \$install /E /R:10 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
if (\$LASTEXITCODE -ge 8) {
    Write-Host 'Update failed while copying files. Press any key to exit...'
    \$null = \$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

Remove-Item -LiteralPath \$staging -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath \$zip -Force -ErrorAction SilentlyContinue

Write-Host 'Restarting...'
Start-Sleep -Seconds 1
Start-Process -FilePath \$exe -WorkingDirectory \$install
''';
  }
}
