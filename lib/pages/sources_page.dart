import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../controllers/playback_controller.dart';
import '../controllers/proxy_controller.dart';
import '../controllers/sources_controller.dart';
import '../controllers/ui_controller.dart';
import '../controllers/update_controller.dart';
import '../models/playlist.dart';
import '../services/playlist_parser.dart';
import '../theme.dart';
import '../widgets/proxy_dialog.dart';
import '../widgets/source_widgets.dart';
import '../widgets/top_bar.dart';

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
    final proxy = context.watch<ProxyController>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          TopBar(
            title: 'Light IPTV Player',
            subtitle: '${sources.sources.length} sources',
            showLogo: false,
            trailing: [
              _AddSourceButton(
                onLocal: () => _addLocalSource(context),
                onOnline: () => _addOnlineSource(context),
                onSingle: () => _addSingleChannel(context),
              ),
              const SizedBox(width: 10),
              TopBarButton(
                icon: Icons.refresh_rounded,
                label: 'Refresh All',
                busy: sources.refreshingAll,
                onPressed: sources.refreshingAll ? null : sources.refreshAll,
              ),
              const SizedBox(width: 10),
              TopBarButton(
                icon: proxy.settings.active
                    ? Icons.vpn_lock_rounded
                    : Icons.public_rounded,
                label: proxy.settings.active ? 'Proxy On' : 'Proxy',
                onPressed: () => showProxyDialog(context),
              ),
            ],
          ),
          if (update.availableUpdate != null) ...[
            const SizedBox(height: 12),
            _UpdateBanner(update: update),
          ],
          Expanded(
            child: sources.sources.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.accentSoft,
                            border: Border.all(color: AppColors.accentBorder),
                          ),
                          child: const Icon(
                            Icons.playlist_add_rounded,
                            color: AppColors.accent,
                            size: 30,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Create a source to start watching.',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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

/// "+ Add Source" primary button with a dropdown of the three source kinds.
class _AddSourceButton extends StatelessWidget {
  const _AddSourceButton({
    required this.onLocal,
    required this.onOnline,
    required this.onSingle,
  });

  final VoidCallback onLocal;
  final VoidCallback onOnline;
  final VoidCallback onSingle;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Add a source',
      position: PopupMenuPosition.under,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      onSelected: (value) {
        switch (value) {
          case 0:
            onLocal();
          case 1:
            onOnline();
          case 2:
            onSingle();
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 0,
          child: _AddMenuRow(
            icon: Icons.folder_open_rounded,
            label: 'Load M3U File',
          ),
        ),
        PopupMenuItem(
          value: 1,
          child: _AddMenuRow(icon: Icons.link_rounded, label: 'Online M3U Link'),
        ),
        PopupMenuItem(
          value: 2,
          child: _AddMenuRow(
            icon: Icons.play_circle_outline_rounded,
            label: 'Single Channel',
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 18, color: Colors.white),
            SizedBox(width: 8),
            Text(
              'Add Source',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
            SizedBox(width: 4),
            Icon(Icons.arrow_drop_down_rounded, size: 20, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _AddMenuRow extends StatelessWidget {
  const _AddMenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.accent),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
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
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.system_update_rounded, color: AppColors.accent),
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
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (updating && updateProgress != null) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: updateProgress,
                      backgroundColor: AppColors.border,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.accent,
                      ),
                    ),
                  ),
                ] else if (!updating)
                  const Text(
                    'The update zip will be saved to the app folder for you to install.',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (updating)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
              ),
            )
          else ...[
            TextButton(
              onPressed: update.dismiss,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
              ),
              child: const Text('Later'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: update.startUpdate,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.download_rounded),
              label: const Text('Download'),
            ),
          ],
        ],
      ),
    );
  }
}
