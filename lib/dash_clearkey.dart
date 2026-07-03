// DASH ClearKey playback support.
//
// libmpv (via media_kit) can demux plain MPEG-DASH but has no CENC/ClearKey
// decryption. dash.js delegates decryption to the browser CDM, and libdash
// only parses the manifest and downloads segments — neither decrypts bytes
// itself. So this module fills that gap: a local HTTP proxy that
//
//   1. fetches and rewrites the MPD so every segment URL points back at us
//      (preserving $Number$/$Time$ templates so mpv's DASH demuxer keeps
//      driving audio/video sync), and
//   2. decrypts each requested segment on the fly — AES-128-CTR (CENC scheme
//      'cenc') — then strips the encryption signalling boxes so libmpv only
//      ever sees clear fMP4.
//
// The decryption/box-rewriting is the equivalent of Bento4's `mp4decrypt`,
// implemented in Dart. It targets the common live-DASH case: fragmented MP4,
// 'cenc' (AES-CTR) subsample encryption, per-sample IVs carried in `senc`.
//
// Scope / known limitations:
//   * Only the 'cenc' scheme (AES-CTR) is handled, not 'cbcs' (AES-CBC).
//   * `saiz`/`saio`-referenced aux info is read; the standalone `senc` box is
//     the primary path (what these IPTV streams use).
//   * default-base-is-moof addressing is assumed (the DASH norm).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

// ---------------------------------------------------------------------------
// Big-endian byte helpers
// ---------------------------------------------------------------------------

int _readU16(List<int> b, int o) => (b[o] << 8) | b[o + 1];

int _readU32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _readU64(List<int> b, int o) {
  final hi = _readU32(b, o);
  final lo = _readU32(b, o + 4);
  return hi * 0x100000000 + lo;
}

void _writeU32(List<int> b, int o, int v) {
  b[o] = (v >> 24) & 0xff;
  b[o + 1] = (v >> 16) & 0xff;
  b[o + 2] = (v >> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

Uint8List _u32(int v) {
  final out = Uint8List(4);
  _writeU32(out, 0, v);
  return out;
}

String _fourcc(List<int> b, int o) =>
    String.fromCharCodes(b.sublist(o, o + 4));

Uint8List _hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// ---------------------------------------------------------------------------
// ISO-BMFF box tree
// ---------------------------------------------------------------------------

// Box types that contain child boxes (and nothing else before them). Sample
// entry boxes (encv/enca/avc1/...) and `stsd` are NOT in this set because they
// carry fixed-size leading fields before their children; those are handled
// explicitly during init-segment sanitisation.
const _containerTypes = {
  'moov', 'trak', 'mdia', 'minf', 'stbl', 'moof', 'traf', 'mvex', 'edts',
  'dinf', 'udta', 'mfra', 'skip', 'meco', 'strk',
  // Protection scheme containers: sinf holds frma/schm/schi, and schi holds
  // tenc — without descending into these we can't recover the original codec
  // or the KID/IV needed to decrypt.
  'sinf', 'schi',
};

class _Box {
  _Box(this.type, {this.payload, List<_Box>? children})
    : children = children ?? [];

  String type;
  // Leaf payload (bytes after the 8-byte size+type header). Null for containers.
  Uint8List? payload;
  List<_Box> children;

  bool get isContainer => payload == null;

  // Total serialised size including the 8-byte header.
  int get size => 8 + (isContainer
      ? children.fold<int>(0, (sum, c) => sum + c.size)
      : payload!.length);

  void writeTo(BytesBuilder out) {
    out.add(_u32(size));
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

  _Box? child(String type) {
    for (final c in children) {
      if (c.type == type) return c;
    }
    return null;
  }
}

// Parse a flat/nested sequence of boxes from [data] between [start,end).
List<_Box> _parseBoxes(Uint8List data, int start, int end) {
  final boxes = <_Box>[];
  var o = start;
  while (o + 8 <= end) {
    var boxSize = _readU32(data, o);
    final type = _fourcc(data, o + 4);
    var headerSize = 8;
    if (boxSize == 1) {
      // 64-bit largesize.
      boxSize = _readU64(data, o + 8);
      headerSize = 16;
    } else if (boxSize == 0) {
      // Extends to end of file.
      boxSize = end - o;
    }
    if (boxSize < headerSize || o + boxSize > end) break;
    final contentStart = o + headerSize;
    final contentEnd = o + boxSize;
    if (_containerTypes.contains(type)) {
      boxes.add(
        _Box(type, children: _parseBoxes(data, contentStart, contentEnd)),
      );
    } else {
      boxes.add(
        _Box(type, payload: data.sublist(contentStart, contentEnd)),
      );
    }
    o = contentEnd;
  }
  return boxes;
}

Uint8List _serializeBoxes(List<_Box> boxes) {
  final bb = BytesBuilder();
  for (final b in boxes) {
    b.writeTo(bb);
  }
  return bb.toBytes();
}

// ---------------------------------------------------------------------------
// CENC decryption
// ---------------------------------------------------------------------------

class _TrackCrypto {
  _TrackCrypto({
    required this.ivSize,
    required this.kid,
    required this.scheme,
  });

  final int ivSize; // default per-sample IV size from tenc (usually 8 or 16)
  final Uint8List kid; // default_KID
  final String scheme; // 'cenc' (AES-CTR) — the only scheme we decrypt
  Uint8List? key; // resolved content key (16 bytes)
}

// Rewrites an init segment in place: turns `encv`/`enca` sample entries back
// into their original codec, drops `sinf`/`pssh`, and returns the crypto info
// (IV size + KID + scheme) discovered from `tenc`. Returns null if the init
// carries no protected track.
_TrackCrypto? _sanitizeInit(List<_Box> boxes) {
  _TrackCrypto? crypto;
  _Box? moov;
  for (final b in boxes) {
    if (b.type == 'moov') moov = b;
  }
  if (moov == null) return null;
  moov.children.removeWhere((b) => b.type == 'pssh');

  for (final trak in moov.children.where((b) => b.type == 'trak')) {
    final stbl = trak
        .child('mdia')
        ?.child('minf')
        ?.child('stbl');
    final stsd = stbl?.child('stsd');
    if (stsd == null || stsd.payload == null) continue;
    final c = _sanitizeStsd(stsd);
    crypto ??= c;
  }
  return crypto;
}

// Rewrites the entries inside an `stsd` leaf box, returning crypto info from
// the first protected entry found.
_TrackCrypto? _sanitizeStsd(_Box stsd) {
  final data = stsd.payload!;
  // version(1)+flags(3)+entry_count(4), then sample entry boxes.
  final head = data.sublist(0, 8);
  final entries = _parseBoxes(data, 8, data.length);
  _TrackCrypto? crypto;
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

// Converts a single `encv`/`enca` sample entry back to its original codec,
// removing the `sinf` protection box. Returns (newEntryBytes, crypto?).
(Uint8List, _TrackCrypto?) _transformSampleEntry(Uint8List entry) {
  final type = _fourcc(entry, 4);
  // Fixed leading fields before child boxes: VisualSampleEntry=78, Audio=28.
  final lead = type == 'enca' ? 28 : 78;
  if (entry.length < 8 + lead) return (entry, null);

  final children = _parseBoxes(entry, 8 + lead, entry.length);
  _Box? sinf;
  for (final c in children) {
    if (c.type == 'sinf') sinf = c;
  }
  if (sinf == null) return (entry, null);

  // Original codec fourcc from frma.
  final frma = sinf.child('frma');
  final originalType = (frma?.payload != null && frma!.payload!.length >= 4)
      ? _fourcc(frma.payload!, 0)
      : (type == 'enca' ? 'mp4a' : 'avc1');

  // Scheme + tenc from schm/schi.
  var scheme = 'cenc';
  final schm = sinf.child('schm');
  if (schm?.payload != null && schm!.payload!.length >= 8) {
    scheme = _fourcc(schm.payload!, 4);
  }
  _TrackCrypto? crypto;
  final tenc = sinf.child('schi')?.child('tenc');
  if (tenc?.payload != null) {
    final t = tenc!.payload!;
    // ver/flags(4), reserved(1), reserved-or-block(1), isProtected(1),
    // ivSize(1), KID(16)...
    if (t.length >= 24) {
      final ivSize = t[7];
      final kid = t.sublist(8, 24);
      crypto = _TrackCrypto(ivSize: ivSize, kid: kid, scheme: scheme);
    }
  }

  // Rebuild the entry with the original type and without sinf.
  children.removeWhere((c) => c.type == 'sinf');
  final body = BytesBuilder()
    ..add(entry.sublist(8, 8 + lead))
    ..add(_serializeBoxes(children));
  final rebuilt = _Box(originalType, payload: body.toBytes());
  return (rebuilt.toBytes(), crypto);
}

class _SampleEnc {
  _SampleEnc(this.iv, this.subsamples);
  final Uint8List iv; // per-sample IV bytes (ivSize long)
  // List of [clearBytes, encryptedBytes] pairs. Empty => whole sample encrypted.
  final List<List<int>> subsamples;
}

// AES-128-CTR decrypt a single CENC sample. Clear subsample ranges are copied
// unchanged; encrypted ranges are fed through one continuous CTR keystream
// (the counter carries across subsamples within a sample).
Uint8List _decryptSample(
  Uint8List sample,
  Uint8List key,
  Uint8List iv,
  List<List<int>> subsamples,
) {
  // Build the 16-byte counter block: IV in the high bytes, zero-filled.
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
    pos += clear; // clear bytes: leave as-is
    if (enc > 0) {
      cipher.processBytes(sample, pos, enc, out, pos);
      pos += enc;
    }
  }
  return out;
}

// Reads sample sizes from a trun payload, using tfhd's default when the trun
// omits per-sample sizes. Returns (sampleSizes, dataOffsetFieldPos or -1).
class _TrunInfo {
  _TrunInfo(this.sizes, this.dataOffsetPos);
  final List<int> sizes;
  final int dataOffsetPos; // byte offset of data_offset within trun payload
}

_TrunInfo _parseTrun(Uint8List p, int defaultSampleSize) {
  final flags = _readU32(p, 0) & 0xffffff;
  final sampleCount = _readU32(p, 4);
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
      sizes.add(_readU32(p, o));
      o += 4;
    } else {
      sizes.add(defaultSampleSize);
    }
    if (flags & 0x000400 != 0) o += 4; // flags
    if (flags & 0x000800 != 0) o += 4; // composition offset
  }
  return _TrunInfo(sizes, dataOffsetPos);
}

int _tfhdDefaultSampleSize(Uint8List p) {
  final flags = _readU32(p, 0) & 0xffffff;
  var o = 8; // ver/flags(4) + track_ID(4)
  if (flags & 0x000001 != 0) o += 8; // base-data-offset
  if (flags & 0x000002 != 0) o += 4; // sample-description-index
  if (flags & 0x000008 != 0) o += 4; // default-sample-duration
  if (flags & 0x000010 != 0) return _readU32(p, o); // default-sample-size
  return 0;
}

List<_SampleEnc> _parseSenc(Uint8List p, int ivSize) {
  final flags = _readU32(p, 0) & 0xffffff;
  final hasSubsamples = flags & 0x000002 != 0;
  final sampleCount = _readU32(p, 4);
  var o = 8;
  final out = <_SampleEnc>[];
  for (var i = 0; i < sampleCount; i++) {
    final iv = p.sublist(o, o + ivSize);
    o += ivSize;
    final subs = <List<int>>[];
    if (hasSubsamples) {
      final subCount = _readU16(p, o);
      o += 2;
      for (var j = 0; j < subCount; j++) {
        final clear = _readU16(p, o);
        final enc = _readU32(p, o + 2);
        o += 6;
        subs.add([clear, enc]);
      }
    }
    out.add(_SampleEnc(iv, subs));
  }
  return out;
}

// Decrypts one media segment (moof + mdat), returning clear fMP4 bytes.
Uint8List _decryptFragment(List<_Box> boxes, _TrackCrypto crypto) {
  final key = crypto.key;
  if (key == null) return _serializeBoxes(boxes);

  // Decrypt each moof/mdat pair in order. Live DASH segments usually carry a
  // single pair, but multi-fragment segments are handled too.
  for (var i = 0; i < boxes.length; i++) {
    if (boxes[i].type != 'moof') continue;
    final moof = boxes[i];

    final sampleEncs = <_SampleEnc>[];
    final sampleSizes = <int>[];
    for (final traf in moof.children.where((b) => b.type == 'traf')) {
      final tfhd = traf.child('tfhd');
      final defSize = tfhd?.payload != null
          ? _tfhdDefaultSampleSize(tfhd!.payload!)
          : 0;
      final senc = traf.child('senc');
      if (senc?.payload != null) {
        sampleEncs.addAll(_parseSenc(senc!.payload!, crypto.ivSize));
      }
      for (final trun in traf.children.where((b) => b.type == 'trun')) {
        if (trun.payload == null) continue;
        sampleSizes.addAll(_parseTrun(trun.payload!, defSize).sizes);
      }
    }

    // Find the mdat belonging to this moof (before the next moof).
    _Box? mdat;
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
        final dec = _decryptSample(
          sample,
          key,
          sampleEncs[s].iv,
          sampleEncs[s].subsamples,
        );
        data.setRange(pos, pos + size, dec);
        pos += size;
      }
      mdat.payload = data;
    }
  }

  // Strip encryption-signalling boxes from every traf.
  for (final moof in boxes.where((b) => b.type == 'moof')) {
    for (final traf in moof.children.where((b) => b.type == 'traf')) {
      traf.children.removeWhere(
        (b) => b.type == 'senc' || b.type == 'saiz' || b.type == 'saio' ||
            b.type == 'sbgp' || b.type == 'sgpd',
      );
    }
  }

  // Aux boxes are gone, so moof shrank: rewrite each trun's data_offset so
  // samples still resolve into the (unchanged) mdat that follows the moof.
  for (final moof in boxes.where((b) => b.type == 'moof')) {
    final moofSize = moof.size;
    var running = moofSize + 8; // start of mdat payload, relative to moof start
    for (final traf in moof.children.where((b) => b.type == 'traf')) {
      final tfhd = traf.child('tfhd');
      final defSize = tfhd?.payload != null
          ? _tfhdDefaultSampleSize(tfhd!.payload!)
          : 0;
      for (final trun in traf.children.where((b) => b.type == 'trun')) {
        if (trun.payload == null) continue;
        final info = _parseTrun(trun.payload!, defSize);
        if (info.dataOffsetPos >= 0) {
          _writeU32(trun.payload!, info.dataOffsetPos, running);
        }
        running += info.sizes.fold<int>(0, (s, x) => s + x);
      }
    }
  }

  return _serializeBoxes(boxes);
}

// ---------------------------------------------------------------------------
// MPD rewriting
// ---------------------------------------------------------------------------

// Percent-encodes [url] for use inside a query value, but leaves DASH template
// tokens ($Number$, $Time$, $RepresentationID$, $Bandwidth$, $$) untouched so
// mpv/ffmpeg still substitutes them before requesting the proxied segment.
String _encodePreservingTemplates(String url) {
  final re = RegExp(r'\$[^$]*\$');
  final buf = StringBuffer();
  var last = 0;
  for (final m in re.allMatches(url)) {
    buf.write(Uri.encodeComponent(url.substring(last, m.start)));
    buf.write(m.group(0));
    last = m.end;
  }
  buf.write(Uri.encodeComponent(url.substring(last)));
  return buf.toString();
}

String _dirOf(String url) {
  final q = url.indexOf('?');
  final path = q >= 0 ? url.substring(0, q) : url;
  final slash = path.lastIndexOf('/');
  return slash >= 0 ? path.substring(0, slash + 1) : '$path/';
}

// Resolves a (possibly relative) template/URL against [base], preserving any
// $...$ template tokens (so Uri normalisation never mangles them).
String _resolveKeepingTemplates(String base, String template) {
  if (template.startsWith('http://') || template.startsWith('https://')) {
    return template;
  }
  final baseUri = Uri.parse(base);
  if (template.startsWith('/')) {
    return '${baseUri.scheme}://${baseUri.authority}$template';
  }
  return _dirOf(base) + template;
}

// Effective base URL for [el], applying any <BaseURL> found along the ancestor
// chain (resolved against the MPD's own URL).
String _baseForElement(XmlElement el, String mpdBase) {
  final chain = <XmlElement>[];
  XmlNode? n = el;
  while (n is XmlElement) {
    chain.add(n);
    n = n.parent;
  }
  var base = mpdBase;
  for (final a in chain.reversed) {
    for (final child in a.children.whereType<XmlElement>()) {
      if (child.name.local == 'BaseURL') {
        base = Uri.parse(base).resolve(child.innerText.trim()).toString();
        break;
      }
    }
  }
  return base;
}

class _MpdRewriteResult {
  _MpdRewriteResult(this.xml, this.cryptoByToken);
  final String xml;
  final Map<int, _TrackCrypto?> cryptoByToken;
}

_MpdRewriteResult _rewriteMpd(
  String mpdText,
  String mpdUrl,
  String proxyBase,
) {
  final doc = XmlDocument.parse(mpdText);
  final cryptoByToken = <int, _TrackCrypto?>{};
  var tokenSeq = 0;

  // Keep only plain audio/video AdaptationSets. Drop:
  //   * trick-mode tracks (I-frame/thumbnail, flagged with a trickmode
  //     EssentialProperty) — ffmpeg may treat them as normal video, and
  //   * text/subtitle tracks (stpp/ttml/wvtt) — this stream's TTML inits carry
  //     a zero mvhd timescale that the bundled ffmpeg chokes on
  //     ("Invalid mvhd time scale 0"), which takes the whole player down.
  // A clean single video + audio manifest is all mpv needs.
  for (final as in doc.findAllElements('AdaptationSet').toList()) {
    final reps = as.findElements('Representation');
    final mimes = <String>[
      as.getAttribute('mimeType') ?? '',
      as.getAttribute('contentType') ?? '',
      for (final r in reps) r.getAttribute('mimeType') ?? '',
    ].map((s) => s.toLowerCase()).toList();
    final codecs = <String>[
      as.getAttribute('codecs') ?? '',
      for (final r in reps) r.getAttribute('codecs') ?? '',
    ].map((s) => s.toLowerCase()).toList();

    final isTrick = as.children.whereType<XmlElement>().any((e) =>
        e.name.local == 'EssentialProperty' &&
        (e.getAttribute('schemeIdUri') ?? '').contains('trickmode'));
    final isText = mimes.any((m) =>
            m == 'text' ||
            m.contains('ttml') ||
            m.startsWith('application') ||
            m.startsWith('text')) ||
        codecs.any((c) =>
            c.contains('stpp') || c.contains('wvtt') || c.contains('ttml'));

    if (isTrick || isText) as.parent?.children.remove(as);
  }

  String proxied(String base, String value, int token) {
    final abs = _resolveKeepingTemplates(base, value);
    return '$proxyBase/seg?r=$token&u=${_encodePreservingTemplates(abs)}';
  }

  for (final st in doc.findAllElements('SegmentTemplate')) {
    final base = _baseForElement(st, mpdUrl);
    final token = tokenSeq++;
    cryptoByToken[token] = null;
    for (final attr in ['initialization', 'media', 'index']) {
      final v = st.getAttribute(attr);
      if (v != null && v.isNotEmpty) {
        st.setAttribute(attr, proxied(base, v, token));
      }
    }
  }

  // SegmentList entries carry concrete (usually unnumbered) URLs.
  for (final sl in doc.findAllElements('SegmentList')) {
    final base = _baseForElement(sl, mpdUrl);
    final token = tokenSeq++;
    cryptoByToken[token] = null;
    for (final init in sl.findElements('Initialization')) {
      final v = init.getAttribute('sourceURL');
      if (v != null && v.isNotEmpty) {
        init.setAttribute('sourceURL', proxied(base, v, token));
      }
    }
    for (final seg in sl.findElements('SegmentURL')) {
      for (final attr in ['media', 'index']) {
        final v = seg.getAttribute(attr);
        if (v != null && v.isNotEmpty) {
          seg.setAttribute(attr, proxied(base, v, token));
        }
      }
    }
  }

  // Drop <BaseURL> (our URLs are now absolute) and ContentProtection (segments
  // are handed to mpv already decrypted).
  for (final name in ['BaseURL', 'ContentProtection']) {
    final toRemove = doc.findAllElements(name).toList();
    for (final e in toRemove) {
      e.parent?.children.remove(e);
    }
  }

  return _MpdRewriteResult(doc.toXmlString(), cryptoByToken);
}

// ---------------------------------------------------------------------------
// Local decrypting proxy
// ---------------------------------------------------------------------------

class DashClearKeyProxy {
  HttpServer? _server;
  String _mpdUrl = '';
  // The manifest endpoint (e.g. mytv265.php?id=...) often 302s to a per-request
  // session .mpd on a load-balanced edge. Re-hitting it on every refresh spins
  // up a NEW session on a possibly different edge each time, which breaks live
  // continuity. So after the first resolution we pin the resolved edge URL and
  // refresh from it, keeping one stable session.
  String _resolvedMpdUrl = '';
  // KID (hex, lowercase, no dashes) -> content key (hex).
  Map<String, String> _keys = {};
  final Map<int, _TrackCrypto?> _cryptoByToken = {};
  final http.Client _client = http.Client();

  static const Map<String, String> _originHeaders = {
    'User-Agent': 'Mozilla/5.0',
  };

  bool get isRunning => _server != null;

  // Starts the proxy for [mpdUrl] with the given ClearKey [keys] (kidHex ->
  // keyHex) and returns the local manifest URL to hand to the player.
  Future<String> start(String mpdUrl, Map<String, String> keys) async {
    await stop();
    _mpdUrl = mpdUrl;
    _keys = {
      for (final e in keys.entries)
        e.key.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase():
            e.value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase(),
    };
    _cryptoByToken.clear();
    _resolvedMpdUrl = '';
    _sanityLogged = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (Object e) => debugPrint('proxy: $e'));
    return 'http://127.0.0.1:${server.port}/manifest';
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  void dispose() {
    stop();
    _client.close();
  }

  String get _proxyBase => 'http://127.0.0.1:${_server?.port ?? 0}';

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/manifest') {
        await _serveManifest(req);
      } else if (path == '/seg') {
        await _serveSegment(req);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (error) {
      debugPrint('proxy handler error: $error');
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveManifest(HttpRequest req) async {
    // Follow redirects manually so we know the FINAL manifest URL: relative
    // segment templates must resolve against it, not the original (the
    // mytv265.php?id=... style endpoints 302 to a CDN .mpd). After the first
    // resolution, refresh from the pinned edge URL so we stay in one session
    // instead of spawning a new one (on a new edge) every refresh.
    final source = _resolvedMpdUrl.isNotEmpty ? _resolvedMpdUrl : _mpdUrl;
    final fetched = await _fetchFollowingRedirects(source);
    final finalUrl = fetched.$1;
    _resolvedMpdUrl = finalUrl;
    final body = utf8.decode(fetched.$2, allowMalformed: true);
    debugPrint(
      'proxy: manifest fetched (${fetched.$2.length}B), final URL=$finalUrl',
    );
    final rewritten = _rewriteMpd(body, finalUrl, _proxyBase);
    // Keep any crypto we already parsed; register newly-seen tokens.
    rewritten.cryptoByToken.forEach((token, _) {
      _cryptoByToken.putIfAbsent(token, () => null);
    });
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'dash+xml')
      ..add(utf8.encode(rewritten.xml));
    await req.response.close();
  }

  // GETs [url], following redirects manually, and returns (finalUrl, body).
  Future<(String, Uint8List)> _fetchFollowingRedirects(String url) async {
    var current = Uri.parse(url);
    for (var i = 0; i < 10; i++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(_originHeaders);
      final streamed = await _client.send(request);
      final loc = streamed.headers['location'];
      if (streamed.statusCode >= 300 &&
          streamed.statusCode < 400 &&
          loc != null) {
        await streamed.stream.drain<void>();
        current = current.resolve(loc);
        continue;
      }
      final bytes = await streamed.stream.toBytes();
      return (current.toString(), bytes);
    }
    throw Exception('Too many redirects fetching $url');
  }

  Future<void> _serveSegment(HttpRequest req) async {
    final url = req.uri.queryParameters['u'];
    final token = int.tryParse(req.uri.queryParameters['r'] ?? '');
    if (url == null || url.isEmpty) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    final res = await _client.get(Uri.parse(url), headers: _originHeaders);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      debugPrint('proxy: segment HTTP ${res.statusCode} for $url');
      req.response.statusCode = res.statusCode;
      await req.response.close();
      return;
    }
    final data = Uint8List.fromList(res.bodyBytes);
    Uint8List out;
    try {
      out = _processSegment(data, token);
    } catch (error, st) {
      debugPrint('proxy: segment decrypt failed for $url: $error\n$st');
      out = data; // fall back to passing the (encrypted) bytes through
    }
    debugPrint(
      'proxy: segment r=$token in=${data.length}B out=${out.length}B '
      'kind=${_segmentKind(data)} url=$url',
    );

    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('video', 'mp4')
      ..headers.contentLength = out.length
      ..add(out);
    await req.response.close();
  }

  String _segmentKind(Uint8List data) {
    final boxes = _parseBoxes(data, 0, data.length);
    if (boxes.any((b) => b.type == 'moov')) return 'init';
    if (boxes.any((b) => b.type == 'moof')) return 'media';
    final types = boxes.map((b) => b.type).take(4).join(',');
    return 'other[$types]';
  }

  // Decrypts/sanitises a fetched segment. Init segments (contain `moov`) yield
  // and cache the track crypto; media segments (`moof`) are decrypted with it.
  Uint8List _processSegment(Uint8List data, int? token) {
    final boxes = _parseBoxes(data, 0, data.length);
    final hasMoov = boxes.any((b) => b.type == 'moov');
    final hasMoof = boxes.any((b) => b.type == 'moof');

    if (hasMoov) {
      final crypto = _sanitizeInit(boxes);
      if (crypto != null) {
        crypto.key = _resolveKey(crypto.kid);
        if (token != null) _cryptoByToken[token] = crypto;
      }
      return _serializeBoxes(boxes);
    }

    if (hasMoof) {
      final crypto = (token != null ? _cryptoByToken[token] : null) ??
          _fallbackCrypto();
      if (crypto?.key != null) {
        final out = _decryptFragment(boxes, crypto!);
        if (!_sanityLogged) {
          _sanityLogged = true;
          debugPrint(
            'proxy: decrypt-sanity r=$token '
            '${_decryptSanity(_parseBoxes(out, 0, out.length))}',
          );
        }
        return out;
      }
      debugPrint('proxy: media r=$token has no key; passing through encrypted');
    }
    return data;
  }

  bool _sanityLogged = false;

  Uint8List? _resolveKey(Uint8List kid) {
    final kidHex = _bytesToHex(kid);
    final keyHex = _keys[kidHex] ?? (_keys.length == 1 ? _keys.values.first : null);
    return keyHex == null ? null : _hexToBytes(keyHex);
  }

  // When a media segment arrives before its init (rare) and only one key is
  // configured, assume the common 8-byte-IV 'cenc' layout.
  _TrackCrypto? _fallbackCrypto() {
    if (_keys.length != 1) return null;
    return _TrackCrypto(
      ivSize: 8,
      kid: Uint8List(16),
      scheme: 'cenc',
    )..key = _hexToBytes(_keys.values.first);
  }
}

// Parses a KODIPROP-style clearkey `license_key` value into a kidHex->keyHex
// map. Accepts `KID:KEY` pairs (hex), comma/whitespace separated.
Map<String, String> parseClearKeyLicense(String licenseKey) {
  final keys = <String, String>{};
  for (final part in licenseKey.split(RegExp(r'[,\s]+'))) {
    final pair = part.trim();
    if (pair.isEmpty || !pair.contains(':')) continue;
    final idx = pair.indexOf(':');
    final kid = pair.substring(0, idx).replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
    final key = pair.substring(idx + 1).replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
    if (kid.length == 32 && key.length == 32) keys[kid] = key;
  }
  return keys;
}

// (debug helpers removed after validation)
// Sanity check on a decrypted fragment: reads the first sample's leading
// length-prefixed NAL unit and reports whether it looks like a valid H.264/265
// access unit. Used to distinguish "wrong key => garbage" from a decode issue.
String _decryptSanity(List<_Box> boxes) {
  _Box? moof;
  _Box? mdat;
  for (final b in boxes) {
    if (b.type == 'moof') moof ??= b;
    if (b.type == 'mdat') mdat ??= b;
  }
  final trun = moof?.child('traf')?.child('trun');
  if (trun?.payload == null || mdat?.payload == null) return 'no moof/mdat';
  final tfhd = moof!.child('traf')!.child('tfhd');
  final defSize =
      tfhd?.payload != null ? _tfhdDefaultSampleSize(tfhd!.payload!) : 0;
  final sizes = _parseTrun(trun!.payload!, defSize).sizes;
  if (sizes.isEmpty) return 'no samples';
  final data = mdat!.payload!;
  final first = sizes.first;
  if (first < 6 || first > data.length) return 'bad first size=$first';
  // 4-byte NAL length prefix, then NAL header.
  final nalLen = _readU32(data, 0);
  final b0 = data[4];
  final hevcType = (b0 >> 1) & 0x3f;
  final avcType = b0 & 0x1f;
  final head = _bytesToHex(data.sublist(0, 8));
  final plausible = nalLen > 0 && nalLen <= first;
  return 'firstSampleSize=$first nalLen=$nalLen '
      'hevcNalType=$hevcType avcNalType=$avcType head=$head '
      '=> ${plausible ? "PLAUSIBLE(key likely OK)" : "GARBAGE(key likely WRONG)"}';
}
