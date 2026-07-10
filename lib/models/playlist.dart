import '../constants.dart';
import '../dash_clearkey.dart';

enum SourceKind { local, online, single }

class Channel {
  const Channel({
    required this.name,
    required this.url,
    required this.group,
    this.logo,
    this.manifestType,
    this.licenseType,
    this.licenseKey,
  });

  final String name;
  final String url;
  final String group;
  final String? logo;

  // DRM / adaptive-streaming hints parsed from #KODIPROP lines that precede the
  // stream URL in the playlist. These mirror Kodi's inputstream.adaptive props:
  //   inputstream.adaptive.manifest_type  -> 'mpd' (MPEG-DASH) or 'hls'
  //   inputstream.adaptive.license_type   -> e.g. 'clearkey'
  //   inputstream.adaptive.license_key    -> for clearkey, 'KID:KEY' hex pairs
  final String? manifestType;
  final String? licenseType;
  final String? licenseKey;

  // True when the playlist explicitly marks this entry as MPEG-DASH.
  bool get isDash => (manifestType ?? '').toLowerCase() == 'mpd';

  // ClearKey key pairs (kidHex -> keyHex) parsed from license_key, empty when
  // none/unusable.
  Map<String, String> get clearKeys =>
      licenseKey == null ? const {} : parseClearKeyLicense(licenseKey!);

  // True when this is a DASH stream we can decrypt via the local ClearKey proxy.
  bool get isEncryptedDash => isDash && clearKeys.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'group': group,
    'logo': logo,
    if (manifestType != null) 'manifestType': manifestType,
    if (licenseType != null) 'licenseType': licenseType,
    if (licenseKey != null) 'licenseKey': licenseKey,
  };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
    name: json['name'] as String? ?? 'Untitled Channel',
    url: json['url'] as String? ?? '',
    group: json['group'] as String? ?? ungroupedGroup,
    logo: json['logo'] as String?,
    manifestType: json['manifestType'] as String?,
    licenseType: json['licenseType'] as String?,
    licenseKey: json['licenseKey'] as String?,
  );
}

class PlaylistSource {
  const PlaylistSource({
    required this.id,
    required this.name,
    required this.kind,
    required this.source,
    required this.channels,
    required this.cached,
  });

  final String id;
  final String name;
  final SourceKind kind;
  final String source;
  final List<Channel> channels;
  final bool cached;

  PlaylistSource copyWith({
    String? name,
    String? source,
    List<Channel>? channels,
    bool? cached,
  }) => PlaylistSource(
    id: id,
    name: name ?? this.name,
    kind: kind,
    source: source ?? this.source,
    channels: channels ?? this.channels,
    cached: cached ?? this.cached,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'source': source,
    'cached': cached,
    'channels': channels.map((channel) => channel.toJson()).toList(),
  };

  factory PlaylistSource.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String? ?? SourceKind.online.name;
    return PlaylistSource(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? 'Playlist',
      kind: SourceKind.values.firstWhere(
        (kind) => kind.name == kindName,
        orElse: () => SourceKind.online,
      ),
      source: json['source'] as String? ?? '',
      cached: json['cached'] as bool? ?? false,
      channels: (json['channels'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Channel.fromJson)
          .where((channel) => channel.url.isNotEmpty)
          .toList(),
    );
  }
}

extension PlaylistSourceGroups on PlaylistSource {
  Map<String, int> get groups {
    final map = <String, int>{allChannels: channels.length};
    for (final channel in channels) {
      map[channel.group] = (map[channel.group] ?? 0) + 1;
    }
    return map;
  }
}
