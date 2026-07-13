import 'dart:async';

import 'package:flutter/foundation.dart';

import '../constants.dart';
import '../models/playlist.dart';
import 'sources_controller.dart';

/// Owns UI navigation state: which source is open (as a list vs. player page),
/// the active group filter, and the search query. Also memoises the visible
/// channel list so high-frequency playback rebuilds don't re-filter it.
class UiController extends ChangeNotifier {
  UiController({required SourcesController sources})
    // Constructor also wires stream subscriptions, so a plain initializing
    // formal isn't sufficient here.
    // ignore: prefer_initializing_formals
    : _sources = sources {
    _replacedSub = _sources.onSourceReplaced.listen(_onSourceReplaced);
    _removedSub = _sources.onSourceRemoved.listen(_onSourceRemoved);
  }

  final SourcesController _sources;
  StreamSubscription<PlaylistSource>? _replacedSub;
  StreamSubscription<String>? _removedSub;

  PlaylistSource? activeSource;
  PlaylistSource? playerSource;
  String activeGroup = allChannels;
  String search = '';

  // Id of a throwaway source created by the Ctrl+V "paste and play" flow. It is
  // deleted automatically once the user leaves the player and returns to the
  // sources list, so quick pastes never accumulate in the saved sources.
  String? temporarySourceId;

  @override
  void dispose() {
    _replacedSub?.cancel();
    _removedSub?.cancel();
    super.dispose();
  }

  void _onSourceReplaced(PlaylistSource source) {
    var changed = false;
    if (activeSource?.id == source.id) {
      activeSource = source;
      changed = true;
    }
    if (playerSource?.id == source.id) {
      playerSource = source;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _onSourceRemoved(String id) {
    var changed = false;
    if (activeSource?.id == id) {
      activeSource = null;
      changed = true;
    }
    if (playerSource?.id == id) {
      playerSource = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void openSource(PlaylistSource source) {
    activeSource = source;
    playerSource = source;
    activeGroup = allChannels;
    search = '';
    notifyListeners();
  }

  /// Opens a throwaway source (from the Ctrl+V paste flow) and records its id so
  /// it can be discarded when the user returns to the sources list.
  void openTemporarySource(PlaylistSource source) {
    temporarySourceId = source.id;
    openSource(source);
  }

  void showSourcesPage() {
    activeSource = null;
    notifyListeners();
  }

  void setSearch(String value) {
    if (search == value) return;
    search = value;
    notifyListeners();
  }

  void setGroup(String group) {
    if (activeGroup == group) return;
    activeGroup = group;
    notifyListeners();
  }

  // Cache of the last group/search filter so the potentially huge channel
  // filter (and the downstream duplicate-name scan) doesn't rerun on every
  // rebuild. Returns the same list instance until the inputs actually change,
  // which also lets the channel list skip its rescan via its identical() guard.
  List<Channel> _visibleChannelsCache = const [];
  String? _visibleChannelsKey;

  List<Channel> visibleChannels(PlaylistSource source) {
    final key =
        '${source.id}|${identityHashCode(source.channels)}|$activeGroup|$search';
    if (key == _visibleChannelsKey) return _visibleChannelsCache;
    final query = search.trim().toLowerCase();
    final filtered = source.channels.where((channel) {
      final matchesGroup =
          activeGroup == allChannels || channel.group == activeGroup;
      final matchesSearch =
          query.isEmpty || channel.name.toLowerCase().contains(query);
      return matchesGroup && matchesSearch;
    }).toList();
    _visibleChannelsKey = key;
    _visibleChannelsCache = filtered;
    return filtered;
  }
}
