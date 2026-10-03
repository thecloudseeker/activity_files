part of '../activity_files_facade.dart';

ActivityExportResult _exportFromActivity({
  required RawActivity activity,
  required ActivityFileFormat to,
  required EncoderOptions options,
  required bool normalize,
  required Iterable<ParseDiagnostic> diagnostics,
  required bool runValidation,
  ValidationResult? validation,
}) {
  var working = activity;
  // See convert()'s matching comment: flatten before normalizing/ordering
  // so additionalTracks' points/laps/sets go through the same repairs as
  // the primary track, not just the encoder's own last-minute flatten.
  final additionalTrackCount = working.additionalTracks.length;
  if (to != ActivityFileFormat.gpx) {
    working = working.flattened();
  }
  NormalizationStats? normalizationStats;
  var repairDiagnostics = const <ValidationDiagnostic>[];
  if (!normalize) {
    final ordered = _ensureOrderedForExport(working);
    working = ordered.activity;
    repairDiagnostics = ordered.diagnostics;
  }
  if (normalize) {
    final normalized = _normalize(
      working,
      sortAndDedup: true,
      trimInvalid: true,
      captureStats: true,
    );
    working = normalized.activity;
    normalizationStats = normalized.stats;
    repairDiagnostics = normalized.repairDiagnostics;
  }
  if (to == ActivityFileFormat.gpx) {
    final trackResult = _normalizeAdditionalTracksForExport(
      working,
      normalize: normalize,
    );
    working = trackResult.activity;
    repairDiagnostics = [...repairDiagnostics, ...trackResult.diagnostics];
  }
  final encoded = ActivityEncoder.encode(working, to, options: options);
  final binary = to == ActivityFileFormat.fit
      ? Uint8List.fromList(base64Decode(encoded))
      : null;
  Duration? validationDuration;
  final validationResult =
      validation ??
      (runValidation
          ? (() {
              final stopwatch = Stopwatch()..start();
              final result = validateRawActivity(working);
              stopwatch.stop();
              validationDuration = stopwatch.elapsed;
              return result;
            })()
          : null);
  if (validation != null && runValidation) {
    validationDuration ??= Duration.zero;
  }
  final mergedDiagnostics = <ParseDiagnostic>[
    ...diagnostics,
    ...repairDiagnostics.map((d) => d.toParseDiagnostic()),
    ..._lossyDiagnostics(
      working,
      to,
      additionalTrackCount: additionalTrackCount,
    ),
    if (validationResult != null)
      ..._diagnosticsFromValidation(validationResult),
  ];
  return ActivityExportResult._(
    activity: working,
    targetFormat: to,
    encoderOptions: options,
    encoded: encoded,
    binary: binary,
    diagnostics: mergedDiagnostics,
    validation: validationResult,
    processingStats: ActivityProcessingStats(
      normalization: normalizationStats,
      validationDuration: validationDuration,
    ),
  );
}

Map<String, Object?> _runExportIsolate(Map<String, Object?> request) {
  final activity = ExportSerialization.activityFromJson(
    (request['activity'] as Map).cast<String, Object?>(),
  );
  final format = ActivityFileFormat.values[request['targetFormat'] as int];
  final options = ExportSerialization.encoderOptionsFromJson(
    (request['options'] as Map).cast<String, Object?>(),
  );
  final diagnostics = (request['diagnostics'] as List<dynamic>)
      .map<ParseDiagnostic>(
        (entry) => ExportSerialization.diagnosticFromJson(
          (entry as Map).cast<String, Object?>(),
        ),
      )
      .toList(growable: false);
  final validation = request['validation'] is Map
      ? ExportSerialization.validationFromJson(
          (request['validation'] as Map).cast<String, Object?>(),
        )
      : null;
  final result = ActivityFiles.export(
    activity: activity,
    to: format,
    options: options,
    normalize: request['normalize'] as bool,
    diagnostics: diagnostics,
    runValidation: request['runValidation'] as bool,
    validation: validation,
  );
  return _encodeExportResult(result);
}

/// Diagnostics for data an [activity] carries that the [to] format cannot
/// represent, so target-format loss is reported rather than silent.
///
/// Only *full* drops are reported: features the target encoder writes in some
/// form (e.g. GPX channel extensions, GeoJSON lap aggregates) are not flagged.
List<ParseDiagnostic> _lossyDiagnostics(
  RawActivity activity,
  ActivityFileFormat to, {
  required int additionalTrackCount,
}) {
  final diagnostics = <ParseDiagnostic>[];
  final format = to.name;
  void add(String code, String message, {String? fix}) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.info,
        code: '${DiagnosticCategory.lossy}.$code',
        message: message,
        suggestedFix: fix,
        priority: 4,
      ),
    );
  }

  const toFit = 'Export to FIT to preserve it.';
  if (to != ActivityFileFormat.gpx && additionalTrackCount > 0) {
    add(
      'multi_track_flattened',
      'Source contains $additionalTrackCount additional '
          'track(s); the $format format cannot represent multiple tracks, so '
          'all tracks are merged into one during encoding.',
      fix: 'Export to GPX to preserve the multi-track structure.',
    );
  }
  // Sets, timer events, swim lengths, additional sessions, and the session
  // summary are only representable in FIT.
  if (to != ActivityFileFormat.fit) {
    if (activity.sets.isNotEmpty) {
      add(
        'sets_dropped',
        '${activity.sets.length} strength-training set(s) cannot be '
            'represented in $format and are dropped.',
        fix: toFit,
      );
    }
    if (activity.events.isNotEmpty) {
      add(
        'events_dropped',
        '${activity.events.length} timer event(s) cannot be represented in '
            '$format and are dropped.',
        fix: toFit,
      );
    }
    if (activity.lengths.isNotEmpty) {
      add(
        'lengths_dropped',
        '${activity.lengths.length} pool-swim length(s) cannot be '
            'represented in $format and are dropped.',
        fix: toFit,
      );
    }
    if (activity.additionalSessions.isNotEmpty) {
      add(
        'sessions_dropped',
        '${activity.additionalSessions.length} additional session(s) cannot '
            'be represented in $format and are dropped.',
        fix: toFit,
      );
    }
    if (activity.summary?.isNotEmpty ?? false) {
      add(
        'summary_dropped',
        'The session summary statistics are not written to $format.',
        fix: toFit,
      );
    }
  }
  // Laps survive in TCX (native) and GeoJSON (aggregate properties); GPX and
  // CSV keep no lap information.
  const noLapFormats = {ActivityFileFormat.gpx, ActivityFileFormat.csv};
  if (noLapFormats.contains(to) && activity.laps.isNotEmpty) {
    add(
      'laps_dropped',
      '${activity.laps.length} lap(s) cannot be represented in $format and '
          'are dropped.',
      fix: 'Export to TCX or FIT to preserve laps.',
    );
  }
  // gpxWaypoints only has a writer in gpx_encoder.dart; every other format
  // silently drops it. Ordinarily a supplementary field alongside real
  // track points, but a GeoJSON source with only untimed marker features
  // (no track-ordering signal) parses to an activity whose *entire*
  // payload lives in gpxWaypoints -- exporting that to anything but GPX
  // would otherwise produce a near-empty file with no diagnostic at all.
  if (to != ActivityFileFormat.gpx && activity.gpxWaypoints.isNotEmpty) {
    add(
      'waypoints_dropped',
      '${activity.gpxWaypoints.length} waypoint(s) cannot be represented '
          'in $format and are dropped.',
      fix: 'Export to GPX to preserve waypoints.',
    );
  }
  // TCX's TPX extension only carries these five channels; there's no
  // fallback slot for arbitrary custom channels (unlike GPX's
  // TrackPointExtension, which round-trips unknown tags), so anything
  // else is dropped rather than invented as a non-standard tag.
  if (to == ActivityFileFormat.tcx) {
    final tcxChannels = {
      Channel.heartRate,
      Channel.cadence,
      Channel.speed,
      Channel.power,
      Channel.distance,
    };
    final droppedChannels =
        activity.channels.keys
            .where((channel) => !tcxChannels.contains(channel))
            .map((channel) => channel.id)
            .toList()
          ..sort();
    if (droppedChannels.isNotEmpty) {
      add(
        'channels_dropped',
        'Channel(s) ${droppedChannels.join(', ')} cannot be represented '
            'in TCX and are dropped.',
        fix: 'Export to FIT, GPX, GeoJSON, or CSV to preserve them.',
      );
    }
  }
  // FIT timestamps are seconds (unsigned) since the FIT epoch
  // (1989-12-31); anything earlier has no valid representation and is
  // clamped to the epoch by the encoder.
  if (to == ActivityFileFormat.fit && _hasPreFitEpochTimestamp(activity)) {
    add(
      'pre_fit_epoch_timestamps_clamped',
      'Some timestamp(s) predate the FIT epoch (1989-12-31) and were '
          'clamped to it; FIT cannot represent earlier dates.',
    );
  }
  return diagnostics;
}

bool _hasPreFitEpochTimestamp(RawActivity activity) =>
    activity.points.any((p) => p.time.isBefore(fitEpoch)) ||
    activity.channels.values.any(
      (samples) => samples.any((s) => s.time.isBefore(fitEpoch)),
    ) ||
    activity.laps.any(
      (l) => l.startTime.isBefore(fitEpoch) || l.endTime.isBefore(fitEpoch),
    ) ||
    activity.events.any((e) => e.time.isBefore(fitEpoch)) ||
    activity.lengths.any(
      (l) => l.startTime.isBefore(fitEpoch) || l.endTime.isBefore(fitEpoch),
    ) ||
    activity.sets.any(
      (s) => s.startTime.isBefore(fitEpoch) || s.endTime.isBefore(fitEpoch),
    );
