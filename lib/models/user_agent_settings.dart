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

/// A user-defined, named User-Agent entry (e.g. "ua1", "ua2") that can be saved
/// and re-selected later.
class SavedUserAgent {
  const SavedUserAgent({
    required this.id,
    required this.name,
    required this.value,
  });

  final String id;
  final String name;
  final String value;

  SavedUserAgent copyWith({String? name, String? value}) => SavedUserAgent(
    id: id,
    name: name ?? this.name,
    value: value ?? this.value,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'value': value,
  };

  factory SavedUserAgent.fromJson(Map<String, dynamic> json) => SavedUserAgent(
    id: (json['id'] as String?) ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: (json['name'] as String?) ?? '',
    value: (json['value'] as String?) ?? '',
  );
}

class UserAgentSettings {
  const UserAgentSettings({
    this.preset = UserAgentPreset.automatic,
    this.customUserAgent = '',
    this.savedAgents = const [],
    this.selectedAgentId,
  });

  final UserAgentPreset preset;
  final String customUserAgent;

  /// User-defined named User-Agent entries.
  final List<SavedUserAgent> savedAgents;

  /// The id of the currently selected saved agent, when [preset] is
  /// [UserAgentPreset.custom].
  final String? selectedAgentId;

  SavedUserAgent? get selectedAgent {
    if (selectedAgentId == null) return null;
    for (final agent in savedAgents) {
      if (agent.id == selectedAgentId) return agent;
    }
    return null;
  }

  String? get effectiveUserAgent {
    if (preset == UserAgentPreset.custom) {
      final selected = selectedAgent;
      final value = (selected?.value ?? customUserAgent).trim();
      return value.isEmpty ? null : value;
    }
    return preset.userAgent;
  }

  UserAgentSettings copyWith({
    UserAgentPreset? preset,
    String? customUserAgent,
    List<SavedUserAgent>? savedAgents,
    String? selectedAgentId,
    bool clearSelectedAgentId = false,
  }) => UserAgentSettings(
    preset: preset ?? this.preset,
    customUserAgent: customUserAgent ?? this.customUserAgent,
    savedAgents: savedAgents ?? this.savedAgents,
    selectedAgentId: clearSelectedAgentId
        ? null
        : (selectedAgentId ?? this.selectedAgentId),
  );

  Map<String, dynamic> toJson() => {
    'preset': preset.name,
    'customUserAgent': customUserAgent,
    'savedAgents': [for (final agent in savedAgents) agent.toJson()],
    'selectedAgentId': selectedAgentId,
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
    final rawAgents = json['savedAgents'];
    final savedAgents = <SavedUserAgent>[
      if (rawAgents is List)
        for (final entry in rawAgents)
          if (entry is Map<String, dynamic>) SavedUserAgent.fromJson(entry),
    ];
    return UserAgentSettings(
      preset: preset,
      customUserAgent: (json['customUserAgent'] as String?) ?? '',
      savedAgents: savedAgents,
      selectedAgentId: json['selectedAgentId'] as String?,
    );
  }
}
