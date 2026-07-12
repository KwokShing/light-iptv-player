// Parses a KODIPROP-style ClearKey `license_key` value into a kidHex->keyHex
// map. Accepts `KID:KEY` pairs (hex), comma/whitespace separated. Moved out of
// the old `dash_clearkey.dart` so the model layer no longer depends on the
// removed proxy.

Map<String, String> parseClearKeyLicense(String licenseKey) {
  final keys = <String, String>{};
  for (final part in licenseKey.split(RegExp(r'[,\s]+'))) {
    final pair = part.trim();
    if (pair.isEmpty || !pair.contains(':')) continue;
    final idx = pair.indexOf(':');
    final kid = pair
        .substring(0, idx)
        .replaceAll(RegExp(r'[^0-9a-fA-F]'), '')
        .toLowerCase();
    final key = pair
        .substring(idx + 1)
        .replaceAll(RegExp(r'[^0-9a-fA-F]'), '')
        .toLowerCase();
    if (kid.length == 32 && key.length == 32) keys[kid] = key;
  }
  return keys;
}
