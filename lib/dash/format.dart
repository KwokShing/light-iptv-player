// A minimal media format description, a trimmed-down Dart port of ExoPlayer's
// `androidx.media3.common.Format` carrying just the fields the DASH manifest
// layer reads (id, bitrate, codecs, mime type, dimensions, sample rate/channels
// and language). ExoPlayer's Format is huge; only these are needed to drive
// segment-URL templates and track selection.

import 'dash_c.dart';

class Format {
  const Format({
    this.id,
    this.containerMimeType,
    this.sampleMimeType,
    this.codecs,
    this.bitrate = C.rateUnset,
    this.width = C.lengthUnset,
    this.height = C.lengthUnset,
    this.frameRate = -1,
    this.sampleRate = C.rateUnset,
    this.channelCount = C.rateUnset,
    this.language,
  });

  final String? id;
  final String? containerMimeType;
  final String? sampleMimeType;
  final String? codecs;
  final int bitrate;
  final int width;
  final int height;
  final double frameRate;
  final int sampleRate;
  final int channelCount;
  final String? language;

  Format copyWith({
    String? id,
    String? containerMimeType,
    String? sampleMimeType,
    String? codecs,
    int? bitrate,
    int? width,
    int? height,
    double? frameRate,
    int? sampleRate,
    int? channelCount,
    String? language,
  }) =>
      Format(
        id: id ?? this.id,
        containerMimeType: containerMimeType ?? this.containerMimeType,
        sampleMimeType: sampleMimeType ?? this.sampleMimeType,
        codecs: codecs ?? this.codecs,
        bitrate: bitrate ?? this.bitrate,
        width: width ?? this.width,
        height: height ?? this.height,
        frameRate: frameRate ?? this.frameRate,
        sampleRate: sampleRate ?? this.sampleRate,
        channelCount: channelCount ?? this.channelCount,
        language: language ?? this.language,
      );

  @override
  String toString() =>
      'Format(id=$id, mime=$sampleMimeType, codecs=$codecs, '
      'bitrate=$bitrate, ${width}x$height)';
}

/// Small MIME-type helpers mirroring the handful of checks ExoPlayer's
/// `MimeTypes` provides that the DASH track-type inference needs.
class MimeTypes {
  MimeTypes._();

  static bool isVideo(String? mimeType) =>
      mimeType != null && mimeType.toLowerCase().startsWith('video/');

  static bool isAudio(String? mimeType) =>
      mimeType != null && mimeType.toLowerCase().startsWith('audio/');

  static bool isText(String? mimeType) {
    if (mimeType == null) return false;
    final m = mimeType.toLowerCase();
    return m.startsWith('text/') ||
        m.startsWith('application/') ||
        m == 'text';
  }

  /// Track type ([C.trackTypeVideo] / audio / text / unknown) for a mime type.
  static int trackType(String? mimeType) {
    if (isVideo(mimeType)) return C.trackTypeVideo;
    if (isAudio(mimeType)) return C.trackTypeAudio;
    if (isText(mimeType)) return C.trackTypeText;
    return C.trackTypeUnknown;
  }
}
