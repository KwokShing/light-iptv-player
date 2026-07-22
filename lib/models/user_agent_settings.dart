enum UserAgentPreset {
  automatic('Default', null),
  android(
    'Android',
    'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/120.0.0.0 Mobile Safari/537.36',
  ),
  vlc('VLC', 'VLC/3.0.20 LibVLC/3.0.20'),
  kodi('Kodi', 'Kodi/21.0 (Windows NT 10.0; Win64; x64) App_Bitness/64'),
  chrome(
    'Chrome (Windows)',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  ),
  custom('Custom', null);

  const UserAgentPreset(this.label, this.userAgent);

  final String label;
  final String? userAgent;
}

class UserAgentSettings {
  const UserAgentSettings({
    this.preset = UserAgentPreset.automatic,
    this.customUserAgent = '',
  });

  final UserAgentPreset preset;
  final String customUserAgent;

  String? get effectiveUserAgent {
    if (preset == UserAgentPreset.custom) {
      final value = customUserAgent.trim();
      return value.isEmpty ? null : value;
    }
    return preset.userAgent;
  }

  UserAgentSettings copyWith({
    UserAgentPreset? preset,
    String? customUserAgent,
  }) => UserAgentSettings(
    preset: preset ?? this.preset,
    customUserAgent: customUserAgent ?? this.customUserAgent,
  );

  Map<String, dynamic> toJson() => {
    'preset': preset.name,
    'customUserAgent': customUserAgent,
  };

  factory UserAgentSettings.fromJson(Map<String, dynamic> json) {
    final storedPreset = json['preset'] as String?;
    var preset = UserAgentPreset.automatic;
    for (final candidate in UserAgentPreset.values) {
      if (candidate.name == storedPreset) {
        preset = candidate;
        break;
      }
    }
    return UserAgentSettings(
      preset: preset,
      customUserAgent: (json['customUserAgent'] as String?) ?? '',
    );
  }
}
