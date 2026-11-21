// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../channel_mapper.dart';
import '../encode/activity_encoder.dart';
import '../encode/csv_encoder.dart';
import '../encode/encoder_options.dart';
import '../encode/encoder_utils.dart';
import '../encode/finite_guard.dart';
import '../encode/geojson_encoder.dart';
import '../fit/fit_epoch.dart';
import '../models.dart';
import '../parse/activity_parser.dart';
import '../parse/csv_parser.dart';
import '../parse/geojson_parser.dart';
import '../parse/parse_result.dart';
import '../pipeline_options.dart';
import '../platform/file_system.dart' as file_system;
import '../platform/isolate_runner.dart' as isolate_runner;
import '../transforms.dart';
import '../validation.dart';
import 'activity_export_request.dart';
import 'export_serialization.dart';
import 'export_stats.dart';
import 'payload_limit.dart';

part 'facade/edit_internals.dart';
part 'facade/export_internals.dart';
part 'facade/export_request_internals.dart';
part 'facade/helpers_internals.dart';
part 'facade/import_internals.dart';
part 'facade/raw_activity_builder.dart';
part 'facade/results.dart';
part 'facade/transform_internals.dart';

/// Callback used to translate arbitrary identifiers into [Sport] values.
@Deprecated(
  'Pass the Sport you mean; it is no longer guessed from text. '
  'Will be removed in 0.11.0.',
)
typedef SportMapper = Sport? Function(dynamic source);

const int _defaultStreamBufferLimitBytes = 64 * 1024 * 1024;
const int _maxFormatDetectBytes = 128 * 1024;

/// Codes of the errors `import` reports for a source it could not read.
const Set<String> _sourceFailureCodes = {
  'parser.format_undetected',
  'import.source.unsupported',
  'import.source.unreadable',
  'import.source.read_failed',
  'import.payload.too_large',
};

/// Top-level facade exposing ergonomic helpers for app integrations.
class ActivityFiles {
  const ActivityFiles._();

  /// Default maximum payload size (bytes) processed by loaders when handling
  /// inline strings/byte arrays or buffered streams.
  static const int defaultMaxPayloadBytes = _defaultStreamBufferLimitBytes;

  /// Namespace declared for GPX extension elements this library writes when
  /// the caller supplies no namespace of its own.
  ///
  /// It is an identifier, not a location: XML namespace names are compared by
  /// string equality and never fetched, and this one is deliberately absent
  /// from the `xsi:schemaLocation` the GPX encoder writes.
  ///
  /// Extension nodes still carrying the previous default
  /// (`https://schemas.activityfiles.dev/extensions`), such as those parsed
  /// from an older export, are written under this namespace on export.
  static const String gpxDefaultExtensionNamespace = defaultExtensionNamespace;

  /// Prefix bound to [gpxDefaultExtensionNamespace] on the GPX root element.
  static const String gpxDefaultExtensionPrefix = 'ext';

  // Import -- file/bytes/stream => RawActivity.
  /// Imports [source] into a [RawActivity], attempting to infer the file format.
  ///
  /// Supported source types:
  /// * `String` containing inline text content. To read from disk pass a [File]
  ///   (preferred) or set [allowFilePaths] to `true` when you explicitly trust
  ///   the string to represent a local path.
  /// * `File`
  /// * `List<int>`/`Uint8List` with raw bytes (FIT binaries or already-encoded
  ///   text).
  /// * `Stream<List<int>>` representing chunked payloads.
  ///
  /// When [format] is omitted the loader will attempt to detect it from file
  /// extensions or by inspecting the payload. Specify [format] when the input
  /// is ambiguous (e.g. a FIT payload provided as a base64 string).
  ///
  /// Never throws because of [source]: a missing or unreadable file, an
  /// unsupported source type, a format that cannot be detected or a payload
  /// over [maxPayloadBytes] comes back as an empty activity with an error
  /// diagnostic, and [ActivityImportResult.format] is null when no format is
  /// known. Only [strictFitIntegrity], which asks for it, throws.
  ///
  /// Left out, [maxPayloadBytes] is a soft limit: a source over 64 MB is
  /// read with an `import.payload.large` warning, except a file of no known
  /// format, which is reported without being loaded. A number is a hard cap
  /// (a file is measured before it is read), even when it is 64 MB. Pass
  /// `null` for no limit.
  static Future<ActivityImportResult> import(
    Object source, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    Encoding encoding = utf8,
    @Deprecated(
      'Pass a File for a path; a String is always content. '
      'Will be removed in 0.11.0.',
    )
    bool allowFilePaths = false,
    bool strictFitIntegrity = false,
    @Deprecated('Use strictFitIntegrity instead. Will be removed in 0.11.0.')
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    int? maxPayloadBytes = softPayloadLimit,
  }) async {
    final softLimit = maxPayloadBytes == softPayloadLimit;
    final hardLimit = softLimit ? null : maxPayloadBytes;
    try {
      return await _importChecked(
        source,
        format: format,
        useIsolate: useIsolate,
        encoding: encoding,
        allowFilePaths: allowFilePaths,
        strictFitHandling: _resolveStrictFitHandling(
          strictFitIntegrity: strictFitIntegrity,
          fitCorruptionHandling: fitCorruptionHandling,
        ),
        hardLimit: hardLimit,
        softLimit: softLimit,
      );
    } on _FitIntegrityException {
      rethrow;
    } on _ImportFailure catch (failure) {
      return _failedImport(
        code: failure.code,
        message: failure.message,
        description: failure.description,
        format: failure.format ?? format,
      );
    } on _PayloadLimitException catch (error) {
      return _failedImport(
        code: 'import.payload.too_large',
        message: error.message,
        description: _describeSource(source),
        format: format ?? _formatFromSourcePath(source),
        suggestedFix:
            'Raise maxPayloadBytes, or leave it out for the soft default.',
      );
    } catch (error) {
      // Anything else comes from the source itself, such as a stream that
      // reports an error while it is read.
      return _failedImport(
        code: 'import.source.read_failed',
        message: 'Reading the source failed: $error',
        description: _describeSource(source),
        format: format ?? _formatFromSourcePath(source),
      );
    }
  }

  static Future<ActivityImportResult> _importChecked(
    Object source, {
    required ActivityFileFormat? format,
    required bool useIsolate,
    required Encoding encoding,
    required bool allowFilePaths,
    required bool strictFitHandling,
    required int? hardLimit,
    required bool softLimit,
  }) async {
    final resolved = await _resolveSource(
      source,
      allowFilePaths: allowFilePaths,
      maxPayloadBytes: hardLimit,
      softLimit: softLimit,
      format: format,
      encoding: encoding,
    );
    final ActivityFileFormat detected;
    try {
      if (hardLimit != null) {
        _enforcePayloadLimit(
          resolved.detectionBytes ?? resolved.payload,
          encoding: encoding,
          limit: hardLimit,
        );
      }
      final found = format ?? _detectFormat(resolved, encoding: encoding);
      if (found == null) {
        throw _ImportFailure.undetected(
          resolved.fileExtension == null
              ? resolved.description
              : '${resolved.description} (extension: ${resolved.fileExtension})',
          inline: resolved.description == 'inline',
        );
      }
      detected = found;
    } catch (_) {
      // A stream that was only sniffed is let go, so its source closes.
      await resolved.release?.call();
      rethrow;
    }
    ActivityParseResult parseResult;
    try {
      parseResult = await _parseResolved(
        resolved.payload,
        detected,
        useIsolate: useIsolate,
        encoding: encoding,
        maxPayloadBytes: hardLimit,
      );
    } on _PayloadLimitException {
      rethrow;
    } on FormatException catch (error) {
      parseResult = _failedParseResult(format: detected, error: error);
    }
    if (_shouldFailFitIntegrity(
      detected,
      parseResult.diagnostics,
      strictFitHandling,
    )) {
      throw _fitIntegrityFailure(parseResult.diagnostics);
    }
    final materialized = await _materializePayload(
      resolved.payload,
      maxBytes: hardLimit,
    );
    var diagnostics = parseResult.diagnostics;
    if (materialized.unavailable) {
      diagnostics = [
        ...diagnostics,
        const ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'activity.payload.unavailable',
          message:
              'The raw payload could not be re-materialized after parsing '
              '(exceeded maxPayloadBytes); payload/bytesPayload/'
              'stringPayload are empty. The parsed activity is unaffected.',
        ),
      ];
    }
    if (softLimit &&
        _payloadSizeAtLeast(materialized.payload) >
            _defaultStreamBufferLimitBytes) {
      diagnostics = [
        ...diagnostics,
        const ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'import.payload.large',
          message:
              'The source is larger than 64 MB; it was read in full because '
              'it is an activity file.',
          suggestedFix:
              'Pass maxPayloadBytes to refuse sources over a size you choose.',
        ),
      ];
    }
    return ActivityImportResult._(
      activity: parseResult.activity,
      diagnostics: diagnostics,
      format: detected,
      sourceDescription: resolved.description,
      payload: materialized.payload,
    );
  }

  /// Attempts to detect the activity format without parsing.
  ///
  /// This helper is useful when you want to branch your own logic based on
  /// format before calling [import] or [convert].
  ///
  /// Detection reads only the start of [source], so no size limit applies.
  static ActivityFileFormat? detectFormat(
    Object source, {
    Encoding encoding = utf8,
    @Deprecated(
      'Pass a File for a path; a String is always content. '
      'Will be removed in 0.11.0.',
    )
    bool allowFilePaths = false,
    @Deprecated(
      'Detection reads only the start of the source, so the limit has no '
      'effect. Will be removed in 0.11.0.',
    )
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) => _detectFormatSync(
    source,
    encoding: encoding,
    allowFilePaths: allowFilePaths,
  );

  /// Imports multiple sources in sequence and returns a [BatchImportResult].
  ///
  /// Each [sources] element is forwarded to [ActivityFiles.import]. If a
  /// source fails, the error is captured in [BatchImportResult.failures] and
  /// processing continues unless [stopOnError] is `true`.
  ///
  /// [onProgress] is called after each source completes, whether or not it
  /// succeeded, with the number of completed items and the total count.
  ///
  /// Example:
  /// ```dart
  /// final result = await ActivityFiles.importBatch(
  ///   files,
  ///   onProgress: (done, total) => print('$done / $total'),
  /// );
  /// print('Imported ${result.successes.length}, failed ${result.failures.length}');
  /// ```
  static Future<BatchImportResult> importBatch(
    Iterable<Object> sources, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    void Function(int completed, int total)? onProgress,
    bool stopOnError = false,
    int? maxPayloadBytes = softPayloadLimit,
  }) async {
    final sourceList = sources.toList();
    final total = sourceList.length;
    final successes = <ActivityImportResult>[];
    final failures = <BatchImportFailure>[];
    var completed = 0;
    for (final source in sourceList) {
      try {
        final result = await import(
          source,
          format: format,
          useIsolate: useIsolate,
          maxPayloadBytes: maxPayloadBytes,
        );
        // import reports a source it cannot read instead of throwing; the
        // batch still lists it as a failure.
        final unread = result.diagnostics
            .where((d) => _sourceFailureCodes.contains(d.code))
            .firstOrNull;
        if (unread != null) throw FormatException(unread.message);
        successes.add(result);
      } catch (error, stackTrace) {
        failures.add(
          BatchImportFailure(
            source: source,
            error: error,
            stackTrace: stackTrace,
          ),
        );
        if (stopOnError) break;
      } finally {
        // Runs before `break` exits the loop, so the aborted item still
        // reports progress.
        onProgress?.call(++completed, total);
      }
    }
    return BatchImportResult(
      successes: successes,
      failures: failures,
      total: total,
    );
  }

  // Export -- RawActivity => encoded output.
  /// Encodes an in-memory [activity] to [to], returning encoded payloads and
  /// aggregated diagnostics.
  static ActivityExportResult export({
    required RawActivity activity,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
    bool runValidation = true,
    ValidationResult? validation,
  }) => _exportFromActivity(
    activity: activity,
    to: to,
    options: options,
    normalize: normalize,
    diagnostics: diagnostics,
    runValidation: runValidation,
    validation: validation,
  );

  /// Asynchronous variant of [export] with optional isolate offloading.
  static Future<ActivityExportResult> exportAsync({
    required RawActivity activity,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
    bool runValidation = true,
    ValidationResult? validation,
    bool useIsolate = true,
  }) async {
    if (!useIsolate) {
      return export(
        activity: activity,
        to: to,
        options: options,
        normalize: normalize,
        diagnostics: diagnostics,
        runValidation: runValidation,
        validation: validation,
      );
    }
    final request = <String, Object?>{
      'activity': ExportSerialization.activityToJson(activity),
      'targetFormat': to.index,
      'options': ExportSerialization.encoderOptionsToJson(options),
      'normalize': normalize,
      'diagnostics': diagnostics
          .map(ExportSerialization.diagnosticToJson)
          .toList(growable: false),
      'runValidation': runValidation,
      'validation': validation != null
          ? ExportSerialization.validationToJson(validation)
          : null,
    };
    final response = await isolate_runner.runWithIsolation(
      () => _runExportIsolate(request),
      useIsolate: useIsolate,
    );
    return _decodeExportResult(response);
  }

  // Transform -- source format => target format, end to end.
  /// Converts [source] to [to], optionally inferring the source format.
  ///
  /// The returned [ActivityConversionResult] exposes the normalized activity,
  /// encoder output, and parser diagnostics gathered while loading the source.
  /// When [normalize] is `true` (default) the converter applies
  /// `RawEditor.sortAndDedup()` and `RawEditor.trimInvalid()` prior to
  /// encoding. When `false`, timestamps are still nudged into strict order
  /// if needed (nothing is dropped); see `repaired.duplicate_timestamps_adjusted`.
  /// Set [exportInIsolate] to `true` to offload encoding onto a background
  /// isolate while keeping parsing control via [useIsolate]. Enable
  /// [runValidation] to append structural validation diagnostics/results;
  /// disable it when conversion throughput matters more than validation output.
  ///
  /// Reads [source] as [import] does, with the same [maxPayloadBytes]
  /// rules, and never throws because of it.
  static Future<ActivityConversionResult> convert({
    required Object source,
    required ActivityFileFormat to,
    ActivityFileFormat? from,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool useIsolate = true,
    Encoding encoding = utf8,
    @Deprecated(
      'Pass a File for a path; a String is always content. '
      'Will be removed in 0.11.0.',
    )
    bool allowFilePaths = false,
    bool exportInIsolate = false,
    bool runValidation = true,
    bool strictFitIntegrity = false,
    @Deprecated('Use strictFitIntegrity instead. Will be removed in 0.11.0.')
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
    int? maxPayloadBytes = softPayloadLimit,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
  }) async {
    final loadResult = await import(
      source,
      format: from,
      useIsolate: useIsolate,
      encoding: encoding,
      // ignore: deprecated_member_use_from_same_package
      allowFilePaths: allowFilePaths,
      strictFitIntegrity: strictFitIntegrity,
      // ignore: deprecated_member_use_from_same_package
      fitCorruptionHandling: fitCorruptionHandling,
      maxPayloadBytes: maxPayloadBytes,
    );
    var activity = loadResult.activity;
    // Flatten before normalizing/ordering, not just before encoding: both of
    // those steps (and the lossy-diagnostics checks below) otherwise only
    // ever see the primary track, silently leaving additionalTracks' points,
    // laps, sets, etc. unprocessed until the encoder's own internal flatten
    // call right before writing bytes, by which point it's too late to fix
    // them up. RawActivity.flattened() is a no-op when there's nothing to
    // flatten, so this is free for single-track sources.
    final additionalTrackCount = activity.additionalTracks.length;
    if (to != ActivityFileFormat.gpx) {
      activity = activity.flattened();
    }
    NormalizationStats? normalizationStats;
    var repairDiagnostics = const <ValidationDiagnostic>[];
    if (normalize) {
      final normalized = _normalize(
        activity,
        sortAndDedup: true,
        trimInvalid: true,
        captureStats: true,
      );
      activity = normalized.activity;
      normalizationStats = normalized.stats;
      repairDiagnostics = normalized.repairDiagnostics;
    }
    var collected = List<ParseDiagnostic>.from(loadResult.diagnostics);
    collected.addAll(repairDiagnostics.map((d) => d.toParseDiagnostic()));
    var exportActivity = activity;
    if (!normalize) {
      // Auto-fix sees the data as read: the ordering step below nudges
      // shared timestamps apart, which would leave it no duplicates to drop.
      (exportActivity, collected) = _applyAutoFix(
        exportActivity,
        autoFix,
        collected,
      );
      final ordered = _ensureOrderedForExport(exportActivity);
      exportActivity = ordered.activity;
      collected.addAll(ordered.diagnostics.map((d) => d.toParseDiagnostic()));
    }
    if (to == ActivityFileFormat.gpx) {
      final trackResult = _normalizeAdditionalTracksForExport(
        exportActivity,
        normalize: normalize,
      );
      exportActivity = trackResult.activity;
      collected.addAll(
        trackResult.diagnostics.map((d) => d.toParseDiagnostic()),
      );
    }
    if (normalize) {
      (exportActivity, collected) = _applyAutoFix(
        exportActivity,
        autoFix,
        collected,
      );
    }
    if (!exportInIsolate) {
      final List<ParseDiagnostic> nonFinite;
      (exportActivity, nonFinite) = _dropNonFiniteForExport(exportActivity);
      collected = [
        ...collected,
        ...nonFinite,
        ..._lossyDiagnostics(
          exportActivity,
          to,
          additionalTrackCount: additionalTrackCount,
        ),
      ];
      final encoded = ActivityEncoder.encode(
        exportActivity,
        to,
        options: options,
      );
      ValidationResult? validation;
      Duration? validationDuration;
      if (runValidation) {
        final stopwatch = Stopwatch()..start();
        validation = validateRawActivity(exportActivity);
        stopwatch.stop();
        validationDuration = stopwatch.elapsed;
        collected = [...collected, ..._diagnosticsFromValidation(validation)];
      }
      return ActivityConversionResult._(
        activity: exportActivity,
        sourceFormat: loadResult.format,
        targetFormat: to,
        diagnostics: [...collected, ...diagnostics],
        encoderOptions: options,
        encoded: encoded,
        validation: validation,
        processingStats: ActivityProcessingStats(
          normalization: normalizationStats,
          validationDuration: validationDuration,
        ),
      );
    }
    // exportAsync's isolate path re-derives the rest of _lossyDiagnostics
    // from exportActivity itself once it lands in _exportFromActivity, but
    // exportActivity is already flattened by this point, so additionalTracks
    // reads 0 there; only this one check needs the count captured above.
    if (to != ActivityFileFormat.gpx && additionalTrackCount > 0) {
      collected = [
        ...collected,
        ParseDiagnostic(
          severity: ParseSeverity.info,
          code: '${DiagnosticCategory.lossy}.multi_track_flattened',
          message:
              'Source contains $additionalTrackCount additional track(s); '
              'the ${to.name} format cannot represent multiple tracks, so '
              'all tracks are merged into one during encoding.',
          suggestedFix: 'Export to GPX to preserve the multi-track structure.',
          priority: 4,
        ),
      ];
    }
    final exportResult = await exportAsync(
      activity: exportActivity,
      to: to,
      options: options,
      normalize: false,
      diagnostics: collected,
      runValidation: runValidation,
      useIsolate: true,
    );
    return ActivityConversionResult._(
      activity: exportResult.activity,
      sourceFormat: loadResult.format,
      targetFormat: to,
      encoderOptions: options,
      encoded: exportResult.encoded,
      binary: exportResult.isBinary ? exportResult.asBytes() : null,
      diagnostics: [...exportResult.diagnostics, ...diagnostics],
      validation: exportResult.validation,
      processingStats: exportResult.processingStats.copyWith(
        normalization: normalizationStats,
      ),
    );
  }

  /// Converts a [source] stream, normalizes, and exports to [to].
  ///
  /// The stream is read as [import] reads one. Toggle [parseInIsolate]
  /// and [exportInIsolate] to control isolate offloading for parse and export.
  ///
  /// Set [maxPayloadBytes] to override the default 64MB limit for buffered
  /// streams. Pass `null` to disable the limit.
  ///
  /// [convert] already accepts a `Stream<List<int>>` as its source and
  /// produces identical output, so this adds nothing but a required [from]
  /// and a renamed isolate flag. Neither path parses incrementally: both
  /// buffer the whole stream before parsing, so the memory profile is the
  /// same too.
  @Deprecated(
    'Use ActivityFiles.convert, which accepts a Stream<List<int>> source and '
    'produces identical output. Pass useIsolate for parseInIsolate, and pass '
    'from explicitly if the format is not detectable from the first 64KB. '
    'Will be removed in 0.11.0.',
  )
  static Future<ActivityExportResult> convertStream({
    required Stream<List<int>> source,
    required ActivityFileFormat from,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool parseInIsolate = true,
    bool exportInIsolate = false,
    Encoding encoding = utf8,
    bool runValidation = true,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
  }) => _runPipeline(
    _ExportRequest.fromStream(
      stream: source,
      from: from,
      to: to,
      options: options,
      normalize: normalize,
      parseInIsolate: parseInIsolate,
      exportInIsolate: exportInIsolate,
      runValidation: runValidation,
      encoding: encoding,
      strictFitIntegrity: strictFitIntegrity,
      fitCorruptionHandling: fitCorruptionHandling,
      autoFix: autoFix,
      maxPayloadBytes: maxPayloadBytes,
      diagnostics: diagnostics,
    ),
  );

  /// Converts directly to an encoded payload, returning the export result for
  /// chaining.
  ///
  /// Provide [source] to convert file/byte-backed content, or supply
  /// [location] (plus optional [channels]) to build from raw sensor streams.
  /// The normalized activity is validated by default and findings are appended
  /// to diagnostics; set [runValidation] to `false` to skip validation. Set
  /// [exportInIsolate] to `true` to offload encoding work to an isolate,
  /// matching [convert].
  ///
  /// Set [maxPayloadBytes] to override the default 64MB limit for inline
  /// strings/bytes, files and buffered streams; a file is measured before it
  /// is read. Pass `null` to disable the limit.
  ///
  /// This method dispatches to one of two unrelated code paths depending on
  /// which argument is given: for new code, prefer calling the specific one
  /// directly: [convert] for [source]-based calls (identical behavior, no
  /// dispatch), or [buildAndExport] for [location]/[channels]-based calls.
  @Deprecated(
    'Use ActivityFiles.convert for source-based calls, or '
    'ActivityFiles.buildAndExport for location/channels-based calls. '
    'Will be removed in 0.11.0.',
  )
  static Future<ActivityExportResult> convertAndExport({
    Object? source,
    Iterable<LocationStreamSample>? location,
    Map<Channel, Iterable<ChannelStreamSample>> channels = const {},
    Iterable<Lap> laps = const <Lap>[],
    Sport? sport,
    Object? sportSource,
    String? label,
    String? creator,
    ActivityDeviceMetadata? device,
    StreamTimestampDecoder? timestampConverter,
    Iterable<GpxExtensionNode> metadataExtensions = const [],
    Iterable<GpxExtensionNode> trackExtensions = const [],
    String? gpxMetadataName,
    String? gpxMetadataDescription,
    bool includeCreatorInGpxMetadataDescription = true,
    String? gpxTrackName,
    String? gpxTrackDescription,
    String? gpxTrackType,
    ActivityFileFormat? from,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool useIsolate = true,
    Encoding encoding = utf8,
    bool allowFilePaths = false,
    bool runValidation = true,
    bool exportInIsolate = false,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) {
    final hasSource = source != null;
    final hasStreams = location != null;
    // Exactly one input is meaningful: an assertion stops any other call
    // during development, and a release build returns an empty export with
    // an error.
    if (hasSource == hasStreams) {
      final problem = hasSource
          ? 'both a source and location/channels'
          : 'neither a source nor location/channels';
      assert(false, 'convertAndExport was called with $problem.');
      return Future.value(
        ActivityFiles.export(
          activity: RawActivity(),
          to: to,
          options: options,
          normalize: false,
          runValidation: false,
          diagnostics: [
            ParseDiagnostic(
              severity: ParseSeverity.error,
              code: 'call.invalid_argument',
              message:
                  'convertAndExport was called with $problem; nothing was '
                  'read.',
              suggestedFix: 'Pass either source or location (with channels).',
              priority: 0,
            ),
          ],
        ),
      );
    }

    if (source != null) {
      return _convertAndExportFromSource(
        source: source,
        from: from,
        to: to,
        options: options,
        normalize: normalize,
        useIsolate: useIsolate,
        encoding: encoding,
        allowFilePaths: allowFilePaths,
        runValidation: runValidation,
        exportInIsolate: exportInIsolate,
        strictFitIntegrity: strictFitIntegrity,
        fitCorruptionHandling: fitCorruptionHandling,
        autoFix: autoFix,
        maxPayloadBytes: maxPayloadBytes,
      );
    }
    return buildAndExport(
      location: location!,
      channels: channels,
      laps: laps,
      sport: sport,
      sportSource: sportSource,
      label: label,
      creator: creator,
      device: device,
      timestampConverter: timestampConverter,
      metadataExtensions: metadataExtensions,
      trackExtensions: trackExtensions,
      gpxMetadataName: gpxMetadataName,
      gpxMetadataDescription: gpxMetadataDescription,
      includeCreatorInGpxMetadataDescription:
          includeCreatorInGpxMetadataDescription,
      gpxTrackName: gpxTrackName,
      gpxTrackDescription: gpxTrackDescription,
      gpxTrackType: gpxTrackType,
      to: to,
      options: options,
      normalize: normalize,
      runValidation: runValidation,
      exportInIsolate: exportInIsolate,
      autoFix: autoFix,
    );
  }

  /// Runs the export pipeline using a declarative [ActivityExportRequest].
  ///
  /// The three request factories map one-to-one onto named-argument methods:
  /// `fromSource` and `fromStream` both onto [convert], which accepts a
  /// `Stream<List<int>>` source, and `fromActivity` onto [export]. Every
  /// field has an equivalent there, including `diagnostics`, so migrating
  /// loses nothing.
  @Deprecated(
    'Use ActivityFiles.convert or ActivityFiles.export instead; convert '
    'accepts a Stream<List<int>> source for the stream case. '
    'Will be removed in 0.11.0.',
  )
  static Future<ActivityExportResult> runPipeline(
    ActivityExportRequest request,
  ) => _runPipeline(
    _ExportRequest._(
      activity: request.activity,
      source: request.source,
      stream: request.stream,
      to: request.to,
      from: request.from,
      options: request.options,
      normalize: request.normalize,
      runValidation: request.runValidation,
      parseInIsolate: request.parseInIsolate,
      exportInIsolate: request.exportInIsolate,
      encoding: request.encoding,
      allowFilePaths: request.allowFilePaths,
      strictFitIntegrity: request.strictFitIntegrity,
      fitCorruptionHandling: request.fitCorruptionHandling,
      autoFix: request.autoFix,
      diagnostics: request.diagnostics,
      validation: request.validation,
      maxPayloadBytes: request.maxPayloadBytes,
    ),
  );

  // Edit -- mutating an existing RawActivity. RawEditor is the primary
  // editing surface (see edit()); these are normalization internals
  // shared by import/convert/export.
  /// Returns a [RawEditor] for fluent editing pipelines.
  static RawEditor edit(RawActivity activity) => RawEditor(activity);

  // Construct -- building a RawActivity from raw structured data with no
  // source format to parse.
  /// Starts a builder for assembling a [RawActivity] incrementally.
  ///
  /// Use [seed] to pre-populate the builder from an existing activity.
  static RawActivityBuilder builder([RawActivity? seed]) =>
      RawActivityBuilder(seed: seed);

  /// Creates a builder populated from raw location/channel streams.
  static RawActivityBuilder builderFromStreams({
    required Iterable<LocationStreamSample> location,
    Map<Channel, Iterable<ChannelStreamSample>> channels = const {},
    Iterable<Lap> laps = const <Lap>[],
    StreamTimestampDecoder? timestampConverter,
    Sport? sport,
    String? creator,
    ActivityDeviceMetadata? device,
  }) {
    final decode = timestampConverter ?? _defaultTimestampDecoder;
    final rawBuilder = ActivityFiles.builder();
    if (sport != null) {
      rawBuilder.sport = sport;
    }
    if (creator != null) {
      rawBuilder.creator = creator;
    }
    if (device != null) {
      rawBuilder.setDeviceMetadata(device);
    }
    for (final sample in location) {
      rawBuilder.addPoint(
        latitude: sample.latitude,
        longitude: sample.longitude,
        elevation: sample.elevation,
        time: decode(sample.timestamp),
      );
    }
    for (final entry in channels.entries) {
      for (final sample in entry.value) {
        rawBuilder.addSample(
          channel: entry.key,
          time: decode(sample.timestamp),
          value: sample.value.toDouble(),
        );
      }
    }
    if (laps.isNotEmpty) {
      rawBuilder.addLaps(laps);
    }
    return rawBuilder;
  }

  /// Builds a [RawActivity] from raw location/channel streams and exports it
  /// directly to [to], returning the export result for chaining.
  ///
  /// Equivalent to configuring [builderFromStreams] by hand and passing the
  /// result to [export], with GPX metadata/track fields and [autoFix] wired
  /// through. Use this instead of [convert] when there's no
  /// file/byte `source` to parse, only raw samples.
  static Future<ActivityExportResult> buildAndExport({
    required Iterable<LocationStreamSample> location,
    Map<Channel, Iterable<ChannelStreamSample>> channels = const {},
    Iterable<Lap> laps = const <Lap>[],
    Sport? sport,
    @Deprecated('Pass sport instead. Will be removed in 0.11.0.')
    Object? sportSource,
    @Deprecated(
      'Pass sport and gpxTrackName instead. Will be removed in 0.11.0.',
    )
    String? label,
    String? creator,
    ActivityDeviceMetadata? device,
    StreamTimestampDecoder? timestampConverter,
    Iterable<GpxExtensionNode> metadataExtensions = const [],
    Iterable<GpxExtensionNode> trackExtensions = const [],
    String? gpxMetadataName,
    String? gpxMetadataDescription,
    bool includeCreatorInGpxMetadataDescription = true,
    String? gpxTrackName,
    String? gpxTrackDescription,
    String? gpxTrackType,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool runValidation = true,
    bool exportInIsolate = false,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
  }) {
    final primarySport =
        sport ??
        (sportSource != null
            ? _resolveSport(sportSource) ?? Sport.unknown
            : Sport.unknown);
    final derivedSport = (primarySport == Sport.unknown && label != null)
        ? _resolveSport(label) ?? Sport.unknown
        : primarySport;
    final builder = builderFromStreams(
      location: location,
      channels: channels,
      laps: laps,
      timestampConverter: timestampConverter,
      sport: derivedSport,
      creator: creator,
      device: device,
    );
    builder.gpxIncludeCreatorMetadataDescription =
        includeCreatorInGpxMetadataDescription;
    if (gpxMetadataName != null) {
      builder.gpxMetadataName = gpxMetadataName;
    }
    if (gpxMetadataDescription != null) {
      builder.gpxMetadataDescription = gpxMetadataDescription;
    }
    final resolvedTrackName = gpxTrackName ?? label;
    if (resolvedTrackName != null) {
      builder.gpxTrackName = resolvedTrackName;
    }
    if (gpxTrackDescription != null) {
      builder.gpxTrackDescription = gpxTrackDescription;
    }
    if (gpxTrackType != null) {
      builder.gpxTrackType = gpxTrackType;
    }
    if (metadataExtensions.isNotEmpty) {
      builder.addGpxMetadataExtensions(metadataExtensions);
    }
    if (trackExtensions.isNotEmpty) {
      builder.addGpxTrackExtensions(trackExtensions);
    }
    final activity = builder.build(normalize: false);
    return _runPipeline(
      _ExportRequest.fromActivity(
        activity: activity,
        to: to,
        options: options,
        normalize: normalize,
        runValidation: runValidation,
        exportInIsolate: exportInIsolate,
        autoFix: autoFix,
      ),
    );
  }

  /// Returns all channels from [activity] as [ChannelStreamSample] lists,
  /// ready to pass directly to [buildAndExport].
  ///
  /// This removes the per-channel reconstruction glue when re-exporting a
  /// previously imported [RawActivity]. Timestamps are milliseconds since the
  /// epoch, matching [LocationStreamSample]/[ChannelStreamSample]'s
  /// [StreamTimestampDecoder] contract used by [builderFromStreams] and
  /// [buildAndExport]; round-tripping through this method does not lose
  /// sub-second precision.
  ///
  /// ```dart
  /// final channels = ActivityFiles.channelSamplesFrom(stored);
  /// await ActivityFiles.buildAndExport(
  ///   location: locationSamples,
  ///   channels: channels,
  ///   to: ActivityFileFormat.gpx,
  /// );
  /// ```
  static Map<Channel, List<ChannelStreamSample>> channelSamplesFrom(
    RawActivity activity,
  ) {
    final result = <Channel, List<ChannelStreamSample>>{};
    for (final entry in activity.channels.entries) {
      if (entry.value.isEmpty) continue;
      result[entry.key] = [
        for (final sample in entry.value)
          (timestamp: sample.time.millisecondsSinceEpoch, value: sample.value),
      ];
    }
    return result;
  }

  static DateTime _defaultTimestampDecoder(int timestamp) =>
      DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);

  // Helpers -- cross-cutting utilities (sport inference, validation,
  // channel queries) that don't act on a RawActivity lifecycle stage.
  /// Registers a [SportMapper] used by [inferSport]. New mappers are checked
  /// last-in-first-out so callers can override earlier defaults.
  @Deprecated(
    'Pass the Sport you mean; it is no longer guessed from text. '
    'Will be removed in 0.11.0.',
  )
  // ignore: deprecated_member_use_from_same_package
  static void registerSportMapper(SportMapper mapper) {
    if (_sportMappers.contains(mapper)) {
      return;
    }
    _sportMappers.add(mapper);
  }

  /// Removes a previously registered [mapper].
  @Deprecated(
    'Pass the Sport you mean; it is no longer guessed from text. '
    'Will be removed in 0.11.0.',
  )
  // ignore: deprecated_member_use_from_same_package
  static bool unregisterSportMapper(SportMapper mapper) =>
      _sportMappers.remove(mapper);

  /// Clears all registered sport mappers.
  @Deprecated(
    'Pass the Sport you mean; it is no longer guessed from text. '
    'Will be removed in 0.11.0.',
  )
  static void clearSportMappers() => _sportMappers.clear();

  /// Resolves [Sport] by applying registered mappers and built-in heuristics.
  @Deprecated(
    'Pass the Sport you mean; it is no longer guessed from text. '
    'Will be removed in 0.11.0.',
  )
  static Sport inferSport(dynamic source, {Sport fallback = Sport.unknown}) {
    final resolved = _resolveSport(source);
    return resolved ?? fallback;
  }

  /// Performs structural validation and returns detailed findings.
  static ValidationResult validate(
    RawActivity activity, {
    Duration gapWarningThreshold = const Duration(minutes: 5),
  }) => validateRawActivity(activity, gapWarningThreshold: gapWarningThreshold);

  /// Maps channels close to [timestamp] for quick lookups and UI overlays.
  static ChannelSnapshot channelSnapshot(
    DateTime timestamp,
    RawActivity activity, {
    Duration maxDelta = const Duration(seconds: 5),
  }) => ChannelMapper.mapAt(timestamp, activity.channels, maxDelta: maxDelta);

  // Deprecated -- kept as forwarders for compatibility; scheduled for
  // removal in 0.11.0. See each method's @Deprecated message for its
  // replacement.
  /// Deprecated name for [import]; forwards with identical behavior.
  @Deprecated('Use ActivityFiles.import instead. Will be removed in 0.11.0.')
  static Future<ActivityImportResult> load(
    Object source, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    Encoding encoding = utf8,
    bool allowFilePaths = false,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    int? maxPayloadBytes = softPayloadLimit,
  }) => import(
    source,
    format: format,
    useIsolate: useIsolate,
    encoding: encoding,
    allowFilePaths: allowFilePaths,
    strictFitIntegrity: strictFitIntegrity,
    fitCorruptionHandling: fitCorruptionHandling,
    maxPayloadBytes: maxPayloadBytes,
  );

  /// Deprecated name for [importBatch]; forwards with identical behavior.
  @Deprecated(
    'Use ActivityFiles.importBatch instead. Will be removed in 0.11.0.',
  )
  static Future<BatchImportResult> loadBatch(
    Iterable<Object> sources, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    void Function(int completed, int total)? onProgress,
    bool stopOnError = false,
    int? maxPayloadBytes = softPayloadLimit,
  }) => importBatch(
    sources,
    format: format,
    useIsolate: useIsolate,
    onProgress: onProgress,
    stopOnError: stopOnError,
    maxPayloadBytes: maxPayloadBytes,
  );

  /// Import a CSV payload into a [RawActivity].
  @Deprecated(
    'Use ActivityFiles.import(input, format: ActivityFileFormat.csv) instead. '
    'Will be removed in 0.11.0.',
  )
  static ActivityParseResult importFromCsv(String input) =>
      const CsvParser().parse(input);

  /// Import a GeoJSON payload into a [RawActivity].
  @Deprecated(
    'Use ActivityFiles.import(input, format: ActivityFileFormat.geojson) '
    'instead. Will be removed in 0.11.0.',
  )
  static ActivityParseResult importFromGeojson(String input) =>
      const GeojsonParser().parse(input);

  /// Export an activity to CSV format.
  @Deprecated(
    'Use ActivityFiles.export(activity: activity, to: ActivityFileFormat.csv) '
    'instead. Will be removed in 0.11.0.',
  )
  static String exportToCsv(RawActivity activity) =>
      CsvEncoder.encode(activity);

  /// Export multiple activities to CSV format.
  @Deprecated(
    'Will be removed in 0.11.0 with no exact replacement. This concatenates '
    'each activity\'s rows under one header, in input order, keeping every '
    'row. The closest alternative, RawEditor.merge() followed by '
    'ActivityFiles.export(), is NOT equivalent: it sorts all points by time '
    'and drops points whose timestamps collide across activities. Encode '
    'each activity separately if you need every row.',
  )
  static String exportToCsvMultiple(List<RawActivity> activities) =>
      CsvEncoder.encodeMultiple(activities);

  /// Export an activity to GeoJSON FeatureCollection (LineString).
  @Deprecated(
    'Use ActivityFiles.export(activity: activity, to: '
    'ActivityFileFormat.geojson) instead. Will be removed in 0.11.0.',
  )
  static String exportToGeojson(RawActivity activity) =>
      GeojsonEncoder.encode(activity);

  /// Export an activity to GeoJSON Point FeatureCollection.
  @Deprecated(
    'Use ActivityFiles.export(activity: activity, to: '
    'ActivityFileFormat.geojson, options: EncoderOptions(geojsonGeometry: '
    'GeojsonGeometry.points, geojsonIncludeChannels: includeChannels)) '
    'instead. Will be removed in 0.11.0.',
  )
  static String exportToGeojsonPoints(
    RawActivity activity, {
    bool includeChannels = false,
  }) => includeChannels
      ? GeojsonEncoder.encodeAsPointsWithChannels(activity)
      : GeojsonEncoder.encodeAsPoints(activity);

  /// Deprecated name for [convertStream]; forwards with identical behavior.
  @Deprecated(
    'Use ActivityFiles.convert, which accepts a Stream<List<int>> source. '
    'Will be removed in 0.11.0.',
  )
  static Future<ActivityExportResult> convertAndExportStream({
    required Stream<List<int>> source,
    required ActivityFileFormat from,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool parseInIsolate = true,
    bool exportInIsolate = false,
    Encoding encoding = utf8,
    bool runValidation = true,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) => convertStream(
    source: source,
    from: from,
    to: to,
    options: options,
    normalize: normalize,
    parseInIsolate: parseInIsolate,
    exportInIsolate: exportInIsolate,
    encoding: encoding,
    runValidation: runValidation,
    strictFitIntegrity: strictFitIntegrity,
    fitCorruptionHandling: fitCorruptionHandling,
    autoFix: autoFix,
    maxPayloadBytes: maxPayloadBytes,
  );

  /// Returns a normalized copy applying common cleanup transforms.
  ///
  /// When [sortAndDedup] or [trimInvalid] are `false` the corresponding step is
  /// skipped. Additional transforms can be chained post-call via
  /// [ActivityFiles.edit].
  @Deprecated(
    'Use ActivityFiles.edit(activity).sortAndDedup().trimInvalid().activity '
    'instead. Will be removed in 0.11.0.',
  )
  static RawActivity normalizeActivity(
    RawActivity activity, {
    bool sortAndDedup = true,
    bool trimInvalid = true,
  }) => _normalize(
    activity,
    sortAndDedup: sortAndDedup,
    trimInvalid: trimInvalid,
    captureStats: false,
  ).activity;

  /// Convenience wrapper for [RawEditor.sortAndDedup].
  @Deprecated(
    'Use ActivityFiles.edit(activity).sortAndDedup().activity instead. '
    'Will be removed in 0.11.0.',
  )
  static RawActivity sortAndDedup(RawActivity activity) =>
      RawEditor(activity).sortAndDedup().activity;

  /// Convenience wrapper for [RawEditor.trimInvalid].
  @Deprecated(
    'Use ActivityFiles.edit(activity).trimInvalid().activity instead. '
    'Will be removed in 0.11.0.',
  )
  static RawActivity trimInvalid(RawActivity activity) =>
      RawEditor(activity).trimInvalid().activity;

  /// Convenience wrapper for [RawEditor.crop].
  @Deprecated(
    'Use ActivityFiles.edit(activity).crop(start, end).activity instead. '
    'Will be removed in 0.11.0.',
  )
  static RawActivity crop(
    RawActivity activity, {
    required DateTime start,
    required DateTime end,
  }) => RawEditor(activity).crop(start, end).activity;

  /// Convenience wrapper for [RawEditor.smoothHR].
  @Deprecated(
    'Use ActivityFiles.edit(activity).smoothHR(window).activity instead. '
    'Will be removed in 0.11.0.',
  )
  static RawActivity smoothHeartRate(RawActivity activity, {int window = 5}) =>
      RawEditor(activity).smoothHR(window).activity;

  /// Convenience wrapper for [RawEditor.recomputeDistanceAndSpeed].
  @Deprecated(
    'Use ActivityFiles.edit(activity).recomputeDistanceAndSpeed().activity '
    'instead. Will be removed in 0.11.0.',
  )
  static RawActivity recomputeDistanceAndSpeed(RawActivity activity) =>
      RawEditor(activity).recomputeDistanceAndSpeed().activity;

  /// Deprecated name for [RawEditor.merge]; forwards with identical behavior.
  @Deprecated('Use RawEditor.merge instead. Will be removed in 0.11.0.')
  static RawActivity merge(
    List<RawActivity> activities, {
    bool preserveSportPerLap = false,
    bool normalize = true,
    String? creator,
  }) => RawEditor.merge(
    activities,
    preserveSportPerLap: preserveSportPerLap,
    normalize: normalize,
    creator: creator,
  );

  /// Deprecated name for [RawEditor.splitBySport]; forwards with identical
  /// behavior.
  @Deprecated('Use RawEditor.splitBySport instead. Will be removed in 0.11.0.')
  static Map<Sport, RawActivity> splitBySport(
    RawActivity activity, {
    bool normalize = true,
  }) => RawEditor.splitBySport(activity, normalize: normalize);

  /// Deprecated name for [RawActivityBuilder.activityLabelNode]; forwards
  /// with identical behavior.
  @Deprecated(
    'Use RawActivityBuilder.activityLabelNode instead. Will be removed in 0.11.0.',
  )
  static GpxExtensionNode gpxActivityLabelNode(
    String label, {
    String prefix = gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, String> attributes = const <String, String>{},
  }) => RawActivityBuilder.activityLabelNode(
    label,
    prefix: prefix,
    namespaceUri: namespaceUri,
    attributes: attributes,
  );

  /// Deprecated name for [RawActivityBuilder.deviceNode]; forwards with
  /// identical behavior.
  @Deprecated(
    'Use RawActivityBuilder.deviceNode instead. Will be removed in 0.11.0.',
  )
  static GpxExtensionNode gpxDeviceNode(
    ActivityDeviceMetadata metadata, {
    String prefix = gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, String> attributes = const <String, String>{},
    Map<String, Object?> extras = const <String, Object?>{},
  }) => RawActivityBuilder.deviceNode(
    metadata,
    prefix: prefix,
    namespaceUri: namespaceUri,
    attributes: attributes,
    extras: extras,
  );

  /// Deprecated name for [RawActivityBuilder.deviceSummaryNode]; forwards
  /// with identical behavior.
  @Deprecated(
    'Use RawActivityBuilder.deviceSummaryNode instead. Will be removed in 0.11.0.',
  )
  static GpxExtensionNode gpxDeviceSummaryNode(
    ActivityDeviceMetadata metadata, {
    String prefix = gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, Object?> extras = const <String, Object?>{},
  }) => RawActivityBuilder.deviceSummaryNode(
    metadata,
    prefix: prefix,
    namespaceUri: namespaceUri,
    extras: extras,
  );
}
