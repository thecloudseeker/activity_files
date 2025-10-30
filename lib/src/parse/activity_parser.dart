// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';
import 'fit_parser.dart';
import 'gpx_parser.dart';
import 'parse_result.dart';
import 'tcx_parser.dart';
/// Common interface for format-specific parsers.
abstract class ActivityFormatParser {
  ActivityParseResult parse(String input);
}
/// Dynamically selects the parser for the requested format.
class ActivityParser {
  const ActivityParser._();
  /// Parses [input] according to [format].
  ///
  /// For FIT content the [input] should be a base64-encoded payload representing
  /// the binary FIT stream.
  static ActivityParseResult parse(String input, ActivityFileFormat format) {
    final parser = switch (format) {
      ActivityFileFormat.gpx => const GpxParser(),
      ActivityFileFormat.tcx => const TcxParser(),
      ActivityFileFormat.fit => const FitParser(),
    };
    return parser.parse(input);
  }
  /// Convenience helper returning only the parsed activity.
  static RawActivity parseActivity(String input, ActivityFileFormat format) =>
      parse(input, format).activity;
}
