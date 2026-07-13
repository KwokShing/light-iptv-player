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
}

/// App-wide, in-memory ring buffer of diagnostic log lines (mpv output, player
/// status messages, EPG loads, etc.), surfaced in the debug log panel.
///
/// A single shared instance is used so any part of the app can append without
/// threading a controller through the widget tree. Capped so a long session
/// can't grow memory unbounded.
class DebugLogService extends ChangeNotifier {
  DebugLogService._();

  static final DebugLogService instance = DebugLogService._();

  static const int _maxEntries = 2000;

  final List<DebugLogEntry> _entries = [];
  List<DebugLogEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  void add(
    String message, {
    DebugLogLevel level = DebugLogLevel.info,
    String source = 'app',
  }) {
    _entries.add(
      DebugLogEntry(
        time: DateTime.now(),
        level: level,
        source: source,
        message: message,
      ),
    );
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}
