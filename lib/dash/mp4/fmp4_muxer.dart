// Combines separate DASH video and audio fMP4 streams into a single multiplexed
// fMP4 that libmpv can demux as one file.
//
// ExoPlayer keeps tracks separate and hands them to a track-aware renderer; mpv
// only accepts a single progressive stream, so we mux at the box level (no
// re-encoding):
//
//   * init: build one `moov` carrying both tracks' `trak` boxes (track_ID 1 =
//     video, 2 = audio) and a merged `mvex` with both `trex` boxes.
//   * each fragment: build one `moof` (single `mfhd` + video `traf` + audio
//     `traf`) followed by one `mdat` holding the video sample data then the
//     audio sample data, fixing every `traf`'s track_ID, `trun` data_offset and
//     the fragment `mfhd` sequence number.
//
// Inputs are already-decrypted, single-track fMP4 (the output of `cenc.dart`).

import 'dart:typed_data';

import 'boxes.dart';
import 'cenc.dart';

const int _videoTrackId = 1;
const int _audioTrackId = 2;

/// Builds a merged init segment from a [video] init and an optional [audio]
/// init (each a moov-bearing fMP4 init segment). Track IDs are normalised to
/// 1 (video) and 2 (audio) so fragment trafs can reference them consistently.
Uint8List muxInit(Uint8List video, Uint8List? audio) {
  final videoBoxes = parseBoxes(video, 0, video.length);
  final videoMoov = _find(videoBoxes, 'moov');
  if (videoMoov == null) return video;

  if (audio == null) {
    // Video-only: just renumber the single track to id 1.
    final trak = videoMoov.child('trak');
    if (trak != null) _setTrackId(trak, _videoTrackId);
    _setTrexTrackIds(videoMoov, [_videoTrackId]);
    return serializeBoxes(videoBoxes);
  }

  final audioBoxes = parseBoxes(audio, 0, audio.length);
  final audioMoov = _find(audioBoxes, 'moov');
  final audioTrak = audioMoov?.child('trak');
  if (audioMoov == null || audioTrak == null) {
    final trak = videoMoov.child('trak');
    if (trak != null) _setTrackId(trak, _videoTrackId);
    _setTrexTrackIds(videoMoov, [_videoTrackId]);
    return serializeBoxes(videoBoxes);
  }

  final videoTrak = videoMoov.child('trak');
  if (videoTrak != null) _setTrackId(videoTrak, _videoTrackId);
  _setTrackId(audioTrak, _audioTrackId);

  // Append the audio trak into the video moov, before/around mvex.
  // Insert the audio trak right after the last existing trak.
  final lastTrakIndex =
      videoMoov.children.lastIndexWhere((b) => b.type == 'trak');
  videoMoov.children.insert(lastTrakIndex + 1, audioTrak);

  // Merge mvex: ensure a trex exists for both track IDs.
  _mergeMvex(videoMoov, audioMoov);

  // Update mvhd next_track_ID to 3 (best-effort; not all demuxers care).
  _setMvhdNextTrackId(videoMoov, 3);

  return serializeBoxes(videoBoxes);
}

/// Builds one merged fragment from a [video] fragment and an optional [audio]
/// fragment (each a moof+mdat fMP4 segment). [sequenceNumber] sets the merged
/// fragment's `mfhd` sequence number.
///
/// Note: this does NOT normalise decode times — call
/// [normalizeFragmentTimestamps] on the result, in playback order, so the
/// per-track origin is captured deterministically even when fragments are
/// muxed out of order by a prefetch pipeline.
Uint8List muxFragment(Uint8List video, Uint8List? audio, int sequenceNumber) {
  final videoBoxes = parseBoxes(video, 0, video.length);
  final videoMoof = _find(videoBoxes, 'moof');
  final videoMdat = _find(videoBoxes, 'mdat');
  if (videoMoof == null || videoMdat == null) return video;

  if (audio == null) {
    _setTrafTrackId(videoMoof, _videoTrackId);
    _setMfhdSequence(videoMoof, sequenceNumber);
    for (final traf in videoMoof.children.where((b) => b.type == 'traf')) {
      _normalizeTfhdBase(traf);
    }
    _rewriteSingleTrackOffsets(videoMoof, videoMdat);
    return serializeBoxes([videoMoof, videoMdat]);
  }

  final audioBoxes = parseBoxes(audio, 0, audio.length);
  final audioMoof = _find(audioBoxes, 'moof');
  final audioMdat = _find(audioBoxes, 'mdat');
  final audioTraf = audioMoof?.child('traf');
  if (audioMoof == null || audioMdat == null || audioTraf == null) {
    _setTrafTrackId(videoMoof, _videoTrackId);
    _setMfhdSequence(videoMoof, sequenceNumber);
    for (final traf in videoMoof.children.where((b) => b.type == 'traf')) {
      _normalizeTfhdBase(traf);
    }
    _rewriteSingleTrackOffsets(videoMoof, videoMdat);
    return serializeBoxes([videoMoof, videoMdat]);
  }

  _setTrafTrackId(videoMoof, _videoTrackId);
  _setTrafTrackIdOn(audioTraf, _audioTrackId);
  _setMfhdSequence(videoMoof, sequenceNumber);

  // Make trun.data_offset authoritative: drop any absolute base_data_offset in
  // the source tfhds and set default-base-is-moof, so the offsets we compute
  // below (relative to the merged moof) are what the demuxer uses. Without this,
  // a stale absolute base_data_offset made the audio samples read from the
  // wrong place — mpv then decoded video bytes as AAC (the "TNS filter order
  // 27", "channel element not allocated" garbage) and the picture broke up.
  for (final traf in videoMoof.children.where((b) => b.type == 'traf')) {
    _normalizeTfhdBase(traf);
  }
  _normalizeTfhdBase(audioTraf);

  // Build the merged moof: mfhd + video traf(s) + audio traf.
  final mergedMoof = Box('moof', children: [
    ...videoMoof.children,
    audioTraf,
  ]);

  // Merged mdat = video sample data followed by audio sample data.
  final videoData = videoMdat.payload ?? Uint8List(0);
  final audioData = audioMdat.payload ?? Uint8List(0);
  final mergedData = Uint8List(videoData.length + audioData.length)
    ..setRange(0, videoData.length, videoData)
    ..setRange(videoData.length, videoData.length + audioData.length, audioData);
  final mergedMdat = Box('mdat', payload: mergedData);

  // Fix data offsets: video samples start at mdat payload start; audio samples
  // start after the video sample data within the same mdat.
  final moofSize = mergedMoof.size;
  final mdatPayloadStart = moofSize + 8; // relative to moof start
  _rewriteTrafOffsets(_videoTrafs(mergedMoof), mdatPayloadStart);
  _rewriteTrafOffsets([audioTraf], mdatPayloadStart + videoData.length);

  return serializeBoxes([mergedMoof, mergedMdat]);
}

// --- track_ID / sequence helpers -------------------------------------------
List<Box> _videoTrafs(Box moof) =>
    moof.children.where((b) => b.type == 'traf').toList()
      ..removeWhere((t) => (t.child('tfhd')?.payload != null &&
          _tfhdTrackId(t.child('tfhd')!.payload!) == _audioTrackId));

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
Uint8List normalizeFragmentTimestamps(Uint8List fragment, Map<int, int> origins) {
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


void _setTrafTrackId(Box moof, int id) {
  final traf = moof.child('traf');
  if (traf != null) _setTrafTrackIdOn(traf, id);
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

// mvex/trex: ensure trex entries reference the normalised track IDs. ExoPlayer
// relies on trex for default sample flags/durations, so keep the originals but
// fix their track_ID to match the trak we renumbered.
void _mergeMvex(Box videoMoov, Box audioMoov) {
  var videoMvex = videoMoov.child('mvex');
  final audioMvex = audioMoov.child('mvex');
  if (videoMvex == null) {
    videoMvex = Box('mvex', children: []);
    videoMoov.children.add(videoMvex);
  }
  // Renumber the existing (video) trex to video track id.
  final videoTrexes = videoMvex.children.where((b) => b.type == 'trex').toList();
  if (videoTrexes.isNotEmpty) {
    _setTrexTrackId(videoTrexes.first, _videoTrackId);
  }
  // Append audio trex(es), renumbered.
  if (audioMvex != null) {
    for (final trex in audioMvex.children.where((b) => b.type == 'trex')) {
      _setTrexTrackId(trex, _audioTrackId);
      videoMvex.children.add(trex);
    }
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

// Single-track fragment: samples start at the mdat payload (moof size + 8).
void _rewriteSingleTrackOffsets(Box moof, Box mdat) {
  final base = moof.size + 8;
  _rewriteTrafOffsets(
      moof.children.where((b) => b.type == 'traf').toList(), base);
}

// Sets every trun's data_offset in [trafs] so that samples resolve to
// [startOffset] (relative to the enclosing moof), accumulating each traf/trun's
// total sample size as we go.
void _rewriteTrafOffsets(List<Box> trafs, int startOffset) {
  var running = startOffset;
  for (final traf in trafs) {
    final tfhd = traf.child('tfhd');
    final defSize =
        tfhd?.payload != null ? tfhdDefaultSampleSize(tfhd!.payload!) : 0;
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
