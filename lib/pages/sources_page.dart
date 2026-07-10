import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../controllers/playback_controller.dart';
import '../controllers/sources_controller.dart';
import '../controllers/ui_controller.dart';
import '../controllers/update_controller.dart';
import '../models/playlist.dart';
import '../services/playlist_parser.dart';
import '../widgets/source_widgets.dart';

class SourcesPage extends StatelessWidget {
  const SourcesPage({super.key});

  void _showMessage(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addLocalSource(BuildContext context) async {
    final sources = context.read<SourcesController>();
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Load M3U File',
        type: FileType.custom,
        allowedExtensions: const ['m3u', 'm3u8', 'txt'],
        lockParentWindow: true,
      );
      final files = result?.files;
      if (files == null || files.isEmpty) {
        if (context.mounted) _showMessage(context, 'File selection cancelled');
        return;
      }
      final file = files.first;

      final bytes = await file.readAsBytes();
      final text = await decodePlaylistBytes(bytes);
      final channels = parsePlaylist(text);
      if (channels.isEmpty) {
        if (context.mounted) {
          _showMessage(context, 'No channels found in ${file.name}');
        }
        return;
      }

      final fileName = file.name.replaceAll(
        RegExp(r'\.m3u8?$|\.txt$', caseSensitive: false),
        '',
      );
      await sources.upsert(
        PlaylistSource(
          id: newSourceId(),
          name: fileName.isEmpty ? 'Local Playlist' : fileName,
          kind: SourceKind.local,
          source: file.path ?? file.name,
          channels: channels,
          cached: true,
        ),
      );
      if (context.mounted) {
        _showMessage(context, 'Loaded ${channels.length} channels');
      }
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'Failed to load M3U file: $error');
      }
    }
  }

  Future<void> _addOnlineSource(BuildContext context) async {
    final sources = context.read<SourcesController>();
    final values = await showSourceDialog(
      context,
      title: 'Online M3U Link',
      urlLabel: 'URL',
    );
    if (values == null) return;
    try {
      final response = await http.get(Uri.parse(values.source));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (context.mounted) {
          _showMessage(
            context,
            'Failed to load playlist: HTTP ${response.statusCode}',
          );
        }
        return;
      }
      final text = await decodeHttpPlaylist(response);
      await sources.upsert(
        PlaylistSource(
          id: newSourceId(),
          name: values.name,
          kind: SourceKind.online,
          source: values.source,
          channels: parsePlaylist(text),
          cached: true,
        ),
      );
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'Failed to load playlist: $error');
      }
    }
  }

  Future<void> _addSingleChannel(BuildContext context) async {
    final sources = context.read<SourcesController>();
    final values = await showSourceDialog(
      context,
      title: 'Single Channel',
      urlLabel: 'Stream URL',
    );
    if (values == null) return;
    await sources.upsert(
      PlaylistSource(
        id: newSourceId(),
        name: values.name,
        kind: SourceKind.single,
        source: values.source,
        channels: [
          Channel(name: values.name, url: values.source, group: 'Quick Test'),
        ],
        cached: true,
      ),
    );
  }

  Future<void> _renameSource(BuildContext context, PlaylistSource source) async {
    final sources = context.read<SourcesController>();
    final result = await showEditSourceDialog(context, source: source);
    if (result == null) return;
    switch (result) {
      case EditSourceResultName(:final name):
        await sources.replace(source.copyWith(name: name));
      case EditSourceResultUrl(:final url, :final name):
        final updatedSource = name != null ? source.copyWith(name: name) : source;
        if (updatedSource.kind == SourceKind.single) {
          await sources.replace(
            updatedSource.copyWith(
              source: url,
              channels: [
                Channel(
                  name: updatedSource.name,
                  url: url,
                  group: 'Quick Test',
                ),
              ],
              cached: true,
            ),
          );
        } else if (updatedSource.kind == SourceKind.online) {
          try {
            final response = await http.get(Uri.parse(url));
            if (response.statusCode < 200 || response.statusCode >= 300) {
              if (context.mounted) {
                _showMessage(
                  context,
                  'Failed to load playlist: HTTP ${response.statusCode}',
                );
              }
              return;
            }
            final text = await decodeHttpPlaylist(response);
            await sources.replace(
              updatedSource.copyWith(
                source: url,
                channels: parsePlaylist(text),
                cached: true,
              ),
            );
          } catch (error) {
            if (context.mounted) {
              _showMessage(context, 'Failed to load URL: $error');
            }
          }
        }
      case EditSourceResultFile(:final path, :final channels):
        await sources.replace(
          source.copyWith(source: path, channels: channels, cached: true),
        );
    }
  }

  Future<void> _deleteSource(BuildContext context, PlaylistSource source) async {
    final sources = context.read<SourcesController>();
    final ui = context.read<UiController>();
    final playback = context.read<PlaybackController>();
    final deletingOpenSource =
        ui.activeSource?.id == source.id || ui.playerSource?.id == source.id;
    if (deletingOpenSource) {
      await playback.stopPlayback();
    }
    await sources.delete(source);
  }

  Future<void> _openSource(BuildContext context, PlaylistSource source) async {
    final ui = context.read<UiController>();
    final playback = context.read<PlaybackController>();
    if (ui.activeSource?.id != source.id || playback.nowPlaying != null) {
      await playback.stopPlayback();
    }
    ui.openSource(source);
  }

  @override
  Widget build(BuildContext context) {
    final sources = context.watch<SourcesController>();
    final update = context.watch<UpdateController>();
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
            child: Row(
              children: [
                const HeaderBrand(),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: () => _addLocalSource(context),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Load M3U File'),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: () => _addOnlineSource(context),
                  icon: const Icon(Icons.link),
                  label: const Text('Online M3U Link'),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: () => _addSingleChannel(context),
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Single Channel'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: sources.refreshingAll ? null : sources.refreshAll,
                  icon: SizedBox(
                    width: 18,
                    height: 18,
                    child: Center(
                      child: sources.refreshingAll
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                    ),
                  ),
                  label: const Text('Refresh All'),
                ),
              ],
            ),
          ),
          if (update.availableUpdate != null) _UpdateBanner(update: update),
          Expanded(
            child: sources.sources.isEmpty
                ? const Center(
                    child: Text(
                      'Create a source to start watching.',
                      style: TextStyle(color: Color(0xff7d8490)),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                    itemBuilder: (context, index) {
                      final source = sources.sources[index];
                      return SourceTile(
                        source: source,
                        onOpen: () => _openSource(context, source),
                        onRefresh: source.kind == SourceKind.single
                            ? null
                            : () => sources.refreshOne(source),
                        isRefreshing: sources.refreshingSourceIds.contains(
                          source.id,
                        ),
                        onRename: () => _renameSource(context, source),
                        onDelete: () => _deleteSource(context, source),
                      );
                    },
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemCount: sources.sources.length,
                  ),
          ),
        ],
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.update});
  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    final release = update.availableUpdate!;
    final updating = update.updating;
    final updateProgress = update.updateProgress;
    final progressPercent = updateProgress == null
        ? null
        : (updateProgress * 100).clamp(0, 100).toStringAsFixed(0);
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xffeef0ff),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xffc7c2ff)),
      ),
      child: Row(
        children: [
          const Icon(Icons.system_update, color: Color(0xff6b5bff)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  updating
                      ? (progressPercent == null
                            ? 'Downloading update...'
                            : 'Downloading update... $progressPercent%')
                      : 'New version ${release.tag} available',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (updating && updateProgress != null) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: updateProgress),
                  ),
                ] else if (!updating)
                  const Text(
                    'The update zip will be saved to the app folder for you to install.',
                    style: TextStyle(color: Color(0xff7d8490), fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (updating)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            TextButton(
              onPressed: update.dismiss,
              child: const Text('Later'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: update.startUpdate,
              icon: const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ],
        ],
      ),
    );
  }
}
