import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../update_service.dart';

/// Owns the auto-update lifecycle: checking GitHub for a newer release,
/// downloading it, and handing off to the external updater. UI-facing status
/// text is surfaced via [messages].
class UpdateController extends ChangeNotifier {
  ReleaseInfo? _availableUpdate;
  ReleaseInfo? get availableUpdate => _availableUpdate;

  bool _updating = false;
  bool get updating => _updating;

  double? _updateProgress;
  double? get updateProgress => _updateProgress;

  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  @override
  void dispose() {
    _messages.close();
    super.dispose();
  }

  void dismiss() {
    _availableUpdate = null;
    notifyListeners();
  }

  Future<void> checkForUpdate() async {
    // Updating in place is only implemented for the Windows build.
    if (!Platform.isWindows) return;
    try {
      final release = await UpdateService.fetchLatestRelease();
      if (release == null) return;

      final prefs = await SharedPreferences.getInstance();
      final currentTag = releaseTag.isNotEmpty
          ? releaseTag
          : (prefs.getString(installedTagStorageKey) ?? '');

      final bool isUpdate;
      if (currentTag.isNotEmpty) {
        // We know exactly which release we're running; the list endpoint
        // returns the newest release first, so anything different is an update.
        isUpdate = release.tag != currentTag;
      } else {
        // Unknown build identity (e.g. a build made before this feature):
        // fall back to semantic version comparison for proper releases, and
        // always surface pre-releases since their tags aren't semver.
        final info = await PackageInfo.fromPlatform();
        isUpdate = release.prerelease
            ? true
            : UpdateService.isNewer(release.version, info.version);
      }

      if (isUpdate) {
        _availableUpdate = release;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('Update check failed: $error');
    }
  }

  Future<void> startUpdate() async {
    final release = _availableUpdate;
    if (release == null || _updating) return;
    _updating = true;
    _updateProgress = null;
    notifyListeners();
    try {
      final zip = await UpdateService.download(
        release.zipUrl,
        onProgress: (progress) {
          _updateProgress = progress;
          notifyListeners();
        },
      );
      _updateProgress = null;
      notifyListeners();
      _messages.add('Update downloaded. Restarting to apply...');

      // Hand off to the external updater (its own console window), then quit so
      // it can replace the locked application files and relaunch us.
      await UpdateService.applyUpdate(zip);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      UpdateService.quit();
    } catch (error) {
      _updating = false;
      notifyListeners();
      _messages.add('Update failed: $error');
    }
  }
}
