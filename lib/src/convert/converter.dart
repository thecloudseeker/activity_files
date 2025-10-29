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
