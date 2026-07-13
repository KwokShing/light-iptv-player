/// A single EPG programme (one row in an XMLTV `<programme>` element), with its
/// absolute UTC start/stop so now/next lookups are timezone-agnostic.
class EpgProgramme {
  const EpgProgramme({
    required this.start,
    required this.stop,
    required this.title,
    this.description,
    this.category,
  });

  final DateTime start; // UTC
  final DateTime stop; // UTC
  final String title;
  final String? description;
  final String? category;

  Duration get duration => stop.difference(start);

  bool containsInstant(DateTime nowUtc) =>
      !nowUtc.isBefore(start) && nowUtc.isBefore(stop);

  /// Progress through the programme at [nowUtc], clamped to 0..1.
  double progressAt(DateTime nowUtc) {
    final total = stop.difference(start).inMilliseconds;
    if (total <= 0) return 0;
    final elapsed = nowUtc.difference(start).inMilliseconds;
    final ratio = elapsed / total;
    if (ratio.isNaN) return 0;
    return ratio.clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    's': start.millisecondsSinceEpoch,
    'e': stop.millisecondsSinceEpoch,
    't': title,
    if (description != null) 'd': description,
    if (category != null) 'c': category,
  };

  factory EpgProgramme.fromJson(Map<String, dynamic> json) => EpgProgramme(
    start: DateTime.fromMillisecondsSinceEpoch(
      (json['s'] as num).toInt(),
      isUtc: true,
    ),
    stop: DateTime.fromMillisecondsSinceEpoch(
      (json['e'] as num).toInt(),
      isUtc: true,
    ),
    title: json['t'] as String? ?? '',
    description: json['d'] as String?,
    category: json['c'] as String?,
  );
}

/// The what's-on-now/next pair for a channel at a given instant.
class EpgNowNext {
  const EpgNowNext({this.now, this.next});
  final EpgProgramme? now;
  final EpgProgramme? next;

  bool get isEmpty => now == null && next == null;
}

/// A parsed XMLTV guide: programmes indexed by channel id, plus a display-name
/// index used to recover a match when a playlist's `tvg-id` doesn't line up
/// with the guide's channel ids (improves recall).
///
/// Matching runs in tiers, each looser than the last, so accuracy stays high
/// while recall improves:
///   1. exact `tvg-id`            (normalized)
///   2. exact display-name        (normalized)
///   3. exact "simplified" key    (channel-noise stripped: HD/4K/字幕/…)
///   4. fuzzy edit-distance match on the simplified key, above a similarity
///      threshold, as a last resort.
class EpgGuide {
  EpgGuide({
    required this.byChannelId,
    required this.displayNameToId,
    required this.generatedAt,
  }) {
    // Build the simplified-key index once, from every id and display name that
    // resolves to a channel with programmes. First writer wins so a shorter,
    // cleaner name isn't overwritten by a noisier alias.
    void register(String raw, String id) {
      final key = _simplifyName(raw);
      if (key.isEmpty) return;
      _simplifiedToId.putIfAbsent(key, () => id);
    }

    for (final id in byChannelId.keys) {
      register(id, id);
    }
    displayNameToId.forEach((name, id) => register(name, id));
  }

  /// Normalized channel id -> programmes sorted ascending by start time.
  final Map<String, List<EpgProgramme>> byChannelId;

  /// Normalized channel display-name -> normalized channel id, for name-based
  /// fallback matching.
  final Map<String, String> displayNameToId;

  /// Simplified (noise-stripped) key -> channel id, for tier-3/4 matching.
  final Map<String, String> _simplifiedToId = {};

  /// Memoises resolved channel ids per (tvgId|name) query so the repeated
  /// now/next lookups the UI issues (every ~30s per visible row) don't re-run
  /// the fuzzy search. Stores '' for "no match" so misses are cached too.
  final Map<String, String> _resolveCache = {};

  /// When this guide was fetched/parsed (used for cache freshness).
  final DateTime generatedAt;

  int get channelCount => byChannelId.length;

  int get programmeCount =>
      byChannelId.values.fold(0, (sum, list) => sum + list.length);

  static String normalizeKey(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Aggressively simplifies a channel id/name for loose matching: lowercases,
  /// drops parenthesised segments (e.g. "(字幕)"), strips common quality/format
  /// and generic "channel/台/頻道" tokens, and removes every non-alphanumeric,
  /// non-CJK character. Returns '' when nothing meaningful remains.
  static String _simplifyName(String value) {
    var s = value.toLowerCase();
    // Drop bracketed/parenthesised annotations: (字幕), [HD], （粤）, 【…】.
    s = s.replaceAll(RegExp(r'[\(\[（【][^\)\]）】]*[\)\]）】]'), ' ');
    // Common ASCII quality/format/generic noise tokens (need word boundaries so
    // e.g. "hd" isn't stripped from inside a real word).
    s = s.replaceAll(
      RegExp(
        r'\b(fhd|uhd|hd|sd|4k|8k|1080p?|720p?|h265|h264|hevc|dolby|live|'
        r'channel|tv)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    // CJK generic tokens: \b word boundaries don't apply between CJK glyphs, so
    // strip these unconditionally.
    s = s.replaceAll(
      RegExp(r'台|臺|頻道|频道|直播|高清|超清|标清|標清'),
      '',
    );
    // Keep letters, digits and CJK; everything else becomes a separator.
    s = s.replaceAll(
      RegExp(r'[^0-9a-z\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+'),
      '',
    );
    return s;
  }

  /// Resolves the channel id for a query, walking the match tiers. Cached.
  String? _resolveChannelId(String? tvgId, String channelName) {
    final cacheKey = '${tvgId ?? ''}|$channelName';
    final cached = _resolveCache[cacheKey];
    if (cached != null) return cached.isEmpty ? null : cached;

    final id = _resolveUncached(tvgId, channelName);
    _resolveCache[cacheKey] = id ?? '';
    return id;
  }

  String? _resolveUncached(String? tvgId, String channelName) {
    // Tier 1: exact tvg-id.
    if (tvgId != null && tvgId.trim().isNotEmpty) {
      final key = normalizeKey(tvgId);
      if (byChannelId.containsKey(key)) return key;
    }
    // Tier 2: exact display-name.
    final viaName = displayNameToId[normalizeKey(channelName)];
    if (viaName != null) return viaName;

    // Build a simplified key from whichever source is non-empty.
    final simplified = _simplifyName(
      channelName.isNotEmpty ? channelName : (tvgId ?? ''),
    );
    if (simplified.isEmpty) return null;

    // Tier 3: exact simplified-key.
    final viaSimple = _simplifiedToId[simplified];
    if (viaSimple != null) return viaSimple;

    // Tier 4: fuzzy edit-distance over simplified keys.
    return _fuzzyMatch(simplified);
  }

  /// Finds the closest simplified key to [query] by normalized Levenshtein
  /// similarity, accepting only matches at/above [_fuzzyThreshold]. Prunes
  /// candidates by length difference so the edit distance is only computed for
  /// plausibly-close keys, keeping this affordable even for large guides.
  static const double _fuzzyThreshold = 0.8;

  String? _fuzzyMatch(String query) {
    // Very short names are too ambiguous to fuzzy-match safely.
    if (query.length < 3) return null;
    final maxLenDiff = (query.length * (1 - _fuzzyThreshold)).ceil() + 1;

    String? best;
    var bestScore = _fuzzyThreshold;
    _simplifiedToId.forEach((key, id) {
      if ((key.length - query.length).abs() > maxLenDiff) return;
      final distance = _boundedLevenshtein(query, key, maxLenDiff);
      if (distance < 0) return; // exceeded the bound
      final longest = query.length > key.length ? query.length : key.length;
      final score = 1 - distance / longest;
      if (score > bestScore) {
        bestScore = score;
        best = id;
      }
    });
    return best;
  }

  /// Levenshtein distance with an early-exit [maxDistance] bound: returns -1 as
  /// soon as every cell in a row exceeds the bound (so far-apart strings cost
  /// almost nothing).
  static int _boundedLevenshtein(String a, String b, int maxDistance) {
    final n = a.length;
    final m = b.length;
    if ((n - m).abs() > maxDistance) return -1;
    var prev = List<int>.generate(m + 1, (j) => j);
    var curr = List<int>.filled(m + 1, 0);
    for (var i = 1; i <= n; i++) {
      curr[0] = i;
      var rowMin = curr[0];
      final ai = a.codeUnitAt(i - 1);
      for (var j = 1; j <= m; j++) {
        final cost = ai == b.codeUnitAt(j - 1) ? 0 : 1;
        var v = prev[j] + 1;
        final del = curr[j - 1] + 1;
        if (del < v) v = del;
        final sub = prev[j - 1] + cost;
        if (sub < v) v = sub;
        curr[j] = v;
        if (v < rowMin) rowMin = v;
      }
      if (rowMin > maxDistance) return -1;
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    final result = prev[m];
    return result > maxDistance ? -1 : result;
  }

  /// Resolves the programme list for a channel through the match tiers. Returns
  /// null when nothing lines up.
  List<EpgProgramme>? _programmesFor(String? tvgId, String channelName) {
    final id = _resolveChannelId(tvgId, channelName);
    return id == null ? null : byChannelId[id];
  }

  /// What's on now and next for a channel at [nowUtc]. Uses binary search over
  /// the sorted programme list, so this stays cheap even for guides with tens
  /// of thousands of programmes.
  EpgNowNext nowNext(String? tvgId, String channelName, DateTime nowUtc) {
    final programmes = _programmesFor(tvgId, channelName);
    if (programmes == null || programmes.isEmpty) return const EpgNowNext();

    // Find the last programme whose start <= nowUtc.
    var lo = 0;
    var hi = programmes.length - 1;
    var idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (!programmes[mid].start.isAfter(nowUtc)) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }

    EpgProgramme? now;
    EpgProgramme? next;
    if (idx >= 0 && programmes[idx].containsInstant(nowUtc)) {
      now = programmes[idx];
      if (idx + 1 < programmes.length) next = programmes[idx + 1];
    } else {
      // No programme covers `now` (a gap in the guide): surface the next
      // upcoming one so the UI still shows something meaningful.
      final nextIdx = idx + 1;
      if (nextIdx >= 0 && nextIdx < programmes.length) {
        next = programmes[nextIdx];
      }
    }
    return EpgNowNext(now: now, next: next);
  }

  /// All programmes for a channel that overlap the local calendar day [day],
  /// in start order. Used by the schedule panel.
  List<EpgProgramme> programmesForDay(
    String? tvgId,
    String channelName,
    DateTime day,
  ) {
    final programmes = _programmesFor(tvgId, channelName);
    if (programmes == null || programmes.isEmpty) return const [];
    final dayStart = DateTime(day.year, day.month, day.day).toUtc();
    final dayEnd = dayStart.add(const Duration(days: 1));
    return programmes
        .where((p) => p.stop.isAfter(dayStart) && p.start.isBefore(dayEnd))
        .toList();
  }

  /// True when a channel has any guide data (used to decide whether to render
  /// EPG affordances).
  bool hasData(String? tvgId, String channelName) {
    final programmes = _programmesFor(tvgId, channelName);
    return programmes != null && programmes.isNotEmpty;
  }
}
