// Combines separate DASH video, audio and subtitle fMP4 streams into a
// single multiplexed fMP4 that libmpv can demux as one file.
//
// Track IDs are normalised to 1 (video), 2 (audio) and 3, 4, 5, ... for each
// text track. Inputs are already-decrypted, single-track fMP4 (the output of
// `cenc.dart`).

import 'dart:typed_data';

import 'boxes.dart';
import 'cenc.dart';

const int _videoTrackId = 1;
const int _audioTrackId = 2;

/// Output track ID of the first muxed text track. Every additional text track
/// takes the next ID, so a manifest with three subtitle languages produces
/// tracks 3, 4 and 5.
const int firstSubtitleTrackId = 3;

/// One text track's initialisation segment plus the output track ID and
/// language it should carry in the merged init.
class SubtitleInit {
  const SubtitleInit({
    required this.trackId,
    required this.data,
    this.language,
  });

  /// Track ID this text track takes in the merged output.
  final int trackId;

  /// The track's own (already sanitised) fMP4 init segment.
  final Uint8List data;

  /// Language declared by the MPD. Written into the merged init so several
  /// subtitle tracks show up with distinct labels instead of as unnamed
  /// duplicates when the packager leaves the metadata out of the init segment.
  final String? language;
}

/// Builds a merged init segment from a [video] init plus an optional [audio]
/// init and any number of [subtitles]. Subtitle inputs must be MP4 text tracks
/// (for example `wvtt` or `stpp`), not raw WebVTT/TTML documents.
Uint8List muxInit(
  Uint8List video,
  Uint8List? audio, [
  List<SubtitleInit> subtitles = const [],
]) {
  final videoBoxes = parseBoxes(video, 0, video.length);
  final videoMoovs = videoBoxes.where((box) => box.type == 'moov').toList();
  if (videoMoovs.length != 1) {
    throw FormatException(
      'Expected exactly one moov in video init, found ${videoMoovs.length}',
    );
  }
  final videoMoov = videoMoovs.single;

  final videoTrak = videoMoov.child('trak');
  if (videoTrak != null) _setTrackId(videoTrak, _videoTrackId);
  _setTrexTrackIds(videoMoov, [_videoTrackId]);

  var highestTrackId = _videoTrackId;
  if (_appendInitTrack(videoMoov, audio, _audioTrackId)) {
    highestTrackId = _audioTrackId;
  }
  for (final subtitle in subtitles) {
    final appended = _appendInitTrack(
      videoMoov,
      subtitle.data,
      subtitle.trackId,
      language: subtitle.language,
    );
    if (appended && subtitle.trackId > highestTrackId) {
      highestTrackId = subtitle.trackId;
    }
  }
  _setMvhdNextTrackId(videoMoov, highestTrackId + 1);

  final ftyp = videoBoxes.where((box) => box.type == 'ftyp').firstOrNull;
  return serializeBoxes([?ftyp, videoMoov]);
}

bool _appendInitTrack(
  Box targetMoov,
  Uint8List? source,
  int trackId, {
  String? language,
}) {
  if (source == null) return false;
  final sourceBoxes = parseBoxes(source, 0, source.length);
  final sourceMoov = _find(sourceBoxes, 'moov');
  final sourceTrak = sourceMoov?.child('trak');
  if (sourceMoov == null || sourceTrak == null) return false;

  _setTrackId(sourceTrak, trackId);
  _setTrackLanguage(sourceTrak, language);
  final lastTrakIndex = targetMoov.children.lastIndexWhere(
    (box) => box.type == 'trak',
  );
  targetMoov.children.insert(lastTrakIndex + 1, sourceTrak);
  _appendTrex(targetMoov, sourceMoov, trackId);
  return true;
}

void _appendTrex(Box targetMoov, Box sourceMoov, int trackId) {
  var targetMvex = targetMoov.child('mvex');
  if (targetMvex == null) {
    targetMvex = Box('mvex', children: []);
    targetMoov.children.add(targetMvex);
  }
  final sourceTrex = sourceMoov
      .child('mvex')
      ?.children
      .where((box) => box.type == 'trex')
      .firstOrNull;
  if (sourceTrex == null) return;
  _setTrexTrackId(sourceTrex, trackId);
  targetMvex.children.add(sourceTrex);
}

/// Builds one merged media fragment. Missing optional fragments are omitted,
/// allowing video/audio playback to continue across subtitle segment gaps.
///
/// [subtitles] maps a merged-output track ID (as handed to [muxInit]) to that
/// track's fragment. Only the text tracks that have a segment covering this
/// fragment need to be present; a subtitle segment usually spans several video
/// segments, so most fragments carry none.
Uint8List muxFragment(
  Uint8List video,
  Uint8List? audio,
  int sequenceNumber, [
  Map<int, Uint8List> subtitles = const {},
]) {
  final videoBoxes = parseBoxes(video, 0, video.length);
  final videoMoof = _find(videoBoxes, 'moof');
  final videoMdat = _find(videoBoxes, 'mdat');
  if (videoBoxes.any((box) => box.type == 'moov')) {
    throw const FormatException('Media fragment unexpectedly contains moov');
  }
  if (videoMoof == null || videoMdat == null) {
    throw const FormatException('Media fragment is missing moof or mdat');
  }

  final videoTrafs = videoMoof.children
      .where((box) => box.type == 'traf')
      .toList();
  for (final traf in videoTrafs) {
    _setTrafTrackIdOn(traf, _videoTrackId);
    _normalizeTfhdBase(traf);
  }
  _setMfhdSequence(videoMoof, sequenceNumber);

  final subtitleTrackIds = subtitles.keys.toList(growable: false)..sort();
  final optionalParts = <_FragmentPart>[
    ?_fragmentPart(audio, _audioTrackId),
    for (final trackId in subtitleTrackIds)
      ?_fragmentPart(subtitles[trackId], trackId),
  ];
  final mergedMoof = Box(
    'moof',
    children: [
      ...videoMoof.children,
      for (final part in optionalParts) part.traf,
    ],
  );

  final videoData = videoMdat.payload ?? Uint8List(0);
  final totalDataLength = optionalParts.fold<int>(
    videoData.length,
    (length, part) => length + part.data.length,
  );
  final mergedData = Uint8List(totalDataLength)
    ..setRange(0, videoData.length, videoData);
  var dataPosition = videoData.length;
  for (final part in optionalParts) {
    mergedData.setRange(
      dataPosition,
      dataPosition + part.data.length,
      part.data,
    );
    dataPosition += part.data.length;
  }
  final mergedMdat = Box('mdat', payload: mergedData);

  final allTrafs = [...videoTrafs, for (final part in optionalParts) part.traf];
  // Some subtitle fragments omit trun.data_offset because their original
  // single-track layout made it implicit. It must be explicit after muxing,
  // otherwise the subtitle decoder reads video/audio bytes instead of cues.
  _ensureTrafDataOffsets(allTrafs);

  var dataOffset = mergedMoof.size + 8;
  _rewriteTrafOffsets(videoTrafs, dataOffset);
  dataOffset += videoData.length;
  for (final part in optionalParts) {
    _rewriteTrafOffsets([part.traf], dataOffset);
    dataOffset += part.data.length;
  }

  return serializeBoxes([mergedMoof, mergedMdat]);
}

_FragmentPart? _fragmentPart(Uint8List? source, int trackId) {
  if (source == null) return null;
  final boxes = parseBoxes(source, 0, source.length);
  final moof = _find(boxes, 'moof');
  final mdat = _find(boxes, 'mdat');
  final traf = moof?.child('traf');
  if (moof == null || mdat == null || traf == null) return null;
  _setTrafTrackIdOn(traf, trackId);
  _normalizeTfhdBase(traf);
  return _FragmentPart(traf, mdat.payload ?? Uint8List(0));
}

class _FragmentPart {
  const _FragmentPart(this.traf, this.data);

  final Box traf;
  final Uint8List data;
}

// --- track_ID / sequence helpers -------------------------------------------

Box? _find(List<Box> boxes, String type) {
  for (final b in boxes) {
    if (b.type == type) return b;
  }
  return null;
}

// tkhd: version(1) flags(3) create/mod times, then track_ID.
void _setTrackId(Box trak, int id) {
  final tkhd = trak.child('tkhd');
  final p = tkhd?.payload;
  if (p == null || p.isEmpty) return;
  final version = p[0];
  // v0: creation(4) modification(4) track_ID(4). v1: creation(8) mod(8) id(4).
  final idOffset = version == 1 ? 4 + 8 + 8 : 4 + 4 + 4;
  if (p.length >= idOffset + 4) writeU32(p, idOffset, id);

  // Also set the tfhd inside any embedded... (init has no traf; skip.)
  // Update tkhd's internal reference only; sample entries are unaffected.
}

// Stamps the MPD-declared language onto a track so a stream with several
// subtitle tracks produces a menu of distinguishable entries. Packagers that
// leave `mdhd.language` at `und` in their text init segments would otherwise
// yield N identical "Subtitle" rows.
void _setTrackLanguage(Box trak, String? language) {
  final packed = _packMdhdLanguage(language);
  if (packed == null) return;
  final p = trak.child('mdia')?.child('mdhd')?.payload;
  if (p == null || p.isEmpty) return;
  // v0: ver/flags(4) creation(4) modification(4) timescale(4) duration(4) then
  // the packed language. v1 widens creation/modification to 8 and duration to 8.
  final offset = p[0] == 1 ? 4 + 8 + 8 + 4 + 8 : 4 + 4 + 4 + 4 + 4;
  if (p.length < offset + 2) return;
  p[offset] = (packed >> 8) & 0xff;
  p[offset + 1] = packed & 0xff;
}

// `mdhd` stores three lowercase ISO-639-2/T letters as 5 bits each. MPDs often
// use the two-letter ISO-639-1 form instead, so the common codes are mapped;
// anything else leaves the init segment's own metadata untouched.
int? _packMdhdLanguage(String? language) {
  var code = language?.trim().split(RegExp('[-_]')).first.toLowerCase();
  if (code == null || code.isEmpty) return null;
  if (code.length == 2) code = _iso639_1To2[code];
  if (code == null || code.length != 3) return null;
  var packed = 0;
  for (final unit in code.codeUnits) {
    if (unit < 0x61 || unit > 0x7a) return null;
    packed = (packed << 5) | (unit - 0x60);
  }
  return packed;
}

const Map<String, String> _iso639_1To2 = {
  'ar': 'ara', 'bn': 'ben', 'cs': 'ces', 'da': 'dan', 'de': 'deu',
  'el': 'ell', 'en': 'eng', 'es': 'spa', 'fa': 'fas', 'fi': 'fin',
  'fr': 'fra', 'he': 'heb', 'hi': 'hin', 'hu': 'hun', 'id': 'ind',
  'it': 'ita', 'ja': 'jpn', 'ko': 'kor', 'ms': 'msa', 'nl': 'nld',
  'no': 'nor', 'pl': 'pol', 'pt': 'por', 'ro': 'ron', 'ru': 'rus',
  'sv': 'swe', 'ta': 'tam', 'te': 'tel', 'th': 'tha', 'tr': 'tur',
  'uk': 'ukr', 'vi': 'vie', 'zh': 'chi',
};

int _tfhdTrackId(Uint8List p) => readU32(p, 4); // ver/flags(4) then track_ID(4)

// tfdt: version(1) flags(3) then baseMediaDecodeTime (32-bit if v0, 64-bit v1).
int? _readTfdt(Box traf) {
  final tfdt = traf.child('tfdt');
  final p = tfdt?.payload;
  if (p == null || p.length < 8) return null;
  final version = p[0];
  if (version == 1) {
    if (p.length < 12) return null;
    return readU64(p, 4);
  }
  return readU32(p, 4);
}

void _writeTfdt(Box traf, int value) {
  final tfdt = traf.child('tfdt');
  final p = tfdt?.payload;
  if (p == null || p.length < 8) return;
  final version = p[0];
  if (version == 1) {
    if (p.length < 12) return;
    // Write 64-bit big-endian.
    final hi = (value ~/ 0x100000000) & 0xffffffff;
    final lo = value & 0xffffffff;
    writeU32(p, 4, hi);
    writeU32(p, 8, lo);
  } else {
    writeU32(p, 4, value & 0xffffffff);
  }
}

// Shifts each track's `tfdt` baseMediaDecodeTime so the output timeline starts
// at 0. The first fragment seen for a given track id records that track's
// original decode time as its origin; every fragment then subtracts the origin.
// Both tracks keep their own origin, so relative A/V offset — and thus sync —
// is preserved.
//
// Live DASH segments carry `tfdt` based on an absolute clock epoch; fed to mpv
// as a bare progressive stream that produced a nonsensical timeline (e.g. a
// 495511-hour position) and broke playback. Call this in playback order so the
// origin is captured deterministically (a prefetch pipeline muxes out of order).
Uint8List normalizeFragmentTimestamps(
  Uint8List fragment,
  Map<int, int> origins,
) {
  final boxes = parseBoxes(fragment, 0, fragment.length);
  var changed = false;
  for (final moof in boxes.where((b) => b.type == 'moof')) {
    for (final traf in moof.children.where((b) => b.type == 'traf')) {
      final tfhd = traf.child('tfhd');
      if (tfhd?.payload == null) continue;
      final trackId = _tfhdTrackId(tfhd!.payload!);
      final original = _readTfdt(traf);
      if (original == null) continue;
      final origin = origins.putIfAbsent(trackId, () => original);
      final shifted = original - origin;
      _writeTfdt(traf, shifted < 0 ? 0 : shifted);
      changed = true;
    }
  }
  return changed ? serializeBoxes(boxes) : fragment;
}

void _setTfhdTrackId(Uint8List p, int id) => writeU32(p, 4, id);

// Normalises a traf's tfhd so trun.data_offset (measured from the moof start)
// is authoritative: removes any absolute base_data_offset field and clears its
// flag, and sets the default-base-is-moof flag (0x020000). A leftover absolute
// base_data_offset from the source segment would otherwise point samples at the
// wrong bytes in our re-laid-out mdat.
void _normalizeTfhdBase(Box traf) {
  final tfhd = traf.child('tfhd');
  final p = tfhd?.payload;
  if (p == null || p.length < 8) return;
  var flags = readU32(p, 0) & 0xffffff;
  const baseDataOffsetPresent = 0x000001;
  const defaultBaseIsMoof = 0x020000;

  if (flags & baseDataOffsetPresent != 0) {
    // Drop the 8-byte base_data_offset that follows ver/flags(4) + track_ID(4).
    final out = BytesBuilder();
    out.add(p.sublist(0, 8)); // ver/flags + track_ID
    out.add(p.sublist(16)); // everything after the 8-byte base_data_offset
    final np = out.toBytes();
    flags &= ~baseDataOffsetPresent;
    flags |= defaultBaseIsMoof;
    // Rewrite flags (keep version byte np[0]).
    np[1] = (flags >> 16) & 0xff;
    np[2] = (flags >> 8) & 0xff;
    np[3] = flags & 0xff;
    tfhd!.payload = np;
  } else if (flags & defaultBaseIsMoof == 0) {
    flags |= defaultBaseIsMoof;
    p[1] = (flags >> 16) & 0xff;
    p[2] = (flags >> 8) & 0xff;
    p[3] = flags & 0xff;
  }
}

void _setTrafTrackIdOn(Box traf, int id) {
  final tfhd = traf.child('tfhd');
  if (tfhd?.payload != null) _setTfhdTrackId(tfhd!.payload!, id);
}

void _setMfhdSequence(Box moof, int sequenceNumber) {
  final mfhd = moof.child('mfhd');
  final p = mfhd?.payload;
  if (p != null && p.length >= 8) {
    writeU32(p, 4, sequenceNumber); // ver/flags(4) then sequence_number(4)
  }
}

void _setTrexTrackId(Box trex, int id) {
  final p = trex.payload;
  if (p != null && p.length >= 8) {
    writeU32(p, 4, id); // ver/flags(4) then track_ID(4)
  }
}

void _setTrexTrackIds(Box moov, List<int> ids) {
  final mvex = moov.child('mvex');
  if (mvex == null) return;
  final trexes = mvex.children.where((b) => b.type == 'trex').toList();
  for (var i = 0; i < trexes.length && i < ids.length; i++) {
    _setTrexTrackId(trexes[i], ids[i]);
  }
}

// mvhd next_track_ID is the last u32 of the mvhd payload.
void _setMvhdNextTrackId(Box moov, int nextId) {
  final mvhd = moov.child('mvhd');
  final p = mvhd?.payload;
  if (p != null && p.length >= 4) {
    writeU32(p, p.length - 4, nextId);
  }
}

// --- data_offset rewriting --------------------------------------------------

// Ensures every trun has an explicit data_offset placeholder before the moof
// size is measured. Inserting the field later would itself grow the moof and
// invalidate every offset calculated from its old size.
void _ensureTrafDataOffsets(List<Box> trafs) {
  for (final traf in trafs) {
    for (final trun in traf.children.where((box) => box.type == 'trun')) {
      final payload = trun.payload;
      if (payload == null || payload.length < 8) continue;
      var flags = readU32(payload, 0) & 0xffffff;
      const dataOffsetPresent = 0x000001;
      if (flags & dataOffsetPresent != 0) continue;

      final expanded = Uint8List(payload.length + 4)
        ..setRange(0, 8, payload)
        ..setRange(12, payload.length + 4, payload, 8);
      flags |= dataOffsetPresent;
      expanded[1] = (flags >> 16) & 0xff;
      expanded[2] = (flags >> 8) & 0xff;
      expanded[3] = flags & 0xff;
      trun.payload = expanded;
    }
  }
}

// Sets every trun's data_offset in [trafs] so that samples resolve to
// [startOffset] (relative to the enclosing moof), accumulating each traf/trun's
// total sample size as we go.
void _rewriteTrafOffsets(List<Box> trafs, int startOffset) {
  var running = startOffset;
  for (final traf in trafs) {
    final tfhd = traf.child('tfhd');
    final defSize = tfhd?.payload != null
        ? tfhdDefaultSampleSize(tfhd!.payload!)
        : 0;
    for (final trun in traf.children.where((b) => b.type == 'trun')) {
      if (trun.payload == null) continue;
      final info = parseTrun(trun.payload!, defSize);
      if (info.dataOffsetPos >= 0) {
        writeU32(trun.payload!, info.dataOffsetPos, running);
      }
      running += info.sizes.fold<int>(0, (s, x) => s + x);
    }
  }
}
