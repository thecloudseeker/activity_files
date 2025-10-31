// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';

/// Result of parsing an activity file, including non-fatal warnings.
class ActivityParseResult {
  ActivityParseResult({required this.activity, Iterable<String>? warnings})
    : warnings = List.unmodifiable(warnings ?? const <String>[]);

  /// The reconstructed activity.
  final RawActivity activity;

  /// Non-fatal issues encountered during parsing.
  final List<String> warnings;
}
