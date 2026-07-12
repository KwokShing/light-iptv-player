// A template from which segment URLs can be built.
//
// Direct Dart port of ExoPlayer's `UrlTemplate`
// (androidx.media3.exoplayer.dash.manifest.UrlTemplate). URLs are built
// according to the substitution rules in ISO/IEC 23009-1:2014 5.3.9.4.4:
// $RepresentationID$, $Number$, $Bandwidth$ and $Time$, with optional
// `%0Nd`-style formatting (decimal or hex).

class UrlTemplate {
  UrlTemplate._(this._urlPieces, this._identifiers, this._identifierFormatTags);

  static const String _representation = 'RepresentationID';
  static const String _number = 'Number';
  static const String _bandwidth = 'Bandwidth';
  static const String _time = 'Time';
  static const String _escapedDollar = r'$$';
  static const String _defaultFormatTag = '%01d';

  static const int _representationId = 1;
  static const int _numberId = 2;
  static const int _bandwidthId = 3;
  static const int _timeId = 4;

  final List<String> _urlPieces;
  final List<int> _identifiers;
  final List<String> _identifierFormatTags;

  /// Compiles an instance from the provided template string. Throws
  /// [FormatException] if the template is malformed.
  static UrlTemplate compile(String template) {
    final urlPieces = <String>[];
    final identifiers = <int>[];
    final identifierFormatTags = <String>[];
    _parseTemplate(template, urlPieces, identifiers, identifierFormatTags);
    return UrlTemplate._(urlPieces, identifiers, identifierFormatTags);
  }

  /// Builds a URI from the template, substituting in the provided arguments.
  /// Identifiers not present in the template are ignored.
  String buildUri(String representationId, int segmentNumber, int bandwidth,
      int time) {
    final builder = StringBuffer();
    for (var i = 0; i < _identifiers.length; i++) {
      builder.write(_urlPieces[i]);
      switch (_identifiers[i]) {
        case _representationId:
          builder.write(representationId);
          break;
        case _numberId:
          builder.write(_format(_identifierFormatTags[i], segmentNumber));
          break;
        case _bandwidthId:
          builder.write(_format(_identifierFormatTags[i], bandwidth));
          break;
        case _timeId:
          builder.write(_format(_identifierFormatTags[i], time));
          break;
      }
    }
    builder.write(_urlPieces[_identifiers.length]);
    return builder.toString();
  }

  // Applies a printf-style `%0Nd` / `%0Nx` / `%0NX` tag to [value]. Dart has no
  // printf, so interpret the (narrow) set of tags DASH allows.
  static String _format(String formatTag, int value) {
    // formatTag looks like `%01d`, `%05d`, `%d`, `%x`, `%08X`, ...
    final conversion = formatTag.substring(formatTag.length - 1);
    var radix = 10;
    var upper = false;
    if (conversion == 'x') {
      radix = 16;
    } else if (conversion == 'X') {
      radix = 16;
      upper = true;
    }
    // Extract minimum width between the leading `%0`/`%` and the conversion.
    var width = 0;
    final inner = formatTag.substring(1, formatTag.length - 1); // e.g. '05','0','',...
    final digits = inner.replaceFirst(RegExp(r'^0'), '');
    if (digits.isNotEmpty) {
      width = int.tryParse(digits) ?? 0;
    }
    var text = value.toRadixString(radix);
    if (upper) text = text.toUpperCase();
    if (text.length < width) {
      text = text.padLeft(width, '0');
    }
    return text;
  }

  static void _parseTemplate(
    String template,
    List<String> urlPieces,
    List<int> identifiers,
    List<String> identifierFormatTags,
  ) {
    urlPieces.add('');
    var templateIndex = 0;
    while (templateIndex < template.length) {
      final dollarIndex = template.indexOf(r'$', templateIndex);
      if (dollarIndex == -1) {
        urlPieces[identifiers.length] =
            urlPieces[identifiers.length] + template.substring(templateIndex);
        templateIndex = template.length;
      } else if (dollarIndex != templateIndex) {
        urlPieces[identifiers.length] = urlPieces[identifiers.length] +
            template.substring(templateIndex, dollarIndex);
        templateIndex = dollarIndex;
      } else if (template.startsWith(_escapedDollar, templateIndex)) {
        urlPieces[identifiers.length] = '${urlPieces[identifiers.length]}\$';
        templateIndex += 2;
      } else {
        identifierFormatTags.add('');
        final secondIndex = template.indexOf(r'$', templateIndex + 1);
        if (secondIndex == -1) {
          throw FormatException('Invalid template: $template');
        }
        var identifier = template.substring(templateIndex + 1, secondIndex);
        if (identifier == _representation) {
          identifiers.add(_representationId);
        } else {
          final formatTagIndex = identifier.indexOf('%0');
          var formatTag = _defaultFormatTag;
          if (formatTagIndex != -1) {
            formatTag = identifier.substring(formatTagIndex);
            // Allowed conversions: decimal (DASH spec) and hex (existing
            // content). Otherwise assume a missing decimal conversion.
            if (!formatTag.endsWith('d') &&
                !formatTag.endsWith('x') &&
                !formatTag.endsWith('X')) {
              formatTag += 'd';
            }
            identifier = identifier.substring(0, formatTagIndex);
          }
          switch (identifier) {
            case _number:
              identifiers.add(_numberId);
              break;
            case _bandwidth:
              identifiers.add(_bandwidthId);
              break;
            case _time:
              identifiers.add(_timeId);
              break;
            default:
              throw FormatException('Invalid template: $template');
          }
          identifierFormatTags[identifiers.length - 1] = formatTag;
        }
        urlPieces.add('');
        templateIndex = secondIndex + 1;
      }
    }
  }
}
