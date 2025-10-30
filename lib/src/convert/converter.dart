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
  static String convert(
    String input, {
    required ActivityFileFormat from,
    required ActivityFileFormat to,
    bool normalize = true,
    EncoderOptions encoderOptions = const EncoderOptions(),
    List<String>? warnings,
  }) {
    final parseResult = ActivityParser.parse(input, from);
    warnings?.addAll(parseResult.warnings);
    var activity = parseResult.activity;
    if (normalize) {
      activity = RawEditor(activity).sortAndDedup().trimInvalid().activity;
    }
    return ActivityEncoder.encode(activity, to, options: encoderOptions);
  }
}
