// SPDX-License-Identifier: BSD-3-Clause

/// Controls how FIT corruption diagnostics are handled by facade helpers.
enum FitCorruptionHandling {
  /// Keep best-effort parsing output and surface diagnostics.
  bestEffort,

  /// Throw when FIT header/trailer integrity diagnostics are present.
  strict,
}

/// Auto-fix options for common data quality issues.
class ActivityAutoFixOptions {
  const ActivityAutoFixOptions({
    this.fixInvalidGps = true,
    this.fixChannelDrift = true,
    this.fixDistanceDrift = true,
    this.fixTimestampGaps = true,
    this.autoLapByDistance = false,
    this.autoLapOnlyWhenMissing = true,
    this.autoLapDistanceMeters,
    this.runningLapDistanceMeters = 1000,
    this.cyclingLapDistanceMeters = 5000,
    this.defaultLapDistanceMeters = 1000,
    this.gapThreshold = const Duration(minutes: 5),
    this.maxInsertedGapPoints = 250,
  });

  const ActivityAutoFixOptions.disabled()
    : fixInvalidGps = false,
      fixChannelDrift = false,
      fixDistanceDrift = false,
      fixTimestampGaps = false,
      autoLapByDistance = false,
      autoLapOnlyWhenMissing = true,
      autoLapDistanceMeters = null,
      runningLapDistanceMeters = 1000,
      cyclingLapDistanceMeters = 5000,
      defaultLapDistanceMeters = 1000,
      gapThreshold = const Duration(minutes: 5),
      maxInsertedGapPoints = 0;

  final bool fixInvalidGps;
  final bool fixChannelDrift;
  final bool fixDistanceDrift;
  final bool fixTimestampGaps;

  /// Enables distance-based auto-lap generation in the pipeline autofix stage.
  final bool autoLapByDistance;

  /// When true, auto-lap generation only runs if activity has no laps.
  final bool autoLapOnlyWhenMissing;

  /// Optional global split distance override (meters).
  ///
  /// When null, sport-specific defaults are used.
  final double? autoLapDistanceMeters;

  /// Split distance for running activities (meters).
  final double runningLapDistanceMeters;

  /// Split distance for cycling activities (meters).
  final double cyclingLapDistanceMeters;

  /// Split distance for all other sports (meters).
  final double defaultLapDistanceMeters;

  final Duration gapThreshold;
  final int maxInsertedGapPoints;

  bool get isEnabled =>
      fixInvalidGps ||
      fixChannelDrift ||
      fixDistanceDrift ||
      (fixTimestampGaps && maxInsertedGapPoints > 0) ||
      autoLapByDistance;
}
