import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml_events.dart';

import '../models/epg.dart';

/// Parses XMLTV guide bytes into an [EpgGuide].
///
/// Designed to run inside a background isolate via `compute`: it takes the raw
/// downloaded bytes (so gzip decompression and charset decoding also happen off
/// the UI thread) and returns a fully-built, serializable guide.
///
/// Uses the streaming event parser (`parseEvents`) rather than building a full
/// DOM, because real-world XMLTV files are frequently 20-100+ MB and a DOM of
/// that size is both slow and memory-hungry.
EpgGuide parseXmltv(Uint8List bytes) {
  final xml = _decodeGuideBytes(bytes);

  // Normalized channel id -> its display names (first is preferred).
  final channelNames = <String, List<String>>{};
  final byChannelId = <String, List<EpgProgramme>>{};

  String? currentChannelId; // <channel id="..."> being read
  final channelNameBuffer = <String>[];

  // Fields of the <programme> currently being read.
  String? progChannel;
  DateTime? progStart;
  DateTime? progStop;
  String? progTitle;
  String? progDesc;
  String? progCategory;

  // Which child element's text we're currently accumulating.
  String? textTarget; // 'title' | 'desc' | 'category' | 'display-name'
  final textBuffer = StringBuffer();

  void flushText() {
    if (textTarget == null) return;
    final value = textBuffer.toString().trim();
    textBuffer.clear();
    if (value.isNotEmpty) {
      switch (textTarget) {
        case 'display-name':
          channelNameBuffer.add(value);
        case 'title':
          progTitle ??= value;
        case 'desc':
          progDesc ??= value;
        case 'category':
          progCategory ??= value;
      }
    }
    textTarget = null;
  }

  for (final event in parseEvents(xml)) {
    if (event is XmlStartElementEvent) {
      switch (event.name) {
        case 'channel':
          currentChannelId = _attr(event, 'id');
          channelNameBuffer.clear();
        case 'display-name':
          if (currentChannelId != null) {
            textTarget = 'display-name';
            textBuffer.clear();
            if (event.isSelfClosing) flushText();
          }
        case 'programme':
          progChannel = _attr(event, 'channel');
          progStart = _parseXmltvTime(_attr(event, 'start'));
          progStop = _parseXmltvTime(_attr(event, 'stop'));
          progTitle = null;
          progDesc = null;
          progCategory = null;
        case 'title':
          textTarget = 'title';
          textBuffer.clear();
          if (event.isSelfClosing) flushText();
        case 'desc':
          textTarget = 'desc';
          textBuffer.clear();
          if (event.isSelfClosing) flushText();
        case 'category':
          textTarget = 'category';
          textBuffer.clear();
          if (event.isSelfClosing) flushText();
      }
    } else if (event is XmlTextEvent) {
      if (textTarget != null) textBuffer.write(event.value);
    } else if (event is XmlCDATAEvent) {
      if (textTarget != null) textBuffer.write(event.value);
    } else if (event is XmlEndElementEvent) {
      switch (event.name) {
        case 'display-name':
        case 'title':
        case 'desc':
        case 'category':
          flushText();
        case 'channel':
          if (currentChannelId != null && channelNameBuffer.isNotEmpty) {
            channelNames[EpgGuide.normalizeKey(currentChannelId)] = List.of(
              channelNameBuffer,
            );
          }
          currentChannelId = null;
          channelNameBuffer.clear();
        case 'programme':
          if (progChannel != null &&
              progStart != null &&
              progStop != null &&
              progStop.isAfter(progStart) &&
              (progTitle?.isNotEmpty ?? false)) {
            final key = EpgGuide.normalizeKey(progChannel);
            (byChannelId[key] ??= <EpgProgramme>[]).add(
              EpgProgramme(
                start: progStart,
                stop: progStop,
                title: progTitle!,
                description: progDesc,
                category: progCategory,
              ),
            );
          }
          progChannel = null;
          progStart = null;
          progStop = null;
          progTitle = null;
          progDesc = null;
          progCategory = null;
      }
    }
  }

  // Programmes can appear out of order (and often are per-channel blocks); sort
  // each channel's list so now/next binary search is valid.
  for (final list in byChannelId.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
  }

  // Build the name -> id fallback index. Only map names that resolve to a
  // channel that actually has programmes, so a name match never dead-ends.
  final displayNameToId = <String, String>{};
  channelNames.forEach((id, names) {
    if (!byChannelId.containsKey(id)) return;
    for (final name in names) {
      displayNameToId.putIfAbsent(EpgGuide.normalizeKey(name), () => id);
    }
  });

  return EpgGuide(
    byChannelId: byChannelId,
    displayNameToId: displayNameToId,
    generatedAt: DateTime.now().toUtc(),
  );
}

String? _attr(XmlStartElementEvent event, String name) {
  for (final attr in event.attributes) {
    if (attr.name == name) return attr.value;
  }
  return null;
}

/// Decodes guide bytes: transparently gunzips gzip payloads (`.xml.gz`, which
/// most providers serve), then decodes as UTF-8 (the near-universal XMLTV
/// encoding). Runs inside the parse isolate, so it deliberately avoids the
/// platform-channel charset converter; a non-UTF-8 declaration falls back to
/// lenient UTF-8 decoding rather than failing.
String _decodeGuideBytes(Uint8List bytes) {
  var data = bytes;
  // gzip magic number 0x1f 0x8b.
  if (data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b) {
    data = Uint8List.fromList(gzip.decode(data));
  }
  // Strip a UTF-8 BOM if present.
  if (data.length >= 3 &&
      data[0] == 0xef &&
      data[1] == 0xbb &&
      data[2] == 0xbf) {
    return utf8.decode(data.sublist(3), allowMalformed: true);
  }
  return utf8.decode(data, allowMalformed: true);
}

/// Parses an XMLTV timestamp: `YYYYMMDDHHMMSS` optionally followed by a space
/// and a `+HHMM`/`-HHMM` offset (e.g. `20260712183000 +0800`). Returns the
/// instant in UTC. When no offset is given, the time is treated as UTC (the
/// XMLTV-recommended default for offset-less times).
DateTime? _parseXmltvTime(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  if (value.length < 14) return null;
  int? part(int start, int end) => int.tryParse(value.substring(start, end));
  final year = part(0, 4);
  final month = part(4, 6);
  final day = part(6, 8);
  final hour = part(8, 10);
  final minute = part(10, 12);
  final second = part(12, 14);
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null ||
      second == null) {
    return null;
  }

  var offsetMinutes = 0;
  final rest = value.substring(14).trim();
  if (rest.isNotEmpty) {
    final sign = rest[0] == '-' ? -1 : 1;
    final digits = rest.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length >= 4) {
      final oh = int.tryParse(digits.substring(0, 2)) ?? 0;
      final om = int.tryParse(digits.substring(2, 4)) ?? 0;
      offsetMinutes = sign * (oh * 60 + om);
    }
  }

  final utc = DateTime.utc(year, month, day, hour, minute, second);
  return utc.subtract(Duration(minutes: offsetMinutes));
}
