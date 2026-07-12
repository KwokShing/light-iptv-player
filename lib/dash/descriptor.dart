// A descriptor, as defined by ISO 23009-1, 2nd edition, 5.8.2.
//
// Dart port of ExoPlayer's `Descriptor`
// (androidx.media3.exoplayer.dash.manifest.Descriptor).

class Descriptor {
  final String schemeIdUri;
  final String? value;
  final String? id;

  const Descriptor(this.schemeIdUri, this.value, this.id);

  @override
  bool operator ==(Object other) =>
      other is Descriptor &&
      schemeIdUri == other.schemeIdUri &&
      value == other.value &&
      id == other.id;

  @override
  int get hashCode => Object.hash(schemeIdUri, value, id);
}
