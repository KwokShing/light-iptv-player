import 'dart:async';

import 'package:flutter/foundation.dart';

/// Severity of a captured log line, mirroring mpv's log levels loosely.
enum DebugLogLevel { info, warn, error }

class DebugLogEntry {
  DebugLogEntry({
    required this.time,
    required this.level,
    required this.source,
    required this.message,
  });

  final DateTime time;
  final DebugLogLevel level;
  final String source; // e.g. 'mpv', 'app', 'epg'
  final String message;

  /// How many times this line arrived back-to-back. A decoder or demuxer that
  /// repeats one warning thousands of times would otherwise evict everything
  /// else from the buffer and leave nothing useful to read.
  int repeats = 1;
}

/// App-wide, in-memory ring buffer of diagnostic log lines (mpv output, player
/// status messages, EPG loads, etc.), surfaced in the debug log panel.
///
/// A single shared instance is used so any part of the app can append without
/// threading a controller through the widget tree. Capped so a long session
/// can't grow memory unbounded.
///
/// Appending is deliberately cheap and decoupled from the UI: notifications are
/// coalesced onto a timer and the immutable snapshot handed to listeners is
/// rebuilt once per notification. Notifying per line instead made an open panel
/// rebuild (and re-copy the whole buffer) for every line, which a chatty stream
/// turned into a frozen UI thread.
class DebugLogService extends ChangeNotifier {
  DebugLogService._();

  static final DebugLogService instance = DebugLogService._();

  static const int _maxEntries = 2000;

  /// How far past [_maxEntries] the buffer is allowed to grow before it is
  /// trimmed back. Trimming in batches keeps the cost of a single line
  /// amortised: `removeRange` on the front of a `List` shifts every remaining
  /// element, so trimming on every line once full is O(_maxEntries) per line.
  static const int _trimSlack = 256;

  /// Listeners repaint a panel full of selectable text, so notify at a rate a
  /// human can actually read instead of once per line.
  static const Duration _notifyInterval = Duration(milliseconds: 120);

  final List<DebugLogEntry> _entries = [];

  List<DebugLogEntry> _snapshot = const [];
  bool _snapshotStale = true;
  Timer? _notifyTimer;

  /// Immutable view of the buffer.
  ///
  /// The snapshot is rebuilt only when listeners are notified, so reading this
  /// repeatedly inside one build is free, and an index into it stays valid for
  /// the whole frame even while new lines keep arriving in the background.
  List<DebugLogEntry> get entries {
    if (_snapshotStale) {
      _snapshot = List<DebugLogEntry>.unmodifiable(_entries);
      _snapshotStale = false;
    }
    return _snapshot;
  }

  bool get isEmpty => _entries.isEmpty;

  void add(
    String message, {
    DebugLogLevel level = DebugLogLevel.info,
    String source = 'app',
  }) {
    // Collapse an immediately repeated line into a counter on the existing
    // entry instead of appending a near-duplicate.
    final last = _entries.isEmpty ? null : _entries.last;
    if (last != null &&
        last.message == message &&
        last.source == source &&
        last.level == level) {
      last.repeats++;
      _scheduleNotify();
      return;
    }
    _entries.add(
      DebugLogEntry(
        time: DateTime.now(),
        level: level,
        source: source,
        message: message,
      ),
    );
    if (_entries.length > _maxEntries + _trimSlack) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    _scheduleNotify();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _flushNotify();
  }

  /// Coalesces a burst of lines into a single notification. The first line of a
  /// burst still waits [_notifyInterval], which is imperceptible next to the
  /// slide-in animation of the panel that displays them.
  void _scheduleNotify() {
    _notifyTimer ??= Timer(_notifyInterval, _flushNotify);
  }

  void _flushNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _snapshotStale = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    super.dispose();
  }
}
