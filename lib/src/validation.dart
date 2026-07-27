// SPDX-License-Identifier: BSD-3-Clause
import 'models.dart';
import 'parse/parse_result.dart';

/// Severity of a validation diagnostic.
enum ValidationSeverity { warning, error }

/// A structured diagnostic produced by activity validation.
///
/// Each diagnostic includes a stable [code] for programmatic routing,
/// a human-readable [message], and an optional [suggestedFix] that UIs can
/// present as a next-step action.  The [priority] field (lower = more
/// important) lets callers order diagnostics when multiple issues exist.
class ValidationDiagnostic {
  const ValidationDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.suggestedFix,
    this.priority,
  });

  /// Severity of this diagnostic.
  final ValidationSeverity severity;

  /// Stable dot-separated code (e.g. `validation.coordinate.invalid_latitude`).
  final String code;

  /// Human-readable description of the issue.
  final String message;

  /// Actionable suggestion for resolving the issue, suitable for display in a
  /// UI as a one-click fix label or guided next step.  Null when no fix is
  /// known.
  final String? suggestedFix;

  /// Relative priority among diagnostics of the same severity (lower = more
  /// important).  Null when ordering is not meaningful.
  final int? priority;

  /// Whether this diagnostic represents a fatal error.
  bool get isError => severity == ValidationSeverity.error;

  /// Converts to a [ParseDiagnostic] so validation results can be mixed with
  /// parser diagnostics when needed.
  ParseDiagnostic toParseDiagnostic() => ParseDiagnostic(
    severity: isError ? ParseSeverity.error : ParseSeverity.warning,
    code: code,
    message: message,
    suggestedFix: suggestedFix,
    priority: priority,
  );
}

/// Outcome of activity validation.
class ValidationResult {
  ValidationResult({
    Iterable<String>? errors,
    Iterable<String>? warnings,
    Iterable<ValidationDiagnostic>? diagnostics,
  }) : diagnostics = List.unmodifiable(
         diagnostics ?? _inferDiagnostics(errors, warnings),
       ),
       errors = List.unmodifiable(errors ?? const <String>[]),
       warnings = List.unmodifiable(warnings ?? const <String>[]);

  /// Builds a result from [diagnostics], deriving the legacy string lists.
  factory ValidationResult.fromDiagnostics(
    Iterable<ValidationDiagnostic> diagnostics,
  ) {
    final (:errors, :warnings) = _splitMessages(diagnostics);
    return ValidationResult(
      diagnostics: diagnostics,
      errors: errors,
      warnings: warnings,
    );
  }

  /// Structured diagnostics.  Prefer this over [errors]/[warnings] for any
  /// new code — the string lists are kept for backwards compatibility.
  final List<ValidationDiagnostic> diagnostics;

  /// Fatal validation failures.
  final List<String> errors;

  /// Non-fatal issues that may need attention.
  final List<String> warnings;

  /// Whether no errors were recorded.
  ///
  /// Checks both [diagnostics] and the legacy [errors] list so that a result
  /// constructed with an explicit but inconsistent combination (e.g. non-empty
  /// [errors] alongside empty [diagnostics]) is never reported as valid.
  bool get isValid => errors.isEmpty && !diagnostics.any((d) => d.isError);

  /// Error-level diagnostics.
  Iterable<ValidationDiagnostic> get errorDiagnostics =>
      diagnostics.where((d) => d.isError);

  /// Warning-level diagnostics.
  Iterable<ValidationDiagnostic> get warningDiagnostics =>
      diagnostics.where((d) => !d.isError);
}

/// Splits diagnostic messages into legacy error/warning string lists.
({List<String> errors, List<String> warnings}) _splitMessages(
  Iterable<ValidationDiagnostic> diagnostics,
) => (
  errors: [
    for (final d in diagnostics)
      if (d.isError) d.message,
  ],
  warnings: [
    for (final d in diagnostics)
      if (!d.isError) d.message,
  ],
);

List<ValidationDiagnostic> _inferDiagnostics(
  Iterable<String>? errors,
  Iterable<String>? warnings,
) => [
  for (final msg in errors ?? const <String>[])
    ValidationDiagnostic(
      severity: ValidationSeverity.error,
      code: 'validation.legacy',
      message: msg,
    ),
  for (final msg in warnings ?? const <String>[])
    ValidationDiagnostic(
      severity: ValidationSeverity.warning,
      code: 'validation.legacy',
      message: msg,
    ),
];

/// Outcome of lap boundary validation.
///
/// Used to detect lap timing mismatches after compound edits like crop,
/// trim, or downsample operations.
class LapValidationResult {
  LapValidationResult({
    Iterable<String>? errors,
    Iterable<String>? warnings,
    Iterable<ValidationDiagnostic>? diagnostics,
  }) : diagnostics = List.unmodifiable(
         diagnostics ?? _inferDiagnostics(errors, warnings),
       ),
       errors = List.unmodifiable(errors ?? const <String>[]),
       warnings = List.unmodifiable(warnings ?? const <String>[]);

  /// Builds a result from [diagnostics], deriving the legacy string lists.
  factory LapValidationResult.fromDiagnostics(
    Iterable<ValidationDiagnostic> diagnostics,
  ) {
    final (:errors, :warnings) = _splitMessages(diagnostics);
    return LapValidationResult(
      diagnostics: diagnostics,
      errors: errors,
      warnings: warnings,
    );
  }

  /// Structured diagnostics.
  final List<ValidationDiagnostic> diagnostics;

  /// Fatal validation failures (e.g., overlapping laps, inverted times).
  final List<String> errors;

  /// Non-fatal issues (e.g., laps extending beyond point timeframe).
  final List<String> warnings;

  /// Whether no errors were recorded.
  ///
  /// Checks both [diagnostics] and the legacy [errors] list so that a result
  /// constructed with an explicit but inconsistent combination (e.g. non-empty
  /// [errors] alongside empty [diagnostics]) is never reported as valid.
  bool get isValid => errors.isEmpty && !diagnostics.any((d) => d.isError);

  /// Whether there are any issues (errors or warnings).
  bool get hasIssues =>
      diagnostics.isNotEmpty || errors.isNotEmpty || warnings.isNotEmpty;
}

LapValidationResult validateLapBoundariesList(
  List<Lap> laps, {
  DateTime? pointsStart,
  DateTime? pointsEnd,
  bool warnWhenNoPoints = false,
}) {
  final diags = <ValidationDiagnostic>[];

  if (warnWhenNoPoints &&
      pointsStart == null &&
      pointsEnd == null &&
      laps.isNotEmpty) {
    diags.add(
      ValidationDiagnostic(
        severity: ValidationSeverity.warning,
        code: 'validation.laps.no_points',
        message: 'Activity has ${laps.length} lap(s) but no GPS points',
        suggestedFix:
            'Add GPS track points or remove the lap boundaries from the activity.',
        priority: 2,
      ),
    );
    return LapValidationResult.fromDiagnostics(diags);
  }

  Lap? previous;
  for (var i = 0; i < laps.length; i++) {
    final lap = laps[i];
    final label = 'Lap ${i + 1}';
    final start = lap.startTime;
    final end = lap.endTime;
    if (!end.isAfter(start)) {
      diags.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.error,
          code: 'validation.laps.inverted_times',
          message:
              '$label ends at ${end.toIso8601String()} which is not after its start ${start.toIso8601String()}',
          suggestedFix:
              'Swap the start and end timestamps for $label, or remove the malformed lap.',
          priority: 0,
        ),
      );
    }
    final prev = previous;
    if (prev != null) {
      final prevStart = prev.startTime;
      final prevEnd = prev.endTime;
      if (start.isBefore(prevStart)) {
        diags.add(
          ValidationDiagnostic(
            severity: ValidationSeverity.error,
            code: 'validation.laps.out_of_order',
            message:
                '$label starts before the previous lap (${prevStart.toIso8601String()}); ensure laps are ordered chronologically.',
            suggestedFix: 'Sort laps by start time before saving.',
            priority: 1,
          ),
        );
      } else if (start.isBefore(prevEnd)) {
        diags.add(
          ValidationDiagnostic(
            severity: ValidationSeverity.error,
            code: 'validation.laps.overlap',
            message:
                '$label starts before the previous lap ended at ${prevEnd.toIso8601String()}',
            suggestedFix:
                'Adjust $label start time to ${prevEnd.toIso8601String()} or later.',
            priority: 1,
          ),
        );
      }
    }
    if (pointsStart != null && start.isBefore(pointsStart)) {
      diags.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: 'validation.laps.extends_before_points',
          message:
              '$label starts before the first point (${pointsStart.toIso8601String()}); lap timings may not align with the trajectory.',
          suggestedFix:
              'Trim $label start to ${pointsStart.toIso8601String()} to align with track points.',
          priority: 3,
        ),
      );
    }
    if (pointsEnd != null && end.isAfter(pointsEnd)) {
      diags.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: 'validation.laps.extends_after_points',
          message:
              '$label ends after the last point (${pointsEnd.toIso8601String()}); lap timings may not align with the trajectory.',
          suggestedFix:
              'Trim $label end to ${pointsEnd.toIso8601String()} to align with track points.',
          priority: 3,
        ),
      );
    }
    previous = lap;
  }

  return LapValidationResult.fromDiagnostics(diags);
}

/// Runs a set of structural checks over [activity].
///
/// Returns a [ValidationResult] whose [ValidationResult.diagnostics] include
/// [ValidationDiagnostic.suggestedFix] and [ValidationDiagnostic.priority]
/// fields so that UIs can present actionable guidance.
ValidationResult validateRawActivity(
  RawActivity activity, {
  Duration gapWarningThreshold = const Duration(minutes: 5),
}) {
  final diags = <ValidationDiagnostic>[];
  DateTime? pointsStart;
  DateTime? pointsEnd;
  for (final point in activity.points) {
    final timestamp = point.time;
    if (pointsStart == null || timestamp.isBefore(pointsStart)) {
      pointsStart = timestamp;
    }
    if (pointsEnd == null || timestamp.isAfter(pointsEnd)) {
      pointsEnd = timestamp;
    }
  }

  void addError(
    String code,
    String message, {
    String? suggestedFix,
    int priority = 1,
  }) {
    diags.add(
      ValidationDiagnostic(
        severity: ValidationSeverity.error,
        code: code,
        message: message,
        suggestedFix: suggestedFix,
        priority: priority,
      ),
    );
  }

  void addWarning(
    String code,
    String message, {
    String? suggestedFix,
    int priority = 2,
  }) {
    diags.add(
      ValidationDiagnostic(
        severity: ValidationSeverity.warning,
        code: code,
        message: message,
        suggestedFix: suggestedFix,
        priority: priority,
      ),
    );
  }

  void checkSeriesOrder<T>(
    Iterable<T> series,
    DateTime Function(T) timeOf,
    String label,
    String codePrefix,
  ) {
    DateTime? previous;
    for (final element in series) {
      final current = timeOf(element);
      final prev = previous;
      if (prev != null) {
        if (current.isBefore(prev)) {
          addError(
            '$codePrefix.out_of_order',
            '$label timestamps out of order at ${current.toIso8601String()}',
            suggestedFix: 'Sort $label by timestamp before exporting.',
            priority: 1,
          );
        } else if (current.isAtSameMomentAs(prev)) {
          addError(
            '$codePrefix.duplicate_timestamp',
            '$label contains duplicate timestamp ${current.toIso8601String()}',
            suggestedFix:
                'Remove duplicate entries or offset the second timestamp by 1 second.',
            priority: 1,
          );
        } else {
          final gap = current.difference(prev);
          if (gapWarningThreshold > Duration.zero &&
              gap > gapWarningThreshold) {
            addWarning(
              '$codePrefix.gap',
              '$label has gap of ${gap.inSeconds}s ending at ${current.toIso8601String()}',
              suggestedFix:
                  'Check for a paused recording or missing data segment near ${current.toIso8601String()}.',
              priority: 3,
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
        addError(
          'validation.coordinate.invalid_latitude',
          'Invalid latitude ${point.latitude} at ${point.time.toIso8601String()}',
          suggestedFix:
              'Remove or correct the track point with latitude $lat; valid range is −90 to 90.',
          priority: 0,
        );
      }
      if (!lon.isFinite || lon < -180 || lon > 180) {
        addError(
          'validation.coordinate.invalid_longitude',
          'Invalid longitude ${point.longitude} at ${point.time.toIso8601String()}',
          suggestedFix:
              'Remove or correct the track point with longitude ${point.longitude}; valid range is −180 to 180.',
          priority: 0,
        );
      }
      final ele = point.elevation;
      if (ele != null && !ele.isFinite) {
        addError(
          'validation.coordinate.invalid_elevation',
          'Invalid elevation $ele at ${point.time.toIso8601String()}',
          suggestedFix: 'Remove or replace the non-finite elevation value.',
          priority: 1,
        );
      }
    }
  }

  void checkLaps() {
    final lapValidation = validateLapBoundariesList(
      activity.laps,
      pointsStart: pointsStart,
      pointsEnd: pointsEnd,
    );
    diags.addAll(lapValidation.diagnostics);
  }

  void checkChannelCoverage() {
    if (pointsStart == null || pointsEnd == null) {
      return;
    }
    final trackStart = pointsStart;
    final trackEnd = pointsEnd;
    for (final entry in activity.channels.entries) {
      DateTime? earliestBefore;
      DateTime? latestAfter;
      for (final sample in entry.value) {
        final timestamp = sample.time;
        if (timestamp.isBefore(trackStart)) {
          earliestBefore ??= timestamp;
        } else if (timestamp.isAfter(trackEnd)) {
          latestAfter ??= timestamp;
        }
        if (earliestBefore != null && latestAfter != null) {
          break;
        }
      }
      if (earliestBefore != null) {
        addWarning(
          'validation.channel.samples_before_track',
          'Channel ${entry.key.id} has samples before the first point (${earliestBefore.toIso8601String()}); normalize timestamps to align sensor data with GPS fixes.',
          suggestedFix:
              'Call trimToPoints() on the channel, or discard samples outside the track time range.',
          priority: 3,
        );
      }
      if (latestAfter != null) {
        addWarning(
          'validation.channel.samples_after_track',
          'Channel ${entry.key.id} has samples after the last point (${latestAfter.toIso8601String()}); normalize timestamps to align sensor data with GPS fixes.',
          suggestedFix:
              'Call trimToPoints() on the channel, or discard samples outside the track time range.',
          priority: 3,
        );
      }
    }
  }

  void checkChannelValues() {
    for (final entry in activity.channels.entries) {
      final channel = entry.key;
      double? previousValue;
      for (final sample in entry.value) {
        final value = sample.value;
        final at = sample.time.toIso8601String();
        if (value.isNaN || value.isInfinite) {
          addError(
            'validation.channel.non_finite_value',
            'Channel ${channel.id} contains non-finite value $value at $at',
            suggestedFix:
                'Remove or replace the non-finite sample for channel ${channel.id}.',
            priority: 0,
          );
          previousValue = null;
          continue;
        }
        if (channel == Channel.distance && value < 0) {
          addError(
            'validation.channel.negative_distance',
            'Channel ${channel.id} has negative distance $value at $at',
            suggestedFix:
                'Distances must be ≥ 0; remove or correct this sample.',
            priority: 0,
          );
        }
        if (channel == Channel.distance &&
            previousValue != null &&
            value + 1e-9 < previousValue) {
          addWarning(
            'validation.channel.distance_decrease',
            'Channel ${channel.id} distance decreases from $previousValue to $value at $at',
            suggestedFix:
                'Distance values must be monotonically increasing; remove or correct the decreasing sample.',
            priority: 2,
          );
        }
        if (channel == Channel.heartRate && (value < 20 || value > 260)) {
          addWarning(
            'validation.channel.heart_rate_out_of_range',
            'Channel ${channel.id} heart rate $value bpm outside plausible range at $at',
            suggestedFix:
                'Verify the heart-rate sensor data; remove obvious spikes or apply a smoothing filter.',
            priority: 2,
          );
        }
        if (channel == Channel.power && value < 0) {
          addError(
            'validation.channel.negative_power',
            'Channel ${channel.id} power cannot be negative ($value) at $at',
            suggestedFix:
                'Replace negative power samples with 0 or remove them.',
            priority: 1,
          );
        }
        previousValue = value;
      }
    }
  }

  checkSeriesOrder<GeoPoint>(
    activity.points,
    (p) => p.time,
    'Points',
    'validation.points',
  );
  for (final entry in activity.channels.entries) {
    checkSeriesOrder<Sample>(
      entry.value,
      (sample) => sample.time,
      'Channel ${entry.key.id}',
      'validation.channel',
    );
  }
  checkChannelValues();
  checkCoordinates();
  checkLaps();
  checkChannelCoverage();

  return ValidationResult.fromDiagnostics(diags);
}

/// Validates [ActivityDeviceMetadata] for consistency and well-formedness.
///
/// Returns a list of [ValidationDiagnostic] items (possibly empty).  Checks:
/// - Manufacturer name / FIT ID consistency (known IDs vs stored name)
/// - Blank-but-present string fields
/// - Implausible FIT ID ranges
/// - FIT product / manufacturer ID sign (must be positive)
List<ValidationDiagnostic> validateDeviceMetadata(
  ActivityDeviceMetadata metadata,
) {
  final diags = <ValidationDiagnostic>[];

  bool isBlank(String? v) => v == null || v.trim().isEmpty;

  // Blank string fields that were explicitly set (non-null but empty/whitespace)
  void checkBlankString(String? value, String fieldName) {
    if (value != null && isBlank(value)) {
      diags.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: 'validation.device.blank_field',
          message:
              'ActivityDeviceMetadata.$fieldName is set but contains only whitespace.',
          suggestedFix: 'Set $fieldName to null rather than an empty string.',
          priority: 3,
        ),
      );
    }
  }

  checkBlankString(metadata.manufacturer, 'manufacturer');
  checkBlankString(metadata.model, 'model');
  checkBlankString(metadata.product, 'product');
  checkBlankString(metadata.serialNumber, 'serialNumber');
  checkBlankString(metadata.softwareVersion, 'softwareVersion');

  // FIT ID range checks — valid manufacturer IDs are 1–65534; 0 and 0xFFFF are reserved
  final mfgId = metadata.fitManufacturerId;
  if (mfgId != null) {
    if (mfgId <= 0 || mfgId >= 0xFFFF) {
      diags.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.error,
          code: 'validation.device.invalid_fit_manufacturer_id',
          message:
              'fitManufacturerId $mfgId is outside the valid FIT range (1–65534).',
          suggestedFix:
              'Use a valid FIT manufacturer ID; see the Garmin FIT SDK manufacturer list.',
          priority: 0,
        ),
      );
    } else {
      // Cross-check: if manufacturer name is set and the ID maps to a known
      // name, warn when they disagree (case-insensitive).
      final knownName = fitManufacturerNames[mfgId];
      final storedName = metadata.manufacturer?.trim();
      if (knownName != null &&
          storedName != null &&
          storedName.toLowerCase() != knownName.toLowerCase()) {
        diags.add(
          ValidationDiagnostic(
            severity: ValidationSeverity.warning,
            code: 'validation.device.manufacturer_name_mismatch',
            message:
                'fitManufacturerId $mfgId is known as "$knownName" but manufacturer is set to "$storedName".',
            suggestedFix:
                'Update manufacturer to "$knownName" to match the FIT SDK, or clear fitManufacturerId.',
            priority: 2,
          ),
        );
      }
    }
  }

  final prodId = metadata.fitProductId;
  if (prodId != null && prodId < 0) {
    diags.add(
      ValidationDiagnostic(
        severity: ValidationSeverity.error,
        code: 'validation.device.invalid_fit_product_id',
        message: 'fitProductId $prodId must not be negative.',
        suggestedFix:
            'Use a non-negative product ID or set fitProductId to null.',
        priority: 0,
      ),
    );
  }

  return diags;
}

/// Validates channel edge cases in [channels].
///
/// Returns diagnostics for:
/// - Empty channel lists that are present as map keys
/// - Channels with a single sample (interpolation not meaningful)
List<ValidationDiagnostic> validateChannels(
  Map<Channel, List<Sample>> channels,
) {
  final diags = <ValidationDiagnostic>[];

  for (final entry in channels.entries) {
    final channel = entry.key;
    final samples = entry.value;

    if (samples.isEmpty) {
      diags.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: 'validation.channel.empty',
          message:
              'Channel ${channel.id} is present in the activity but has no samples.',
          suggestedFix:
              'Remove the empty channel entry, or add at least one sample.',
          priority: 3,
        ),
      );
      continue;
    }

    if (samples.length == 1) {
      diags.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: 'validation.channel.single_sample',
          message:
              'Channel ${channel.id} has only one sample; interpolation will not be meaningful.',
          suggestedFix:
              'Verify that the sensor recorded data throughout the activity.',
          priority: 4,
        ),
      );
    }

    // Note: a "custom channel shadows a built-in" check is intentionally
    // absent. Channel.custom() normalizes IDs (trim + lowercase), so a custom
    // channel with a built-in name IS the built-in channel — the map cannot
    // hold a shadowing duplicate.
  }

  return diags;
}
