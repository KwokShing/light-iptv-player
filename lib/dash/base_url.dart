// A BaseURL element, as defined by ISO 23009-1.
//
// Dart port of ExoPlayer's `BaseUrl`
// (androidx.media3.exoplayer.dash.manifest.BaseUrl), keeping the DVB priority /
// weight / serviceLocation fields even though the simplified single-BaseURL
// scheduling here does not yet use failover.

class BaseUrl {
  static const int defaultDvbPriority = 1;
  static const int defaultWeight = 1;
  static const String defaultServiceLocation = '';

  final String url;
  final String serviceLocation;
  final int priority;
  final int weight;

  const BaseUrl(
    this.url, [
    this.serviceLocation = defaultServiceLocation,
    this.priority = defaultDvbPriority,
    this.weight = defaultWeight,
  ]);

  @override
  bool operator ==(Object other) =>
      other is BaseUrl &&
      url == other.url &&
      serviceLocation == other.serviceLocation &&
      priority == other.priority &&
      weight == other.weight;

  @override
  int get hashCode => Object.hash(url, serviceLocation, priority, weight);
}
