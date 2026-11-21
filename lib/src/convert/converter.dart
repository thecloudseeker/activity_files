// SPDX-License-Identifier: BSD-3-Clause
import '../encode/activity_encoder.dart';
import '../encode/encoder_options.dart';
import '../models.dart';
import '../parse/activity_parser.dart';
import '../parse/parse_result.dart';
import '../transforms.dart';

/// High-level facade for converting between activity file formats.
///
/// This is sugar over parsing followed by [ActivityEncoder.encode], with no
/// capability of its own: it cannot auto-detect the source format, and it
/// returns a bare `String` rather than a result carrying diagnostics. Use
/// [ActivityFiles.convert].
@Deprecated('Use ActivityFiles.convert. Will be removed in 0.10.0.')
class ActivityConverter {
  const ActivityConverter._();

  /// Converts [input] from [from] to [to], applying sane defaults.
  ///
  /// Text formats (GPX/TCX) expect [input] as a UTF-8 string. For FIT payloads
  /// you may pass either a base64-encoded [String] or a raw [List<int>]
  /// containing the binary bytes.
  static String convert(
    Object input, {
    required ActivityFileFormat from,
    required ActivityFileFormat to,
    bool normalize = true,
    EncoderOptions encoderOptions = const EncoderOptions(),
    List<ParseDiagnostic>? diagnostics,
    @Deprecated('Use diagnostics instead.') List<String>? warnings,
  }) {
    final parseResult = switch (input) {
      String text => ParserRouter.parse(text, from),
      List<int> bytes => ParserRouter.parseBytes(bytes, from),
      _ => ActivityParseResult(
        activity: RawActivity(),
        diagnostics: [
          ParseDiagnostic(
            severity: ParseSeverity.error,
            code: 'import.source.unsupported',
            message:
                'Unsupported input type ${input.runtimeType}; expected '
                'String or List<int>.',
          ),
        ],
      ),
    };
    diagnostics?.addAll(parseResult.diagnostics);
    if (warnings != null) {
      warnings.addAll(
        parseResult.warningDiagnostics.map((diagnostic) => diagnostic.message),
      );
    }
    var activity = parseResult.activity;
    if (normalize) {
      final editor = RawEditor(activity).sortAndDedup().trimInvalid();
      activity = editor.activity;
      diagnostics?.addAll(
        editor.repairDiagnostics.map((d) => d.toParseDiagnostic()),
      );
    }
    return ActivityEncoder.encode(activity, to, options: encoderOptions);
  }
}
