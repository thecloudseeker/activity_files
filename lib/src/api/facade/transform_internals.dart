part of '../activity_files_facade.dart';

// The convertAndExport(source: ...) branch, split out so it's callable
// (via convert(), which does the same thing) independently of the
// location/channels branch. See buildAndExport for that branch.
Future<ActivityExportResult> _convertAndExportFromSource({
  required Object source,
  required ActivityFileFormat? from,
  required ActivityFileFormat to,
  required EncoderOptions options,
  required bool normalize,
  required bool useIsolate,
  required Encoding encoding,
  required bool allowFilePaths,
  required bool runValidation,
  required bool exportInIsolate,
  required bool strictFitIntegrity,
  required FitCorruptionHandling fitCorruptionHandling,
  required ActivityAutoFixOptions autoFix,
  required int? maxPayloadBytes,
}) => _runPipeline(
  _ExportRequest.fromSource(
    source: source,
    from: from,
    to: to,
    options: options,
    normalize: normalize,
    parseInIsolate: useIsolate,
    runValidation: runValidation,
    encoding: encoding,
    exportInIsolate: exportInIsolate,
    allowFilePaths: allowFilePaths,
    strictFitIntegrity: strictFitIntegrity,
    fitCorruptionHandling: fitCorruptionHandling,
    autoFix: autoFix,
    maxPayloadBytes: maxPayloadBytes,
  ),
);

Future<ActivityExportResult> _runPipeline(_ExportRequest request) async {
  if (request.activity != null) {
    var activity = request.activity!;
    var diagnostics = List<ParseDiagnostic>.from(request.diagnostics);
    (activity, diagnostics) = _applyAutoFix(
      activity,
      request.autoFix,
      diagnostics,
    );
    if (request.exportInIsolate) {
      return ActivityFiles.exportAsync(
        activity: activity,
        to: request.to,
        options: request.options,
        normalize: request.normalize,
        diagnostics: diagnostics,
        runValidation: request.runValidation,
        validation: request.validation,
        useIsolate: true,
      );
    }
    return _exportFromActivity(
      activity: activity,
      to: request.to,
      options: request.options,
      normalize: request.normalize,
      diagnostics: diagnostics,
      runValidation: request.runValidation,
      validation: request.validation,
    );
  }
  if (request.stream != null) {
    ActivityParseResult parseResult;
    try {
      parseResult = await ActivityParser.parseStream(
        request.stream!,
        request.from!,
        useIsolate: request.parseInIsolate,
        encoding: request.encoding,
        maxBytes: request.maxPayloadBytes,
      );
    } on FormatException catch (error) {
      parseResult = _failedParseResult(format: request.from!, error: error);
    }
    if (_shouldFailFitIntegrity(
      request.from!,
      parseResult.diagnostics,
      _resolveStrictFitHandling(
        strictFitIntegrity: request.strictFitIntegrity,
        fitCorruptionHandling: request.fitCorruptionHandling,
      ),
    )) {
      throw _fitIntegrityFailure(parseResult.diagnostics);
    }
    var parsedActivity = parseResult.activity;
    var parseDiagnostics = List<ParseDiagnostic>.from(parseResult.diagnostics);
    (parsedActivity, parseDiagnostics) = _applyAutoFix(
      parsedActivity,
      request.autoFix,
      parseDiagnostics,
    );
    final downstreamDiagnostics = <ParseDiagnostic>[
      ...parseDiagnostics,
      ...request.diagnostics,
    ];
    final downstreamRequest = _ExportRequest.fromActivity(
      activity: parsedActivity,
      to: request.to,
      options: request.options,
      normalize: request.normalize,
      runValidation: request.runValidation,
      exportInIsolate: request.exportInIsolate,
      diagnostics: downstreamDiagnostics,
      validation: request.validation,
    );
    return _runPipeline(downstreamRequest);
  }
  if (request.source != null) {
    final conversion = await ActivityFiles.convert(
      source: request.source!,
      to: request.to,
      from: request.from,
      options: request.options,
      normalize: request.normalize,
      useIsolate: request.parseInIsolate,
      encoding: request.encoding,
      allowFilePaths: request.allowFilePaths,
      exportInIsolate: request.exportInIsolate,
      runValidation: request.runValidation,
      strictFitIntegrity: request.strictFitIntegrity,
      fitCorruptionHandling: request.fitCorruptionHandling,
      autoFix: request.autoFix,
      maxPayloadBytes: request.maxPayloadBytes,
    );
    var mergedDiagnostics = <ParseDiagnostic>[
      ...conversion.diagnostics,
      ...request.diagnostics,
    ];
    var result = conversion.copyWith(diagnostics: mergedDiagnostics);
    if (request.runValidation && conversion.validation == null) {
      final stopwatch = Stopwatch()..start();
      final validation = validateRawActivity(result.activity);
      stopwatch.stop();
      mergedDiagnostics = [
        ...mergedDiagnostics,
        ..._diagnosticsFromValidation(validation),
      ];
      result = result.copyWith(
        diagnostics: mergedDiagnostics,
        validation: validation,
        processingStats: result.processingStats.copyWith(
          validationDuration: stopwatch.elapsed,
        ),
      );
    }
    return result;
  }
  throw StateError(
    'An export request must specify an activity, source, or stream.',
  );
}

// Applies RawEditor.autoFix() when enabled and appends the resulting
// diagnostics; a no-op passthrough otherwise. Shared by convert() and both
// _runPipeline() branches so the isEnabled-check-and-diagnose sequence
// exists exactly once.
(RawActivity, List<ParseDiagnostic>) _applyAutoFix(
  RawActivity activity,
  ActivityAutoFixOptions options,
  List<ParseDiagnostic> diagnostics,
) {
  if (!options.isEnabled) {
    return (activity, diagnostics);
  }
  final fixed = RawEditor(activity).autoFix(options).activity;
  return (fixed, [...diagnostics, ..._autoFixDiagnostics(activity, fixed)]);
}

List<ParseDiagnostic> _autoFixDiagnostics(
  RawActivity before,
  RawActivity after,
) {
  final diagnostics = <ParseDiagnostic>[];
  final removedPoints = before.points.length - after.points.length;
  if (removedPoints > 0) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.info,
        code: 'autofix.invalid_gps.trimmed',
        message: 'Auto-fix removed $removedPoints invalid/out-of-range points.',
      ),
    );
  }
  final beforeSamples = _totalSamples(before);
  final afterSamples = _totalSamples(after);
  final deltaSamples = beforeSamples - afterSamples;
  if (deltaSamples > 0) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.info,
        code: 'autofix.channel_drift.trimmed',
        message:
            'Auto-fix removed $deltaSamples channel samples outside the valid trajectory window.',
      ),
    );
  }
  if (after.channels.containsKey(Channel.distance) &&
      !before.channels.containsKey(Channel.distance)) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.info,
        code: 'autofix.distance.recomputed',
        message: 'Auto-fix recomputed distance/speed channels from GPS points.',
      ),
    );
  }
  if (after.laps.length > before.laps.length) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.info,
        code: 'autofix.laps.auto_generated',
        message:
            'Auto-fix generated ${after.laps.length - before.laps.length} lap(s) from distance splits.',
      ),
    );
  }
  return diagnostics;
}
