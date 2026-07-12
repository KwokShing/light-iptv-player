// Defines a range of data located at a reference URI.
//
// Direct Dart port of ExoPlayer's `RangedUri`
// (androidx.media3.exoplayer.dash.manifest.RangedUri). The relative-URL
// resolution that Java delegates to `UriUtil.resolveToUri` is reimplemented in
// [UriUtil.resolve] below using Dart's `Uri`, matching RFC 3986 behaviour.

import 'dash_c.dart';

class RangedUri {
  /// The (zero based) index of the first byte of the range.
  final int start;

  /// The length of the range, or [C.lengthUnset] if unbounded.
  final int length;

  final String _referenceUri;

  int _hashCode = 0;

  RangedUri(String? referenceUri, this.start, this.length)
      : _referenceUri = referenceUri ?? '';

  /// The resolved URI string represented by this instance, relative to
  /// [baseUri].
  String resolveUriString(String baseUri) =>
      UriUtil.resolve(baseUri, _referenceUri);

  /// Attempts to merge this [RangedUri] with [other] against a common
  /// [baseUri]. Succeeds only if both resolve to the same URI and form a
  /// contiguous byte region. Returns null otherwise.
  RangedUri? attemptMerge(RangedUri? other, String baseUri) {
    final resolvedUri = resolveUriString(baseUri);
    if (other == null || resolvedUri != other.resolveUriString(baseUri)) {
      return null;
    } else if (length != C.lengthUnset && start + length == other.start) {
      return RangedUri(
        resolvedUri,
        start,
        other.length == C.lengthUnset ? C.lengthUnset : length + other.length,
      );
    } else if (other.length != C.lengthUnset && other.start + other.length == start) {
      return RangedUri(
        resolvedUri,
        other.start,
        length == C.lengthUnset ? C.lengthUnset : other.length + length,
      );
    } else {
      return null;
    }
  }

  @override
  int get hashCode {
    if (_hashCode == 0) {
      var result = 17;
      result = 31 * result + start;
      result = 31 * result + length;
      result = 31 * result + _referenceUri.hashCode;
      _hashCode = result;
    }
    return _hashCode;
  }

  @override
  bool operator ==(Object other) =>
      other is RangedUri &&
      start == other.start &&
      length == other.length &&
      _referenceUri == other._referenceUri;

  @override
  String toString() =>
      'RangedUri(referenceUri=$_referenceUri, start=$start, length=$length)';
}

/// Minimal reimplementation of the pieces of ExoPlayer's `UriUtil` the DASH
/// layer uses: resolving a (possibly relative) reference against a base URI.
class UriUtil {
  UriUtil._();

  /// Resolves [referenceUri] against [baseUri] per RFC 3986. An absolute
  /// reference is returned as-is; an empty reference yields the base.
  static String resolve(String baseUri, String referenceUri) {
    if (referenceUri.isEmpty) return baseUri;
    final ref = Uri.tryParse(referenceUri);
    if (ref != null && ref.hasScheme) {
      // Already absolute.
      return referenceUri;
    }
    final base = Uri.tryParse(baseUri);
    if (base == null) return referenceUri;
    return base.resolve(referenceUri).toString();
  }
}
