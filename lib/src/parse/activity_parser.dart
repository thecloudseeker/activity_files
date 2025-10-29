// MIT License
//
// Copyright (c) 2024 activity_files
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

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
