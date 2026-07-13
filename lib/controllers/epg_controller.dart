import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/epg.dart';
import '../models/playlist.dart';
import '../services/epg_parser.dart';

/// Owns EPG (XMLTV) guides: which URL each playlist uses, downloading and
/// parsing them off the UI thread, caching to disk, and answering now/next and
/// full-day queries for channels.
///
/// A guide is keyed by its URL, so multiple playlists sharing the same
/// `url-tvg` reuse one parsed guide. Parsed guides are held in memory; the raw
/// bytes are cached to a temp file so a restart can reload without re-fetching
/// when still fresh.
/// Coarse status of a source's EPG guide, used to explain to the user why the
/// guide area might be empty instead of silently showing nothing.
enum EpgStatus {
  /// The playlist declared no `url-tvg` header, so there is nothing to load.
  noUrl,

  /// A download/parse is in flight.
  loading,

  /// The last download/parse failed; see [EpgController.errorFor].
  error,

  /// A guide is loaded and available.
  ready,
}

class EpgController extends ChangeNotifier {
  final Map<String, EpgGuide> _guides = {};
  final Map<String, DateTime> _fetchedAt = {};
  final Map<String, String> _errors = {};
  final Set<String> _loading = {};

  // Bumped whenever guide data changes so time-based widgets can also key off
  // it if needed. Mostly we just rely on notifyListeners().
  int _revision = 0;
  int get revision => _revision;

  bool _restored = false;

  /// The guide URLs currently being fetched/parsed (for spinners).
  Set<String> get loadingUrls => Set.unmodifiable(_loading);

  bool isLoading(String? url) => url != null && _loading.contains(url);

  bool hasGuide(String? url) => url != null && _guides.containsKey(url);

  EpgGuide? guideFor(String? url) => url == null ? null : _guides[url];

  /// The last error message for [url], if its most recent load failed.
  String? errorFor(String? url) => url == null ? null : _errors[url];

  /// The coarse status of [url]'s guide, for user-facing diagnostics.
  EpgStatus statusFor(String? url) {
    if (url == null || url.trim().isEmpty) return EpgStatus.noUrl;
    if (_loading.contains(url)) return EpgStatus.loading;
    if (_guides.containsKey(url)) return EpgStatus.ready;
    if (_errors.containsKey(url)) return EpgStatus.error;
    return EpgStatus.loading;
  }

  /// Restores the URL->timestamp index and lazily reloads cached guide bytes
  /// from disk. Called once at startup.
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(epgStorageKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final ts = (entry.value as num?)?.toInt();
        if (ts != null) {
          _fetchedAt[entry.key] = DateTime.fromMillisecondsSinceEpoch(
            ts,
            isUtc: true,
          );
        }
      }
    } catch (_) {
      // Corrupt index: ignore and start fresh.
    }
  }

  Future<void> _saveIndex() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      epgStorageKey,
      jsonEncode(
        _fetchedAt.map((url, at) => MapEntry(url, at.millisecondsSinceEpoch)),
      ),
    );
  }

  /// Ensures the guide for [url] is available: reloads a fresh disk cache, or
  /// downloads + parses when missing/stale. Safe to call repeatedly; in-flight
  /// and satisfied requests are deduped. Failures are swallowed (EPG is
  /// best-effort) but logged.
  Future<void> ensureGuide(String? url, {bool force = false}) async {
    if (url == null || url.trim().isEmpty) return;
    if (_loading.contains(url)) return;
    if (!force && _guides.containsKey(url)) return;

    final fetchedAt = _fetchedAt[url];
    final fresh =
        fetchedAt != null &&
        DateTime.now().toUtc().difference(fetchedAt) < epgRefreshInterval;

    _loading.add(url);
    notifyListeners();
    try {
      // Try the on-disk cache first when it's still fresh and not forced.
      if (!force && fresh && !_guides.containsKey(url)) {
        final cached = await _readCache(url);
        if (cached != null) {
          final guide = await compute(parseXmltv, cached);
          _guides[url] = guide;
          _errors.remove(url);
          _bump();
          return;
        }
      }

      final bytes = await _download(url);
      final guide = await compute(parseXmltv, bytes);
      _guides[url] = guide;
      _errors.remove(url);
      _fetchedAt[url] = DateTime.now().toUtc();
      unawaited(_writeCache(url, bytes));
      unawaited(_saveIndex());
      _bump();
    } catch (error) {
      _errors[url] = error.toString();
      debugPrint('EPG load failed for $url: $error');
    } finally {
      _loading.remove(url);
      notifyListeners();
    }
  }

  void _bump() {
    _revision++;
    notifyListeners();
  }

  /// What's on now and next for a channel, using its guide URL. Returns an
  /// empty result when no guide is loaded or the channel isn't in it.
  EpgNowNext nowNext(String? url, Channel channel, {DateTime? at}) {
    final guide = url == null ? null : _guides[url];
    if (guide == null) return const EpgNowNext();
    return guide.nowNext(
      channel.tvgId,
      channel.name,
      (at ?? DateTime.now()).toUtc(),
    );
  }

  List<EpgProgramme> programmesForDay(
    String? url,
    Channel channel,
    DateTime day,
  ) {
    final guide = url == null ? null : _guides[url];
    if (guide == null) return const [];
    return guide.programmesForDay(channel.tvgId, channel.name, day);
  }

  bool channelHasData(String? url, Channel channel) {
    final guide = url == null ? null : _guides[url];
    if (guide == null) return false;
    return guide.hasData(channel.tvgId, channel.name);
  }

  // --- networking + disk cache -------------------------------------------

  Future<Uint8List> _download(String url) async {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  File _cacheFile(String url) {
    // A stable, filesystem-safe name derived from the URL (FNV-1a 64-bit hex).
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(url)) {
      hash = (hash ^ byte) * 0x100000001b3;
      hash &= 0xFFFFFFFFFFFFFFFF;
    }
    final name = hash.toRadixString(16).padLeft(16, '0');
    final dir = Directory('${Directory.systemTemp.path}/light-iptv-epg');
    return File('${dir.path}/$name.xmltv');
  }

  Future<void> _writeCache(String url, Uint8List bytes) async {
    try {
      final file = _cacheFile(url);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: false);
    } catch (error) {
      debugPrint('EPG cache write failed: $error');
    }
  }

  Future<Uint8List?> _readCache(String url) async {
    try {
      final file = _cacheFile(url);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }
}
