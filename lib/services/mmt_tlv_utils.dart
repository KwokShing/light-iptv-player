const _mmtTlvExtensions = ['.mmt', '.mmts', '.tlv'];

/// Whether [source] explicitly identifies an ARIB MMT/TLV stream.
bool isMmtTlvSource(String source) {
  final path = (Uri.tryParse(source)?.path ?? source).toLowerCase();
  return _mmtTlvExtensions.any(path.endsWith);
}

/// Whether an HTTP Content-Type explicitly identifies an MMT/TLV stream.
bool isMmtTlvContentType(String contentType) {
  final value = contentType.toLowerCase().split(';').first.trim();
  return value == 'video/mmt' ||
      value == 'application/mmt' ||
      value == 'video/mmts' ||
      value == 'application/mmts' ||
      value == 'video/tlv' ||
      value == 'application/tlv';
}

/// Detects consecutive ARIB TLV packets even when a live HTTP response begins
/// in the middle of a packet. Each packet is 0x7F, a constrained packet type,
/// a big-endian 16-bit payload length, then the payload.
bool looksLikeMmtTlv(List<int> bytes) {
  bool validHeader(int offset) {
    if (offset + 4 > bytes.length || bytes[offset] != 0x7f) return false;
    final type = bytes[offset + 1];
    return type <= 0x04 || type >= 0xfd;
  }

  for (var offset = 0; offset + 4 <= bytes.length; offset++) {
    if (!validHeader(offset)) continue;
    var packetOffset = offset;
    var completePackets = 0;
    while (validHeader(packetOffset)) {
      final payloadLength =
          (bytes[packetOffset + 2] << 8) | bytes[packetOffset + 3];
      packetOffset += 4 + payloadLength;
      if (packetOffset > bytes.length) break;
      completePackets++;
      if (completePackets >= 2) return true;
    }
  }
  return false;
}
