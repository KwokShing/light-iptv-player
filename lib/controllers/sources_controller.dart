import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/playlist.dart';
import '../services/playlist_parser.dart';
import '../services/xtream_service.dart';

/// Owns the list of playlist sources and their persistence, plus all
/// add/rename/delete/refresh operations. UI-facing status text is surfaced via
/// [messages]; callers that also track an "open" source (see UiController) can
/// react to individual sources changing through [onSourceReplaced] /
/// [onSourceRemoved].
class SourcesController extends ChangeNotifier {
  List<PlaylistSource> _sources = [];
  List<PlaylistSource> get sources => _sources;

  bool _refreshingAll = false;
  bool get refreshingAll => _refreshingAll;

  Set<String> _refreshingSourceIds = const {};
  Set<String> get refreshingSourceIds => _refreshingSourceIds;

  bool _loaded = false;
  bool get loaded => _loaded;

  // Id of an in-memory-only source (the Ctrl+V "paste and play" throwaway). It
  // participates in the live [sources] list so the UI can show/play it, but is
  // deliberately excluded from persistence so it never survives an app restart
  // or leaks into the saved list if the user leaves without pressing home.
  String? _ephemeralId;

  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  // Notified with the up-to-date source whenever an existing source is
  // replaced (rename/refresh/edit), and with the id whenever one is removed,
  // so the UI layer can keep any "open" source in sync.
  final _replaced = StreamController<PlaylistSource>.broadcast();
  Stream<PlaylistSource> get onSourceReplaced => _replaced.stream;
  final _removed = StreamController<String>.broadcast();
  Stream<String> get onSourceRemoved => _removed.stream;

  void _message(String text) => _messages.add(text);

  @override
  void dispose() {
    _messages.close();
    _replaced.close();
    _removed.close();
    super.dispose();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(sourcesStorageKey);
    _sources = raw == null
        ? <PlaylistSource>[]
        : (jsonDecode(raw) as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(PlaylistSource.fromJson)
              .toList();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      sourcesStorageKey,
      jsonEncode(
        _sources
            .where((source) => source.id != _ephemeralId)
            .map((source) => source.toJson())
            .toList(),
      ),
    );
  }

  // Fetch and parse a source's channels from its origin. Network/file I/O runs
  // on the main isolate (CharsetConverter uses platform channels and can't run
  // in a background isolate), but the CPU-heavy M3U parse is offloaded via
  // `compute` so it never janks the UI. Throws on failure.
  Future<ParsedPlaylist> _fetchChannels(PlaylistSource source) async {
    if (source.kind == SourceKind.local) {
      final text = await decodePlaylistBytes(
        await File(source.source).readAsBytes(),
      );
      return compute(parsePlaylist, text);
    }
    if (source.kind == SourceKind.xtream) {
      final url = xtreamPlaylistUrl(
        source.source,
        source.xtreamUsername ?? '',
        source.xtreamPassword ?? '',
      );
      final text = await fetchPlaylistText(url);
      final parsed = await compute(parsePlaylist, text);
      // Xtream panels serve their guide from `xmltv.php`; use it when the M3U
      // header didn't declare its own `url-tvg`.
      if (parsed.epgUrl == null &&
          (source.xtreamUsername?.isNotEmpty ?? false)) {
        return ParsedPlaylist(
          channels: parsed.channels,
          epgUrl: xtreamEpgUrl(
            source.source,
            source.xtreamUsername!,
            source.xtreamPassword ?? '',
          ),
        );
      }
      return parsed;
    }
    final text = await fetchPlaylistText(source.source);
    return compute(parsePlaylist, text);
  }

  Future<void> upsert(PlaylistSource source) async {
    _sources = [source, ..._sources];
    notifyListeners();
    await _save();
  }

  // Insert the in-memory-only paste source. It shows up in [sources] and can be
  // played immediately, but is not written to disk (see [_save]). Any previous
  // ephemeral source is dropped first so only one is ever live.
  void upsertTemporary(PlaylistSource source) {
    _sources = [
      source,
      ..._sources.where((item) => item.id != _ephemeralId),
    ];
    _ephemeralId = source.id;
    notifyListeners();
  }

  // Swap the live ephemeral source in place (Ctrl+V while viewing it). Stays
  // in memory only.
  void replaceTemporary(PlaylistSource source) {
    _ephemeralId = source.id;
    _sources = _sources
        .map((item) => item.id == source.id ? source : item)
        .toList();
    notifyListeners();
    _replaced.add(source);
  }

  // Drop the live ephemeral source without touching disk. No-op if there is
  // none (e.g. the user already saved it via some other flow).
  void discardTemporary() {
    final id = _ephemeralId;
    if (id == null) return;
    _ephemeralId = null;
    if (_sources.every((item) => item.id != id)) return;
    _sources = _sources.where((item) => item.id != id).toList();
    notifyListeners();
    _removed.add(id);
  }

  // Promote the live ephemeral paste source into a permanent, persisted source
  // so it survives leaving the player and app restarts. No-op if there is none.
  Future<void> keepTemporary() async {
    if (_ephemeralId == null ||
        _sources.every((item) => item.id != _ephemeralId)) {
      return;
    }
    _ephemeralId = null;
    await _save();
  }

  Future<void> replace(PlaylistSource source) async {
    _sources = _sources
        .map((item) => item.id == source.id ? source : item)
        .toList();
    notifyListeners();
    _replaced.add(source);
    await _save();
  }

  Future<void> delete(PlaylistSource source) async {
    _sources = _sources.where((item) => item.id != source.id).toList();
    notifyListeners();
    _removed.add(source.id);
    await _save();
  }

  Future<void> refreshOne(PlaylistSource source) async {
    if (_refreshingSourceIds.contains(source.id)) return;
    _refreshingSourceIds = {..._refreshingSourceIds, source.id};
    notifyListeners();
    try {
      final parsed = await _fetchChannels(source);
      await replace(
        source.copyWith(
          channels: parsed.channels,
          cached: true,
          epgUrl: parsed.epgUrl,
        ),
      );
    } catch (error) {
      _message('Update failed for "${source.name}": $error');
    } finally {
      _refreshingSourceIds = {..._refreshingSourceIds}..remove(source.id);
      notifyListeners();
    }
  }

  // Refresh every reloadable playlist (local + online) in one go. Single
  // channels have no upstream to refresh and are skipped. Fetches run
  // concurrently and state is written (and persisted) once at the end, so the
  // list doesn't rebuild repeatedly mid-run.
  Future<void> refreshAll() async {
    if (_refreshingAll) return;
    final reloadable = _sources
        .where(
          (source) =>
              source.kind != SourceKind.single &&
              source.kind != SourceKind.media,
        )
        .toList();
    if (reloadable.isEmpty) {
      _message('No playlists to refresh');
      return;
    }
    _refreshingAll = true;
    notifyListeners();

    Future<({String id, String name, ParsedPlaylist? parsed})> refreshOne(
      PlaylistSource source,
    ) async {
      try {
        final parsed = await _fetchChannels(source);
        return (id: source.id, name: source.name, parsed: parsed);
      } catch (_) {
        return (id: source.id, name: source.name, parsed: null);
      }
    }

    final results = await Future.wait(reloadable.map(refreshOne));

    final updates = <String, ParsedPlaylist>{};
    var succeeded = 0;
    final failures = <String>[];
    for (final result in results) {
      if (result.parsed != null) {
        updates[result.id] = result.parsed!;
        succeeded++;
      } else {
        failures.add(result.name);
      }
    }

    PlaylistSource apply(PlaylistSource source) {
      final parsed = updates[source.id];
      return parsed == null
          ? source
          : source.copyWith(
              channels: parsed.channels,
              cached: true,
              epgUrl: parsed.epgUrl,
            );
    }

    _sources = _sources.map(apply).toList();
    _refreshingAll = false;
    notifyListeners();
    // Keep any open source in sync with the refreshed data.
    for (final source in _sources) {
      if (updates.containsKey(source.id)) _replaced.add(source);
    }
    await _save();

    // Only surface a bottom message when something failed; a success banner
    // popping in right as the list rebuilds caused a visible frame hitch.
    if (failures.isNotEmpty) {
      _message(
        'Refreshed $succeeded, failed ${failures.length}: '
        '${failures.join(', ')}',
      );
    }
  }
}
