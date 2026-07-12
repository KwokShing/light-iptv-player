// ISO-BMFF (MP4) box tree parsing/serialisation and big-endian byte helpers.
//
// Extracted verbatim from the original `dash_clearkey.dart` (the box model,
// `_parseBoxes`/`_serializeBoxes`, and the u16/u32/u64 readers) and made
// public so both the CENC decryptor (`cenc.dart`) and the fMP4 muxer
// (`fmp4_muxer.dart`) can share one box implementation.

import 'dart:typed_data';

int readU16(List<int> b, int o) => (b[o] << 8) | b[o + 1];

int readU32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int readU64(List<int> b, int o) {
  final hi = readU32(b, o);
  final lo = readU32(b, o + 4);
  return hi * 0x100000000 + lo;
}

void writeU32(List<int> b, int o, int v) {
  b[o] = (v >> 24) & 0xff;
  b[o + 1] = (v >> 16) & 0xff;
  b[o + 2] = (v >> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

Uint8List u32(int v) {
  final out = Uint8List(4);
  writeU32(out, 0, v);
  return out;
}

String fourcc(List<int> b, int o) => String.fromCharCodes(b.sublist(o, o + 4));

Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// Box types that contain child boxes (and nothing else before them). Sample
// entry boxes (encv/enca/avc1/...) and `stsd` are NOT in this set because they
// carry fixed-size leading fields before their children; those are handled
// explicitly during init-segment sanitisation.
const Set<String> containerTypes = {
  'moov', 'trak', 'mdia', 'minf', 'stbl', 'moof', 'traf', 'mvex', 'edts',
  'dinf', 'udta', 'mfra', 'skip', 'meco', 'strk',
  // Protection scheme containers.
  'sinf', 'schi',
};

class Box {
  Box(this.type, {this.payload, List<Box>? children})
      : children = children ?? [];

  String type;
  // Leaf payload (bytes after the 8-byte size+type header). Null for containers.
  Uint8List? payload;
  List<Box> children;

  bool get isContainer => payload == null;

  // Total serialised size including the 8-byte header.
  int get size =>
      8 +
      (isContainer
          ? children.fold<int>(0, (sum, c) => sum + c.size)
          : payload!.length);

  void writeTo(BytesBuilder out) {
    out.add(u32(size));
    out.add(Uint8List.fromList(type.codeUnits));
    if (isContainer) {
      for (final c in children) {
        c.writeTo(out);
      }
    } else {
      out.add(payload!);
    }
  }

  Uint8List toBytes() {
    final bb = BytesBuilder();
    writeTo(bb);
    return bb.toBytes();
  }

  Box? child(String type) {
    for (final c in children) {
      if (c.type == type) return c;
    }
    return null;
  }
}

/// Parses a flat/nested sequence of boxes from [data] between [start, end).
List<Box> parseBoxes(Uint8List data, int start, int end) {
  final boxes = <Box>[];
  var o = start;
  while (o + 8 <= end) {
    var boxSize = readU32(data, o);
    final type = fourcc(data, o + 4);
    var headerSize = 8;
    if (boxSize == 1) {
      boxSize = readU64(data, o + 8);
      headerSize = 16;
    } else if (boxSize == 0) {
      boxSize = end - o;
    }
    if (boxSize < headerSize || o + boxSize > end) break;
    final contentStart = o + headerSize;
    final contentEnd = o + boxSize;
    if (containerTypes.contains(type)) {
      boxes.add(Box(type, children: parseBoxes(data, contentStart, contentEnd)));
    } else {
      boxes.add(Box(type, payload: data.sublist(contentStart, contentEnd)));
    }
    o = contentEnd;
  }
  return boxes;
}

Uint8List serializeBoxes(List<Box> boxes) {
  final bb = BytesBuilder();
  for (final b in boxes) {
    b.writeTo(bb);
  }
  return bb.toBytes();
}
