import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/playlist.dart';
import '../services/playlist_parser.dart';
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
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: source,
              decoration: InputDecoration(labelText: urlLabel),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
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
  EditSourceResultFile(this.path, this.channels, {this.name});
  final String path;
  final List<Channel> channels;
  final String? name;
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
      final channels = parsePlaylist(text);
      if (channels.isEmpty) return;
      if (!mounted) return;
      Navigator.pop(
        context,
        EditSourceResultFile(file.path ?? file.name, channels),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = widget.source.kind == SourceKind.local;
    return AlertDialog(
      title: const Text('Edit Source'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            if (!isLocal) ...[
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(labelText: 'URL'),
              ),
            ],
            if (isLocal) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open),
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
          child: const Text('Cancel'),
        ),
        FilledButton(
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
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                // Version read from the bundle instead of a hardcoded string so
                // it can never drift from pubspec.yaml.
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final version = snapshot.data?.version;
                    return Text(
                      version == null ? '' : 'v$version',
                      style: const TextStyle(color: Color(0xff7d8490)),
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

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xffd9c7ff), width: 1.4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0f7c4dff),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              const AppLogo(size: 46),
              const SizedBox(width: 14),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Tag(
                      label: switch (source.kind) {
                        SourceKind.local => 'Local File',
                        SourceKind.online => 'Online Link',
                        SourceKind.single => 'Quick Test',
                      },
                    ),
                    if (source.cached) const Tag(label: 'Cached', green: true),
                    Text(
                      '${source.channels.length} channels',
                      style: const TextStyle(color: Color(0xff7d8490)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Wrap(
                spacing: 2,
                children: [
                  if (onRefresh != null)
                    IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 38,
                        height: 38,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: isRefreshing ? null : onRefresh,
                      icon: isRefreshing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  IconButton(
                    constraints: const BoxConstraints.tightFor(
                      width: 38,
                      height: 38,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: onRename,
                    icon: const Icon(Icons.edit),
                  ),
                  IconButton(
                    constraints: const BoxConstraints.tightFor(
                      width: 38,
                      height: 38,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete, color: Color(0xffe0001b)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
