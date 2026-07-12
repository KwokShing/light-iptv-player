// CENC (AES-128-CTR) decryption and init-segment sanitisation for fragmented
// MP4, ported from the original `dash_clearkey.dart`. This is the Dart
// equivalent of Bento4's `mp4decrypt` for the 'cenc' scheme: it turns
// encrypted encv/enca sample entries back into their original codec, strips
// sinf/pssh/senc/saiz/saio/sbgp/sgpd, decrypts mdat samples, and fixes trun
// data offsets.
//
// ExoPlayer delegates decryption to the platform CDM (MediaDrm); libmpv has no
// such path, so we keep this software decryptor unchanged.

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'boxes.dart';

class TrackCrypto {
  TrackCrypto({
    required this.ivSize,
    required this.kid,
    required this.scheme,
  });

  final int ivSize; // default per-sample IV size from tenc (usually 8 or 16)
  final Uint8List kid; // default_KID
  final String scheme; // 'cenc' (AES-CTR) — the only scheme we decrypt
  Uint8List? key; // resolved content key (16 bytes)
}

// Rewrites an init segment in place: encv/enca -> original codec, drops
// sinf/pssh, returns the crypto info (IV size + KID + scheme) discovered from
// tenc. Null if the init carries no protected track.
TrackCrypto? sanitizeInit(List<Box> boxes) {
  TrackCrypto? crypto;
  Box? moov;
  for (final b in boxes) {
    if (b.type == 'moov') moov = b;
  }
  if (moov == null) return null;
  moov.children.removeWhere((b) => b.type == 'pssh');

  for (final trak in moov.children.where((b) => b.type == 'trak')) {
    final stbl = trak.child('mdia')?.child('minf')?.child('stbl');
    final stsd = stbl?.child('stsd');
    if (stsd == null || stsd.payload == null) continue;
    final c = _sanitizeStsd(stsd);
    crypto ??= c;
  }
  return crypto;
}

TrackCrypto? _sanitizeStsd(Box stsd) {
  final data = stsd.payload!;
  final head = data.sublist(0, 8);
  final entries = parseBoxes(data, 8, data.length);
  TrackCrypto? crypto;
  final out = BytesBuilder()..add(head);
  for (final entry in entries) {
    if (entry.type == 'encv' || entry.type == 'enca' || entry.type == 'encs') {
      final result = _transformSampleEntry(entry.toBytes());
      out.add(result.$1);
      crypto ??= result.$2;
    } else {
      out.add(entry.toBytes());
    }
  }
  stsd.payload = out.toBytes();
  return crypto;
}

(Uint8List, TrackCrypto?) _transformSampleEntry(Uint8List entry) {
  final type = fourcc(entry, 4);
  final lead = type == 'enca' ? 28 : 78;
  if (entry.length < 8 + lead) return (entry, null);

  final children = parseBoxes(entry, 8 + lead, entry.length);
  Box? sinf;
  for (final c in children) {
    if (c.type == 'sinf') sinf = c;
  }
  if (sinf == null) return (entry, null);

  final frma = sinf.child('frma');
  final originalType = (frma?.payload != null && frma!.payload!.length >= 4)
      ? fourcc(frma.payload!, 0)
      : (type == 'enca' ? 'mp4a' : 'avc1');

  var scheme = 'cenc';
  final schm = sinf.child('schm');
  if (schm?.payload != null && schm!.payload!.length >= 8) {
    scheme = fourcc(schm.payload!, 4);
  }
  TrackCrypto? crypto;
  final tenc = sinf.child('schi')?.child('tenc');
  if (tenc?.payload != null) {
    final t = tenc!.payload!;
    if (t.length >= 24) {
      final ivSize = t[7];
      final kid = t.sublist(8, 24);
      crypto = TrackCrypto(ivSize: ivSize, kid: kid, scheme: scheme);
    }
  }

  children.removeWhere((c) => c.type == 'sinf');
  final body = BytesBuilder()
    ..add(entry.sublist(8, 8 + lead))
    ..add(serializeBoxes(children));
  final rebuilt = Box(originalType, payload: body.toBytes());
  return (rebuilt.toBytes(), crypto);
}

class SampleEnc {
  SampleEnc(this.iv, this.subsamples);
  final Uint8List iv;
  // [clearBytes, encryptedBytes] pairs. Empty => whole sample encrypted.
  final List<List<int>> subsamples;
}

Uint8List decryptSample(
  Uint8List sample,
  Uint8List key,
  Uint8List iv,
  List<List<int>> subsamples,
) {
  final counter = Uint8List(16);
  counter.setRange(0, iv.length > 16 ? 16 : iv.length, iv);

  final cipher = CTRStreamCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), counter));

  final out = Uint8List.fromList(sample);
  if (subsamples.isEmpty) {
    cipher.processBytes(sample, 0, sample.length, out, 0);
    return out;
  }
  var pos = 0;
  for (final ss in subsamples) {
    final clear = ss[0];
    final enc = ss[1];
    pos += clear;
    if (enc > 0) {
      cipher.processBytes(sample, pos, enc, out, pos);
      pos += enc;
    }
  }
  return out;
}

class TrunInfo {
  TrunInfo(this.sizes, this.dataOffsetPos);
  final List<int> sizes;
  final int dataOffsetPos;
}

TrunInfo parseTrun(Uint8List p, int defaultSampleSize) {
  final flags = readU32(p, 0) & 0xffffff;
  final sampleCount = readU32(p, 4);
  var o = 8;
  var dataOffsetPos = -1;
  if (flags & 0x000001 != 0) {
    dataOffsetPos = o;
    o += 4;
  }
  if (flags & 0x000004 != 0) o += 4; // first-sample-flags
  final sizes = <int>[];
  for (var i = 0; i < sampleCount; i++) {
    if (flags & 0x000100 != 0) o += 4; // duration
    if (flags & 0x000200 != 0) {
      sizes.add(readU32(p, o));
      o += 4;
    } else {
      sizes.add(defaultSampleSize);
    }
    if (flags & 0x000400 != 0) o += 4; // flags
    if (flags & 0x000800 != 0) o += 4; // composition offset
  }
  return TrunInfo(sizes, dataOffsetPos);
}

int tfhdDefaultSampleSize(Uint8List p) {
  final flags = readU32(p, 0) & 0xffffff;
  var o = 8; // ver/flags(4) + track_ID(4)
  if (flags & 0x000001 != 0) o += 8; // base-data-offset
  if (flags & 0x000002 != 0) o += 4; // sample-description-index
  if (flags & 0x000008 != 0) o += 4; // default-sample-duration
  if (flags & 0x000010 != 0) return readU32(p, o); // default-sample-size
  return 0;
}

List<SampleEnc> parseSenc(Uint8List p, int ivSize) {
  final flags = readU32(p, 0) & 0xffffff;
  final hasSubsamples = flags & 0x000002 != 0;
  final sampleCount = readU32(p, 4);
  var o = 8;
  final out = <SampleEnc>[];
  for (var i = 0; i < sampleCount; i++) {
    final iv = p.sublist(o, o + ivSize);
    o += ivSize;
    final subs = <List<int>>[];
    if (hasSubsamples) {
      final subCount = readU16(p, o);
      o += 2;
      for (var j = 0; j < subCount; j++) {
        final clear = readU16(p, o);
        final enc = readU32(p, o + 2);
        o += 6;
        subs.add([clear, enc]);
      }
    }
    out.add(SampleEnc(iv, subs));
  }
  return out;
}

// Decrypts one media segment (moof + mdat) in place, then strips encryption
// boxes and rewrites trun data offsets. Returns clear fMP4 bytes.
Uint8List decryptFragment(List<Box> boxes, TrackCrypto crypto) {
  final key = crypto.key;
  if (key == null) return serializeBoxes(boxes);

  for (var i = 0; i < boxes.length; i++) {
    if (boxes[i].type != 'moof') continue;
    final moof = boxes[i];

    final sampleEncs = <SampleEnc>[];
    final sampleSizes = <int>[];
    for (final traf in moof.children.where((b) => b.type == 'traf')) {
      final tfhd = traf.child('tfhd');
      final defSize =
          tfhd?.payload != null ? tfhdDefaultSampleSize(tfhd!.payload!) : 0;
      final senc = traf.child('senc');
      if (senc?.payload != null) {
        sampleEncs.addAll(parseSenc(senc!.payload!, crypto.ivSize));
      }
      for (final trun in traf.children.where((b) => b.type == 'trun')) {
        if (trun.payload == null) continue;
        sampleSizes.addAll(parseTrun(trun.payload!, defSize).sizes);
      }
    }

    Box? mdat;
    for (var j = i + 1; j < boxes.length; j++) {
      if (boxes[j].type == 'moof') break;
      if (boxes[j].type == 'mdat') {
        mdat = boxes[j];
        break;
      }
    }

    if (mdat?.payload != null && sampleEncs.isNotEmpty) {
      final data = Uint8List.fromList(mdat!.payload!);
      var pos = 0;
      final n = sampleSizes.length < sampleEncs.length
          ? sampleSizes.length
          : sampleEncs.length;
      for (var s = 0; s < n; s++) {
        final size = sampleSizes[s];
        if (pos + size > data.length) break;
        final sample = data.sublist(pos, pos + size);
        final dec =
            decryptSample(sample, key, sampleEncs[s].iv, sampleEncs[s].subsamples);
        data.setRange(pos, pos + size, dec);
        pos += size;
      }
      mdat.payload = data;
    }
  }

  for (final moof in boxes.where((b) => b.type == 'moof')) {
    for (final traf in moof.children.where((b) => b.type == 'traf')) {
      traf.children.removeWhere((b) =>
          b.type == 'senc' ||
          b.type == 'saiz' ||
          b.type == 'saio' ||
          b.type == 'sbgp' ||
          b.type == 'sgpd');
    }
  }

  for (final moof in boxes.where((b) => b.type == 'moof')) {
    final moofSize = moof.size;
    var running = moofSize + 8; // start of mdat payload, relative to moof start
    for (final traf in moof.children.where((b) => b.type == 'traf')) {
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

  return serializeBoxes(boxes);
}
