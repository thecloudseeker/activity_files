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
  DateTime? pointsStart;
  DateTime? pointsEnd;
  for (final point in activity.points) {
    final timestamp = point.time.toUtc();
    if (pointsStart == null || timestamp.isBefore(pointsStart)) {
      pointsStart = timestamp;
    }
    if (pointsEnd == null || timestamp.isAfter(pointsEnd)) {
      pointsEnd = timestamp;
    }
  }
  void recordValueIssue({
    required Channel channel,
    required Sample sample,
    required String message,
    bool asError = true,
  }) {
    final label = 'Channel ${channel.id}';
    final entry = '$label $message at ${sample.time.toIso8601String()}';
    if (asError) {
      errors.add(entry);
    } else {
      warnings.add(entry);
    }
  }

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

  void checkLaps() {
    Lap? previous;
    for (var i = 0; i < activity.laps.length; i++) {
      final lap = activity.laps[i];
      final label = 'Lap ${i + 1}';
      final start = lap.startTime.toUtc();
      final end = lap.endTime.toUtc();
      if (!end.isAfter(start)) {
        errors.add(
          '$label ends at ${end.toIso8601String()} which is not after its start ${start.toIso8601String()}',
        );
      }
      final prev = previous;
      if (prev != null) {
        final prevStart = prev.startTime.toUtc();
        final prevEnd = prev.endTime.toUtc();
        if (start.isBefore(prevStart)) {
          errors.add(
            '$label starts before the previous lap (${prevStart.toIso8601String()}); ensure laps are ordered chronologically.',
          );
        } else if (start.isBefore(prevEnd)) {
          errors.add(
            '$label starts before the previous lap ended at ${prevEnd.toIso8601String()}',
          );
        }
      }
      if (pointsStart != null && start.isBefore(pointsStart)) {
        warnings.add(
          '$label starts before the first point (${pointsStart.toIso8601String()}); lap timings may not align with the trajectory.',
        );
      }
      if (pointsEnd != null && end.isAfter(pointsEnd)) {
        warnings.add(
          '$label ends after the last point (${pointsEnd.toIso8601String()}); lap timings may not align with the trajectory.',
        );
      }
      previous = lap;
    }
  }

  void checkChannelCoverage() {
    if (pointsStart == null || pointsEnd == null) {
      return;
    }
    for (final entry in activity.channels.entries) {
      DateTime? earliestBefore;
      DateTime? latestAfter;
      for (final sample in entry.value) {
        final timestamp = sample.time.toUtc();
        if (timestamp.isBefore(pointsStart)) {
          earliestBefore ??= timestamp;
        } else if (timestamp.isAfter(pointsEnd)) {
          latestAfter ??= timestamp;
        }
        if (earliestBefore != null && latestAfter != null) {
          break;
        }
      }
      if (earliestBefore != null) {
        warnings.add(
          'Channel ${entry.key.id} has samples before the first point (${earliestBefore.toIso8601String()}); normalize timestamps to align sensor data with GPS fixes.',
        );
      }
      if (latestAfter != null) {
        warnings.add(
          'Channel ${entry.key.id} has samples after the last point (${latestAfter.toIso8601String()}); normalize timestamps to align sensor data with GPS fixes.',
        );
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
    double? previousValue;
    for (final sample in entry.value) {
      final value = sample.value;
      if (value.isNaN || value.isInfinite) {
        recordValueIssue(
          channel: entry.key,
          sample: sample,
          message: 'contains non-finite value $value',
        );
        continue;
      }
      if (entry.key == Channel.distance && value < 0) {
        recordValueIssue(
          channel: entry.key,
          sample: sample,
          message: 'has negative distance $value',
        );
      }
      if (entry.key == Channel.distance &&
          previousValue != null &&
          value + 1e-9 < previousValue) {
        recordValueIssue(
          channel: entry.key,
          sample: sample,
          message: 'distance decreases from $previousValue to $value',
          asError: false,
        );
      }
      if (entry.key == Channel.heartRate && (value < 20 || value > 260)) {
        recordValueIssue(
          channel: entry.key,
          sample: sample,
          message: 'heart rate $value bpm outside plausible range',
          asError: false,
        );
      }
      if (entry.key == Channel.power && value < 0) {
        recordValueIssue(
          channel: entry.key,
          sample: sample,
          message: 'power cannot be negative ($value)',
        );
      }
      previousValue = value;
    }
  }
  checkCoordinates();
  checkLaps();
  checkChannelCoverage();
  return ValidationResult(errors: errors, warnings: warnings);
}
