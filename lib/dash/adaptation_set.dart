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

  /// `Role` descriptors (`urn:mpeg:dash:role:2011`). Used to tell apart several
  /// text tracks that share a language, e.g. `subtitle` versus `forced-subtitle`.
  final List<Descriptor> roleDescriptors;

  /// Human-readable `Label` element, when the packager supplies one.
  final String? label;

  AdaptationSet(
    this.id,
    this.type,
    this.representations,
    this.accessibilityDescriptors,
    this.essentialProperties,
    this.supplementalProperties, {
    this.roleDescriptors = const [],
    this.label,
  });
}
