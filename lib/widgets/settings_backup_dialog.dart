import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/sources_controller.dart';
import '../controllers/user_agent_controller.dart';
import '../models/playlist.dart';
import '../models/user_agent_settings.dart';
import '../theme.dart';
import 'top_bar.dart';

const _backupFormat = 'light-iptv-player-settings';
const _backupVersion = 1;
const _maxBackupBytes = 64 * 1024 * 1024;
const _maxSources = 5000;

class SettingsBackupButton extends StatelessWidget {
  const SettingsBackupButton({super.key});

  @override
  Widget build(BuildContext context) {
    return TopBarButton(
      icon: Icons.settings_backup_restore_rounded,
      label: 'Backup',
      onPressed: () => showSettingsBackupDialog(context),
    );
  }
}

Future<void> showSettingsBackupDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _SettingsBackupDialog(),
  );
}

class _SettingsBackupDialog extends StatefulWidget {
  const _SettingsBackupDialog();

  @override
  State<_SettingsBackupDialog> createState() => _SettingsBackupDialogState();
}

class _SettingsBackupDialogState extends State<_SettingsBackupDialog> {
  bool _busy = false;
  String? _feedback;
  bool _feedbackIsError = false;

  void _setFeedback(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _feedback = message;
      _feedbackIsError = error;
    });
  }

  Future<void> _exportSettings() async {
    final sources = context.read<SourcesController>();
    final userAgent = context.read<UserAgentController>();
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final backup = _SettingsBackup(
        sources: sources.savedSources,
        userAgent: userAgent.settings,
      );
      final bytes = Uint8List.fromList(utf8.encode(_encodeBackup(backup)));
      final path = await FilePicker.saveFile(
        dialogTitle: 'Export Settings',
        fileName: _defaultBackupName(),
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: bytes,
        lockParentWindow: true,
      );
      if (path != null) _setFeedback('Settings exported successfully');
    } catch (error) {
      _setFeedback('Export failed: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importSettings() async {
    final sources = context.read<SourcesController>();
    if (sources.refreshingAll || sources.refreshingSourceIds.isNotEmpty) {
      _setFeedback(
        'Wait for playlist refreshes to finish before importing',
        error: true,
      );
      return;
    }

    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Import Settings',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        lockParentWindow: true,
      );
      final files = result?.files;
      if (files == null || files.isEmpty) return;
      final file = files.first;
      if (file.size > _maxBackupBytes) {
        throw const FormatException('Backup file is larger than 64 MB');
      }
      final backup = _decodeBackup(await file.readAsBytes());
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => _ImportConfirmation(backup: backup),
      );
      if (confirmed != true || !mounted) return;

      final userAgent = context.read<UserAgentController>();
      final previousSources = List<PlaylistSource>.of(sources.savedSources);
      final previousUserAgent = userAgent.settings;
      try {
        await sources.replaceAll(backup.sources);
        await userAgent.save(backup.userAgent);
      } catch (error) {
        try {
          await sources.replaceAll(previousSources);
          await userAgent.save(previousUserAgent);
        } catch (_) {
          // Preserve the original import error; a later restart reloads the
          // last values that were successfully persisted.
        }
        rethrow;
      }
      _setFeedback(
        'Imported ${backup.sources.length} sources and User-Agent settings',
      );
    } on FormatException catch (error) {
      _setFeedback('Invalid settings file: ${error.message}', error: true);
    } catch (error) {
      _setFeedback('Import failed: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Settings Backup',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 470,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Export or restore playlist sources and User-Agent profiles in '
              'one JSON file. Proxy settings stay on this device.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfffff8e1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xffffd978)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: Color(0xff8a5a00),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'The backup may contain playlist URLs and Xtream '
                      'credentials in plain text. Store it securely.',
                      style: TextStyle(
                        color: Color(0xff6d4c00),
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _exportSettings,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('Export Settings'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _importSettings,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('Import Settings'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (_feedback != null) ...[
              const SizedBox(height: 14),
              Text(
                _feedback!,
                style: TextStyle(
                  color: _feedbackIsError ? AppColors.danger : AppColors.good,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ImportConfirmation extends StatelessWidget {
  const _ImportConfirmation({required this.backup});

  final _SettingsBackup backup;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Replace current settings?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Importing this file will replace the current configuration:',
            ),
            const SizedBox(height: 14),
            _SummaryLine(
              icon: Icons.playlist_play_rounded,
              label: '${backup.sources.length} playlist sources',
            ),
            _SummaryLine(
              icon: Icons.language_rounded,
              label: 'User-Agent: ${backup.userAgent.preset.label}',
            ),
            const SizedBox(height: 12),
            const Text(
              'Local playlist and media paths may not work on another device.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Import and Replace'),
        ),
      ],
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.accent),
          const SizedBox(width: 9),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _SettingsBackup {
  const _SettingsBackup({required this.sources, required this.userAgent});

  final List<PlaylistSource> sources;
  final UserAgentSettings userAgent;
}

String _encodeBackup(_SettingsBackup backup) {
  return '${const JsonEncoder.withIndent('  ').convert({'format': _backupFormat, 'version': _backupVersion, 'exportedAt': DateTime.now().toUtc().toIso8601String(), 'sources': backup.sources.map((source) => source.toJson()).toList(), 'userAgent': backup.userAgent.toJson()})}\n';
}

_SettingsBackup _decodeBackup(Uint8List bytes) {
  if (bytes.length > _maxBackupBytes) {
    throw const FormatException('Backup file is larger than 64 MB');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    throw const FormatException('The file is not valid UTF-8 JSON');
  }
  final root = _requireObject(decoded, 'root');
  if (root['format'] != _backupFormat) {
    throw const FormatException('Unrecognized backup format');
  }
  if (root['version'] != _backupVersion) {
    throw FormatException('Unsupported backup version: ${root['version']}');
  }

  final rawSources = root['sources'];
  if (rawSources is! List) {
    throw const FormatException('"sources" must be a list');
  }
  if (rawSources.length > _maxSources) {
    throw const FormatException('The backup contains too many sources');
  }

  final sources = <PlaylistSource>[];
  final ids = <String>{};
  for (var index = 0; index < rawSources.length; index++) {
    final item = _requireObject(rawSources[index], 'sources[$index]');
    final id = item['id'];
    if (id is! String || id.trim().isEmpty) {
      throw FormatException('sources[$index] has no valid id');
    }
    if (!ids.add(id)) {
      throw FormatException('Duplicate source id: $id');
    }
    final channels = item['channels'];
    if (channels is! List ||
        channels.any((channel) => channel is! Map<String, dynamic>)) {
      throw FormatException('sources[$index].channels must be a list');
    }
    final source = PlaylistSource.fromJson(item);
    if (source.source.trim().isEmpty) {
      throw FormatException('sources[$index] has no source URL or path');
    }
    sources.add(source);
  }

  final userAgent = UserAgentSettings.fromJson(
    _requireObject(root['userAgent'], 'userAgent'),
  );
  return _SettingsBackup(sources: sources, userAgent: userAgent);
}

Map<String, dynamic> _requireObject(Object? value, String name) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('"$name" must be an object');
}

String _defaultBackupName() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'light-iptv-player-settings-'
      '${now.year}-${two(now.month)}-${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}.json';
}
