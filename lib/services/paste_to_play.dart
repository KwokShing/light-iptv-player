import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/playback_controller.dart';
import '../controllers/sources_controller.dart';
import '../controllers/ui_controller.dart';
import '../models/playlist.dart';
import 'playlist_parser.dart';

const _pasteGroup = 'Quick Test';

/// Reads a stream URL from the clipboard and returns it when it looks playable,
/// otherwise shows a snackbar and returns null.
Future<String?> _readPlayableUrl(BuildContext context) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  if (!context.mounted) return null;
  final url = data?.text?.trim() ?? '';
  final uri = Uri.tryParse(url);
  final isPlayable =
      url.isNotEmpty &&
      uri != null &&
      uri.hasScheme &&
      (uri.isScheme('http') ||
          uri.isScheme('https') ||
          uri.isScheme('rtmp') ||
          uri.isScheme('rtsp') ||
          uri.isScheme('udp') ||
          uri.isScheme('file'));
  if (!isPlayable) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Clipboard does not contain a playable URL')),
    );
    return null;
  }
  return url;
}

String _nameFor(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'Pasted URL';
  if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty) {
    return uri.pathSegments.last;
  }
  return uri.host.isNotEmpty ? uri.host : 'Pasted URL';
}

/// VLC-style Ctrl+V from the sources page: create a throwaway single-channel
/// source, open the player, and start playing it.
Future<void> pasteAndPlay(BuildContext context) async {
  final url = await _readPlayableUrl(context);
  if (url == null || !context.mounted) return;

  final name = _nameFor(url);
  final channel = Channel(name: name, url: url, group: _pasteGroup);
  final source = PlaylistSource(
    id: newSourceId(),
    name: name,
    kind: SourceKind.single,
    source: url,
    channels: [channel],
    cached: true,
  );

  final sources = context.read<SourcesController>();
  final ui = context.read<UiController>();
  final playback = context.read<PlaybackController>();
  await sources.upsert(source);
  await playback.stopPlayback();
  ui.openTemporarySource(source);
  await playback.play(channel);
}

/// Ctrl+V while already viewing the temporary paste source: swap the stream URL
/// in place and play the new channel, without leaving the player.
Future<void> pasteAndReplace(BuildContext context, PlaylistSource temp) async {
  final url = await _readPlayableUrl(context);
  if (url == null || !context.mounted) return;

  final name = _nameFor(url);
  final channel = Channel(name: name, url: url, group: _pasteGroup);
  final updated = temp.copyWith(
    name: name,
    source: url,
    channels: [channel],
    cached: true,
  );

  final sources = context.read<SourcesController>();
  final playback = context.read<PlaybackController>();
  await sources.replace(updated);
  await playback.play(channel);
}
