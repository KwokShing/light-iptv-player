import '../models/user_agent_settings.dart';

/// Process-wide User-Agent override, mirroring ProxyService's global runtime
/// state so every IPTV HTTP client sees changes without being recreated.
class UserAgentService {
  UserAgentService._();

  static String? _current;

  static String? get current => _current;

  static void apply(UserAgentSettings settings) {
    _current = settings.effectiveUserAgent;
  }

  static String resolve(String fallback) => _current ?? fallback;

  static Map<String, String>? get headers =>
      _current == null ? null : {'User-Agent': _current!};
}
