// SPDX-License-Identifier: BSD-3-Clause
import '../encode/activity_encoder.dart';
import '../encode/encoder_options.dart';
import '../models.dart';
import '../parse/activity_parser.dart';
import '../transforms.dart';

/// High-level facade for converting between activity file formats.
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
    List<String>? warnings,
  }) {
    final parseResult = switch (input) {
      String text => ActivityParser.parse(text, from),
      List<int> bytes => ActivityParser.parseBytes(bytes, from),
      _ => throw ArgumentError(
        'Unsupported input type ${input.runtimeType}; expected String or List<int>.',
      ),
    };
    warnings?.addAll(parseResult.warnings);
    var activity = parseResult.activity;
    if (normalize) {
      activity = RawEditor(activity).sortAndDedup().trimInvalid().activity;
    }
    return ActivityEncoder.encode(activity, to, options: encoderOptions);
  }
}
