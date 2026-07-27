// SPDX-License-Identifier: BSD-3-Clause
/// Custom test matchers for activity files.
///
/// Provides specialized matchers for comparing activities, samples, and channels.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// Returns a [Matcher] that checks whether a [DateTime] is at the same moment
/// as [expected], using [DateTime.isAtSameMomentAs] for comparison. This is
/// equivalent to comparing UTC microseconds but works correctly across timezone
/// representations.
Matcher isAtSameMomentAs(DateTime expected) => predicate<DateTime>(
  (actual) => actual.isAtSameMomentAs(expected),
  'is at the same moment as $expected',
);

/// Checks if a sample list contains a matching sample within tolerance.
///
/// A sample matches if:
/// - Timestamp is within [tolerance] of [target].time
/// - Value is within 0.5 of [target].value
bool hasMatchingSample(
  List<Sample> samples,
  Sample target,
  Duration tolerance,
) {
  final targetMicros = target.time.microsecondsSinceEpoch;
  final limit = tolerance.inMicroseconds;
  for (final sample in samples) {
    final delta = (sample.time.microsecondsSinceEpoch - targetMicros).abs();
    if (delta <= limit && (sample.value - target.value).abs() < 0.5) {
      return true;
    }
  }
  return false;
}
