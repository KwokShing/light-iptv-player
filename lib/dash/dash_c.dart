// Shared constants and small numeric helpers, ported from the pieces of
// ExoPlayer's `androidx.media3.common.C` / `Util` that the DASH manifest layer
// depends on. Kept in one place so the ported model/parser code reads close to
// the Java original (`C.TIME_UNSET`, `Util.scaleLargeTimestamp`, ...).

/// Mirrors ExoPlayer's C constants used by the DASH manifest classes.
class C {
  C._();

  static const int timeUnset = -9223372036854775807; // Long.MIN_VALUE + 1
  static const int indexUnset = -1;
  static const int lengthUnset = -1;
  static const int rateUnset = -1;

  static const int microsPerSecond = 1000000;
  static const int millisPerSecond = 1000;

  // Track types (subset of ExoPlayer's C.TrackType we care about).
  static const int trackTypeUnknown = -1;
  static const int trackTypeAudio = 1;
  static const int trackTypeVideo = 2;
  static const int trackTypeText = 3;
}

/// Ported helpers from ExoPlayer's `Util`.
class Util {
  Util._();

  /// Scales a large timestamp: `value * multiplier / divisor`, done with
  /// enough care to avoid overflow the way ExoPlayer's Util does. For the
  /// magnitudes DASH manifests produce, Dart's arbitrary-precision `int` on
  /// native (64-bit) is sufficient; we still special-case the unset value.
  static int scaleLargeTimestamp(int timestamp, int multiplier, int divisor) {
    if (timestamp == C.timeUnset) return C.timeUnset;
    if (divisor >= multiplier && (divisor % multiplier) == 0) {
      final divisionFactor = divisor ~/ multiplier;
      return timestamp ~/ divisionFactor;
    } else if (divisor < multiplier && (multiplier % divisor) == 0) {
      final multiplicationFactor = multiplier ~/ divisor;
      return timestamp * multiplicationFactor;
    } else {
      final multiplicationFactor = multiplier / divisor;
      return (timestamp * multiplicationFactor).round();
    }
  }

  static int msToUs(int timeMs) =>
      timeMs == C.timeUnset ? C.timeUnset : timeMs * 1000;

  static int usToMs(int timeUs) =>
      timeUs == C.timeUnset ? C.timeUnset : timeUs ~/ 1000;

  /// Ceiling integer division, matching `Util.ceilDivide`.
  static int ceilDivide(int numerator, int denominator) =>
      (numerator + denominator - 1) ~/ denominator;
}
