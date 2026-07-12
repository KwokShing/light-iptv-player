// Encapsulates media content components over a contiguous period of time.
//
// Dart port of ExoPlayer's `Period`
// (androidx.media3.exoplayer.dash.manifest.Period). EventStreams are omitted
// (not needed for the mpv-fed clear-fMP4 pipeline), so the eventStreams field
// is dropped compared to the original.

import 'adaptation_set.dart';
import 'dash_c.dart';
import 'descriptor.dart';

class Period {
  final String? id;

  /// Start time in milliseconds, relative to the start of the manifest.
  final int startMs;
  final List<AdaptationSet> adaptationSets;
  final Descriptor? assetIdentifier;

  Period(
    this.id,
    this.startMs,
    this.adaptationSets, [
    this.assetIdentifier,
  ]);

  /// Index of the first adaptation set of [type], or [C.indexUnset].
  int getAdaptationSetIndex(int type) {
    for (var i = 0; i < adaptationSets.length; i++) {
      if (adaptationSets[i].type == type) return i;
    }
    return C.indexUnset;
  }
}
