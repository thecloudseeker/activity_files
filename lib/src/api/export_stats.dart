// SPDX-License-Identifier: BSD-3-Clause

/// Captures aggregated processing metrics for export flows.
class ActivityProcessingStats {
  const ActivityProcessingStats({this.normalization, this.validationDuration});

  /// Details about normalization effects, when applied.
  final NormalizationStats? normalization;

  /// Time taken to perform structural validation, if executed.
  final Duration? validationDuration;

  /// Whether normalization was applied during processing.
  bool get hasNormalization => normalization != null;

  /// Whether validation was executed.
  bool get hasValidationTiming => validationDuration != null;

  ActivityProcessingStats copyWith({
    NormalizationStats? normalization,
    Duration? validationDuration,
  }) => ActivityProcessingStats(
    normalization: normalization ?? this.normalization,
    validationDuration: validationDuration ?? this.validationDuration,
  );
}

/// Summarizes normalization adjustments performed before encoding.
class NormalizationStats {
  const NormalizationStats({
    required this.applied,
    required this.pointsBefore,
    required this.pointsAfter,
    required this.totalSamplesBefore,
    required this.totalSamplesAfter,
    required this.duration,
  });

  /// Whether normalization steps were executed.
  final bool applied;

  /// Point count prior to normalization.
  final int pointsBefore;

  /// Point count after normalization.
  final int pointsAfter;

  /// Total sensor sample count prior to normalization.
  final int totalSamplesBefore;

  /// Total sensor sample count after normalization.
  final int totalSamplesAfter;

  /// Time taken to normalize.
  final Duration duration;

  /// Difference in point count (after - before).
  int get pointsDelta => pointsAfter - pointsBefore;

  /// Difference in sample count (after - before).
  int get totalSamplesDelta => totalSamplesAfter - totalSamplesBefore;

  /// Whether any structural changes were observed.
  bool get hasChanges =>
      pointsBefore != pointsAfter || totalSamplesBefore != totalSamplesAfter;
}
