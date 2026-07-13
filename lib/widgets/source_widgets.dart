import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/playlist.dart';
import '../services/playlist_parser.dart';
import '../theme.dart';
import 'common.dart';

class SourceDialogResult {
  const SourceDialogResult(this.name, this.source);
  final String name;
  final String source;
}

Future<SourceDialogResult?> showSourceDialog(
  BuildContext context, {
  required String title,
  required String urlLabel,
}) async {
  final name = TextEditingController();
  final source = TextEditingController();
  return showDialog<SourceDialogResult>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: const TextStyle(color: AppColors.textPrimary)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Name',
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: source,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: urlLabel,
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          onPressed: () {
            final nextName = name.text.trim();
            final nextSource = source.text.trim();
            if (nextName.isEmpty || nextSource.isEmpty) return;
            Navigator.pop(context, SourceDialogResult(nextName, nextSource));
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

sealed class EditSourceResult {}

class EditSourceResultName extends EditSourceResult {
  EditSourceResultName(this.name);
  final String name;
}

class EditSourceResultUrl extends EditSourceResult {
  EditSourceResultUrl(this.url, {this.name});
  final String url;
  final String? name;
}

class EditSourceResultFile extends EditSourceResult {
  EditSourceResultFile(this.path, this.channels, {this.name, this.epgUrl});
  final String path;
  final List<Channel> channels;
  final String? name;
  final String? epgUrl;
}

Future<EditSourceResult?> showEditSourceDialog(
  BuildContext context, {
  required PlaylistSource source,
}) async {
  return showDialog<EditSourceResult>(
    context: context,
    builder: (context) => _EditSourceDialog(source: source),
  );
}

class _EditSourceDialog extends StatefulWidget {
  const _EditSourceDialog({required this.source});
  final PlaylistSource source;

  @override
  State<_EditSourceDialog> createState() => _EditSourceDialogState();
}

class _EditSourceDialogState extends State<_EditSourceDialog> {
  late TextEditingController nameController;
  late TextEditingController urlController;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.source.name);
    urlController = TextEditingController(text: widget.source.source);
  }

  @override
  void dispose() {
    nameController.dispose();
    urlController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Load M3U File',
        type: FileType.custom,
        allowedExtensions: const ['m3u', 'm3u8', 'txt'],
        lockParentWindow: true,
      );
      final files = result?.files;
      if (files == null || files.isEmpty) return;
      final file = files.first;

      final bytes = await file.readAsBytes();
      final text = await decodePlaylistBytes(bytes);
      final parsed = parsePlaylist(text);
      if (parsed.channels.isEmpty) return;
      if (!mounted) return;
      Navigator.pop(
        context,
        EditSourceResultFile(
          file.path ?? file.name,
          parsed.channels,
          epgUrl: parsed.epgUrl,
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = widget.source.kind == SourceKind.local;
    return AlertDialog(
      title: const Text(
        'Edit Source',
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Name',
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
            if (!isLocal) ...[
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'URL',
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
            ],
            if (isLocal) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _pickFile,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                  ),
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Load different M3U file'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          onPressed: () {
            final name = nameController.text.trim();
            final url = urlController.text.trim();
            final nameChanged = name.isNotEmpty && name != widget.source.name;
            final urlChanged =
                !isLocal && url.isNotEmpty && url != widget.source.source;
            if (urlChanged) {
              Navigator.pop(
                context,
                EditSourceResultUrl(url, name: nameChanged ? name : null),
              );
            } else if (nameChanged) {
              Navigator.pop(context, EditSourceResultName(name));
            }
          },
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

class HeaderBrand extends StatelessWidget {
  const HeaderBrand({super.key});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 420),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLogo(size: 54),
          const SizedBox(width: 16),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Light IPTV Player',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                // Version read from the bundle instead of a hardcoded string so
                // it can never drift from pubspec.yaml.
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final version = snapshot.data?.version;
                    return Text(
                      version == null ? '' : 'v$version',
                      style: const TextStyle(color: AppColors.textMuted),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SourceTile extends StatelessWidget {
  const SourceTile({
    super.key,
    required this.source,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    this.onRefresh,
    this.isRefreshing = false,
  });

  final PlaylistSource source;
  final VoidCallback onOpen;
  final VoidCallback? onRefresh;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final bool isRefreshing;

  String get _kindLabel => switch (source.kind) {
    SourceKind.local => 'Local File',
    SourceKind.online => 'Online Link',
    SourceKind.single => 'Quick Test',
  };

  IconData get _kindIcon => switch (source.kind) {
    SourceKind.local => Icons.folder_open_rounded,
    SourceKind.online => Icons.link_rounded,
    SourceKind.single => Icons.play_circle_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        hoverColor: AppColors.surfaceMuted,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border, width: 1),
            boxShadow: cardShadow(),
          ),
          child: Row(
            children: [
              const AppLogo(size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(_kindIcon, size: 13, color: AppColors.textMuted),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            _kindLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        _Dot(),
                        Text(
                          '${source.channels.length} channels',
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        if (source.cached) ...[
                          const SizedBox(width: 8),
                          const Tag(label: 'Cached', green: true),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (onRefresh != null)
                _TileAction(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Refresh',
                  color: AppColors.textSecondary,
                  onPressed: isRefreshing ? null : onRefresh,
                  busy: isRefreshing,
                ),
              _TileAction(
                icon: Icons.edit_rounded,
                tooltip: 'Rename',
                color: AppColors.textSecondary,
                onPressed: onRename,
              ),
              _TileAction(
                icon: Icons.delete_rounded,
                tooltip: 'Delete',
                color: AppColors.danger,
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small separator dot between metadata pieces.
class _Dot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      width: 3,
      height: 3,
      decoration: const BoxDecoration(
        color: AppColors.textMuted,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Compact 32px icon action used in the source tile trailing row.
class _TileAction extends StatelessWidget {
  const _TileAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      iconSize: 18,
      splashRadius: 18,
      hoverColor: AppColors.surfaceMuted,
      tooltip: tooltip,
      color: color,
      onPressed: onPressed,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
              ),
            )
          : Icon(icon),
    );
  }
}
