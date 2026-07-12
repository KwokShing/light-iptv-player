// A set of interchangeable encoded versions of a media content component.
//
// Dart port of ExoPlayer's `AdaptationSet`
// (androidx.media3.exoplayer.dash.manifest.AdaptationSet).

import 'descriptor.dart';
import 'representation.dart';

class AdaptationSet {
  static const int idUnset = -1;

  final int id;

  /// [C.trackType...] of the adaptation set.
  final int type;
  final List<Representation> representations;
  final List<Descriptor> accessibilityDescriptors;
  final List<Descriptor> essentialProperties;
  final List<Descriptor> supplementalProperties;

  AdaptationSet(
    this.id,
    this.type,
    this.representations,
    this.accessibilityDescriptors,
    this.essentialProperties,
    this.supplementalProperties,
  );
}
