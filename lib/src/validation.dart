// SPDX-License-Identifier: BSD-3-Clause
import 'models.dart';

/// Outcome of activity validation.
class ValidationResult {
  ValidationResult({Iterable<String>? errors, Iterable<String>? warnings})
    : errors = List.unmodifiable(errors ?? const <String>[]),
      warnings = List.unmodifiable(warnings ?? const <String>[]);

  /// Fatal validation failures.
  final List<String> errors;

  /// Non-fatal issues that may need attention.
  final List<String> warnings;

  /// Whether no errors were recorded.
  bool get isValid => errors.isEmpty;
}

/// Runs a set of structural checks over [activity].
ValidationResult validateRawActivity(
  RawActivity activity, {
  Duration gapWarningThreshold = const Duration(minutes: 5),
}) {
  final errors = <String>[];
  final warnings = <String>[];
  void checkSeriesOrder<T>(
    Iterable<T> series,
    DateTime Function(T) timeOf,
    String label,
  ) {
    DateTime? previous;
    for (final element in series) {
      final current = timeOf(element).toUtc();
      final prev = previous;
      if (prev != null) {
        if (current.isBefore(prev)) {
          errors.add(
            '$label timestamps out of order at ${current.toIso8601String()}',
          );
        } else if (current.isAtSameMomentAs(prev)) {
          errors.add(
            '$label contains duplicate timestamp ${current.toIso8601String()}',
          );
        } else {
          final gap = current.difference(prev);
          if (gapWarningThreshold > Duration.zero &&
              gap > gapWarningThreshold) {
            warnings.add(
              '$label has gap of ${gap.inSeconds}s ending at ${current.toIso8601String()}',
            );
          }
        }
      }
      previous = current;
    }
  }

  void checkCoordinates() {
    for (final point in activity.points) {
      final lat = point.latitude;
      final lon = point.longitude;
      if (!lat.isFinite || lat < -90 || lat > 90) {
        errors.add(
          'Invalid latitude ${point.latitude} at ${point.time.toIso8601String()}',
        );
      }
      if (!lon.isFinite || lon < -180 || lon > 180) {
        errors.add(
          'Invalid longitude ${point.longitude} at ${point.time.toIso8601String()}',
        );
      }
      final ele = point.elevation;
      if (ele != null && !ele.isFinite) {
        errors.add('Invalid elevation $ele at ${point.time.toIso8601String()}');
      }
    }
  }

  checkSeriesOrder<GeoPoint>(activity.points, (p) => p.time, 'Points');
  for (final entry in activity.channels.entries) {
    checkSeriesOrder<Sample>(
      entry.value,
      (sample) => sample.time,
      'Channel ${entry.key.id}',
    );
  }
  checkCoordinates();
  return ValidationResult(errors: errors, warnings: warnings);
}
