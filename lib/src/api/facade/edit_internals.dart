// SPDX-License-Identifier: BSD-3-Clause
part of '../activity_files_facade.dart';

({
  RawActivity activity,
  NormalizationStats? stats,
  List<ValidationDiagnostic> repairDiagnostics,
})
_normalize(
  RawActivity activity, {
  required bool sortAndDedup,
  required bool trimInvalid,
  required bool captureStats,
}) {
  final requested = sortAndDedup || trimInvalid;
  // Short-circuit when data is already normalized to avoid redundant cloning
  // in UI hot paths (performance optimization). Still counts as "applied"
  // when normalization was requested, even though no changes were needed.
  if (!requested || _isAlreadyNormalized(activity, sortAndDedup, trimInvalid)) {
    final stats = captureStats
        ? NormalizationStats(
            applied: requested,
            pointsBefore: activity.points.length,
            pointsAfter: activity.points.length,
            totalSamplesBefore: _totalSamples(activity),
            totalSamplesAfter: _totalSamples(activity),
            duration: Duration.zero,
          )
        : null;
    return (activity: activity, stats: stats, repairDiagnostics: const []);
  }
  final beforePoints = activity.points.length;
  final beforeSamples = captureStats ? _totalSamples(activity) : 0;
  final stopwatch = Stopwatch()..start();
  var editor = RawEditor(activity);
  if (sortAndDedup) {
    editor = editor.sortAndDedup();
  }
  if (trimInvalid) {
    editor = editor.trimInvalid();
  }
  final normalized = editor.activity;
  stopwatch.stop();
  return (
    activity: normalized,
    stats: captureStats
        ? NormalizationStats(
            applied: true,
            pointsBefore: beforePoints,
            pointsAfter: normalized.points.length,
            totalSamplesBefore: beforeSamples,
            totalSamplesAfter: _totalSamples(normalized),
            duration: stopwatch.elapsed,
          )
        : null,
    repairDiagnostics: editor.repairDiagnostics,
  );
}

/// Checks if the activity data is already normalized based on requested operations.
bool _isAlreadyNormalized(
  RawActivity activity,
  bool checkSortAndDedup,
  bool checkTrimInvalid,
) {
  if (checkSortAndDedup && !_isStrictlyOrderedActivity(activity)) {
    return false;
  }
  if (checkTrimInvalid) {
    final validCoordinates = activity.points.every(
      (p) =>
          p.latitude.isFinite &&
          p.latitude >= -90 &&
          p.latitude <= 90 &&
          p.longitude.isFinite &&
          p.longitude >= -180 &&
          p.longitude <= 180 &&
          !(p.latitude.abs() < 1e-6 && p.longitude.abs() < 1e-6) &&
          (p.elevation == null || p.elevation! > -499.0),
    );
    if (!validCoordinates) return false;
    if (activity.points.isNotEmpty) {
      final start = activity.points.first.time;
      final end = activity.points.last.time;
      final channelsInRange = activity.channels.values.every(
        (samples) => samples.every(
          (s) => !s.time.isBefore(start) && !s.time.isAfter(end),
        ),
      );
      if (!channelsInRange) return false;
      final lapsInRange = activity.laps.every(
        (lap) => !lap.startTime.isBefore(start) && !lap.endTime.isAfter(end),
      );
      if (!lapsInRange) return false;
    }
  }
  return true;
}

bool _isStrictlyOrderedActivity(RawActivity activity) =>
    _isStrictlyOrdered(activity.points, (p) => p.time) &&
    activity.channels.values.every(
      (samples) => _isStrictlyOrdered(samples, (s) => s.time),
    ) &&
    _isStrictlyOrdered(activity.laps, (l) => l.startTime);

({RawActivity activity, List<ValidationDiagnostic> diagnostics})
_ensureOrderedForExport(RawActivity activity) {
  if (_isStrictlyOrderedActivity(activity)) {
    return (activity: activity, diagnostics: const []);
  }
  final editor = RawEditor(activity).ensureStrictTimeOrder();
  return (activity: editor.activity, diagnostics: editor.repairDiagnostics);
}

/// Runs the same normalize-or-order-for-export step applied to the
/// primary track on each of [activity]'s `additionalTracks`.
///
/// GPX is the only target that keeps `additionalTracks` instead of
/// flattening them into the primary track before export (see convert()'s
/// flatten comment), so it's the only path where secondary tracks would
/// otherwise skip sortAndDedup/trimInvalid/time-ordering entirely.
({RawActivity activity, List<ValidationDiagnostic> diagnostics})
_normalizeAdditionalTracksForExport(
  RawActivity activity, {
  required bool normalize,
}) {
  if (activity.additionalTracks.isEmpty) {
    return (activity: activity, diagnostics: const []);
  }
  final diagnostics = <ValidationDiagnostic>[];
  final tracks = <RawActivity>[];
  for (final track in activity.additionalTracks) {
    if (normalize) {
      final result = _normalize(
        track,
        sortAndDedup: true,
        trimInvalid: true,
        captureStats: false,
      );
      tracks.add(result.activity);
      diagnostics.addAll(result.repairDiagnostics);
    } else {
      final result = _ensureOrderedForExport(track);
      tracks.add(result.activity);
      diagnostics.addAll(result.diagnostics);
    }
  }
  return (
    activity: activity.copyWith(additionalTracks: tracks),
    diagnostics: diagnostics,
  );
}

/// Checks if a list is sorted by time with no duplicate timestamps
/// (each entry strictly after its predecessor).
bool _isStrictlyOrdered<T>(List<T> items, DateTime Function(T) timeOf) {
  for (var i = 1; i < items.length; i++) {
    if (!timeOf(items[i]).toUtc().isAfter(timeOf(items[i - 1]).toUtc())) {
      return false;
    }
  }
  return true;
}

int _totalSamples(RawActivity activity) => activity.channels.values.fold(
  0,
  (total, samples) => total + samples.length,
);
