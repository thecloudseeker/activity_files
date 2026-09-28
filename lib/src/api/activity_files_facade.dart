// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:async/async.dart';
import '../channel_mapper.dart';
import '../encode/activity_encoder.dart';
import '../encode/encoder_options.dart';
import '../encode/csv_encoder.dart';
import '../encode/geojson_encoder.dart';
import '../fit/fit_epoch.dart';
import '../platform/file_system.dart' as file_system;
import '../platform/isolate_runner.dart' as isolate_runner;
import '../models.dart';
import '../parse/activity_parser.dart';
import '../parse/csv_parser.dart';
import '../parse/geojson_parser.dart';
import '../parse/parse_result.dart';
import '../transforms.dart';
import '../validation.dart';
import 'activity_export_request.dart';
import 'export_serialization.dart';
import 'export_stats.dart';
import '../pipeline_options.dart';

part 'facade/import_internals.dart';
part 'facade/transform_internals.dart';
part 'facade/edit_internals.dart';
part 'facade/helpers_internals.dart';
part 'facade/export_internals.dart';
part 'facade/results.dart';
part 'facade/raw_activity_builder.dart';

/// Callback used to translate arbitrary identifiers into [Sport] values.
typedef SportMapper = Sport? Function(dynamic source);

const int _defaultStreamBufferLimitBytes = 64 * 1024 * 1024;
const int _maxFormatDetectBytes = 128 * 1024;

/// Top-level facade exposing ergonomic helpers for app integrations.
class ActivityFiles {
  const ActivityFiles._();

  /// Default maximum payload size (bytes) processed by loaders when handling
  /// inline strings/byte arrays or buffered streams.
  static const int defaultMaxPayloadBytes = _defaultStreamBufferLimitBytes;

  static const String gpxDefaultExtensionNamespace =
      'https://schemas.activityfiles.dev/extensions';
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
  /// Set [maxPayloadBytes] to override the default 64MB limit for inline
  /// strings/bytes and buffered streams. Pass `null` to disable the limit.
  static Future<ActivityImportResult> import(
    Object source, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    Encoding encoding = utf8,
    bool allowFilePaths = false,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) async {
    final resolved = await _resolveSource(
      source,
      allowFilePaths: allowFilePaths,
    );
    if (maxPayloadBytes != null) {
      _enforcePayloadLimit(
        resolved.detectionBytes ?? resolved.payload,
        encoding: encoding,
        limit: maxPayloadBytes,
      );
    }
    final detected =
        format ??
        _detectFormat(
          resolved,
          encoding: encoding,
          maxPayloadBytes: maxPayloadBytes,
        );
    if (detected == null) {
      throw ArgumentError(
        'Unable to infer activity format from source. The format must be specified explicitly.\n'
        '\n'
        'To fix this, try one of the following:\n'
        '  1. Provide the format parameter: import(source, format: ActivityFileFormat.gpx)\n'
        '  2. Use a file with a recognized extension (.gpx, .tcx, .fit, .csv, .geojson)\n'
        '  3. If passing a filesystem path as a String, enable: import(source, allowFilePaths: true)\n'
        '\n'
        'Tips for common formats:\n'
        '  • GPX/TCX: Usually detected automatically from file extension\n'
        '  • FIT (binary): For base64-encoded FIT data, use import(bytes, format: ActivityFileFormat.fit)\n'
        '  • CSV/GeoJSON: Detectable from extension or content sniffing\n'
        '  • Inline content: Always specify format for text passed as a String\n'
        '\n'
        'Received: ${resolved.description} (extension: ${resolved.fileExtension ?? "none"})',
      );
    }
    ActivityParseResult parseResult;
    try {
      parseResult = await _parseResolved(
        resolved.payload,
        detected,
        useIsolate: useIsolate,
        encoding: encoding,
        maxPayloadBytes: maxPayloadBytes,
      );
    } on FormatException catch (error) {
      parseResult = _failedParseResult(format: detected, error: error);
    }
    if (_shouldFailFitIntegrity(
      detected,
      parseResult.diagnostics,
      _resolveStrictFitHandling(
        strictFitIntegrity: strictFitIntegrity,
        fitCorruptionHandling: fitCorruptionHandling,
      ),
    )) {
      throw _fitIntegrityFailure(parseResult.diagnostics);
    }
    final materialized = await _materializePayload(
      resolved.payload,
      maxBytes: maxPayloadBytes,
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
  /// Set [maxPayloadBytes] to override the default 64MB limit; pass `null`
  /// to disable the limit.
  static ActivityFileFormat? detectFormat(
    Object source, {
    Encoding encoding = utf8,
    bool allowFilePaths = false,
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) => _detectFormatSync(
    source,
    encoding: encoding,
    allowFilePaths: allowFilePaths,
    maxPayloadBytes: maxPayloadBytes,
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
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) async {
    final sourceList = sources.toList();
    final total = sourceList.length;
    final successes = <ActivityImportResult>[];
    final failures = <BatchImportFailure>[];
    var completed = 0;
    for (final source in sourceList) {
      try {
        successes.add(
          await import(
            source,
            format: format,
            useIsolate: useIsolate,
            maxPayloadBytes: maxPayloadBytes,
          ),
        );
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
      return Future.value(
        export(
          activity: activity,
          to: to,
          options: options,
          normalize: normalize,
          diagnostics: diagnostics,
          runValidation: runValidation,
          validation: validation,
        ),
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
  /// Set [maxPayloadBytes] to override the default 64MB limit for inline
  /// strings/bytes and buffered streams. Pass `null` to disable the limit.
  static Future<ActivityConversionResult> convert({
    required Object source,
    required ActivityFileFormat to,
    ActivityFileFormat? from,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool useIsolate = true,
    Encoding encoding = utf8,
    bool allowFilePaths = false,
    bool exportInIsolate = false,
    bool runValidation = true,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
  }) async {
    final loadResult = await import(
      source,
      format: from,
      useIsolate: useIsolate,
      encoding: encoding,
      allowFilePaths: allowFilePaths,
      strictFitIntegrity: strictFitIntegrity,
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
      final ordered = _ensureOrderedForExport(activity);
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
    (exportActivity, collected) = _applyAutoFix(
      exportActivity,
      autoFix,
      collected,
    );
    if (!exportInIsolate) {
      collected = [
        ...collected,
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
  /// Parsing occurs via [ActivityParser.parseStream]. Toggle [parseInIsolate]
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
    'Will be removed in 0.10.0.',
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
    ActivityExportRequest.fromStream(
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
  /// strings/bytes and buffered streams. Pass `null` to disable the limit.
  ///
  /// This method dispatches to one of two unrelated code paths depending on
  /// which argument is given: for new code, prefer calling the specific one
  /// directly: [convert] for [source]-based calls (identical behavior, no
  /// dispatch), or [buildAndExport] for [location]/[channels]-based calls.
  @Deprecated(
    'Use ActivityFiles.convert for source-based calls, or '
    'ActivityFiles.buildAndExport for location/channels-based calls. '
    'Will be removed in 0.10.0.',
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
    if (hasSource && hasStreams) {
      throw ArgumentError(
        'Cannot specify both source and location/channels inputs.\n'
        '\n'
        'Choose one input method:\n'
        '\n'
        'Option A: Convert from file/bytes\n'
        '  convertAndExport(source: File("activity.gpx"), to: ActivityFileFormat.tcx)\n'
        '\n'
        'Option B: Build from location and channel data\n'
        '  convertAndExport(\n'
        '    location: [LocationStreamSample(...)],\n'
        '    channels: {Channel.heartRate: [ChannelStreamSample(...)]},\n'
        '    to: ActivityFileFormat.gpx,\n'
        '  )\n'
        '\n'
        'You specified both source and location. Please use only one.',
      );
    }
    if (!hasSource && !hasStreams) {
      throw ArgumentError(
        'No input provided to convertAndExport. You must specify either source or location/channels.\n'
        '\n'
        'Example 1: Convert a file\n'
        '  final result = await convertAndExport(\n'
        '    source: File("activity.gpx"),\n'
        '    to: ActivityFileFormat.fit,\n'
        '  );\n'
        '\n'
        'Example 2: Convert from raw sensor data\n'
        '  final result = await convertAndExport(\n'
        '    location: gpsPoints,\n'
        '    channels: {\n'
        '      Channel.heartRate: heartRateSamples,\n'
        '      Channel.cadence: cadenceSamples,\n'
        '    },\n'
        '    to: ActivityFileFormat.gpx,\n'
        '  );\n'
        '\n'
        'Please provide one of: source (File, bytes, Stream) or location + channels.',
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
    'Will be removed in 0.10.0.',
  )
  static Future<ActivityExportResult> runPipeline(
    ActivityExportRequest request,
  ) => _runPipeline(request);

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
            ? inferSport(sportSource, fallback: Sport.unknown)
            : Sport.unknown);
    final derivedSport = (primarySport == Sport.unknown && label != null)
        ? inferSport(label, fallback: Sport.unknown)
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
      ActivityExportRequest.fromActivity(
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
  /// await ActivityFiles.convertAndExport(
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
  static void registerSportMapper(SportMapper mapper) {
    if (_sportMappers.contains(mapper)) {
      return;
    }
    _sportMappers.add(mapper);
  }

  /// Removes a previously registered [mapper].
  static bool unregisterSportMapper(SportMapper mapper) =>
      _sportMappers.remove(mapper);

  /// Clears all registered sport mappers.
  static void clearSportMappers() => _sportMappers.clear();

  /// Resolves [Sport] by applying registered mappers and built-in heuristics.
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
  // removal in 0.10.0. See each method's @Deprecated message for its
  // replacement.
  /// Deprecated name for [import]; forwards with identical behavior.
  @Deprecated('Use ActivityFiles.import instead. Will be removed in 0.10.0.')
  static Future<ActivityImportResult> load(
    Object source, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    Encoding encoding = utf8,
    bool allowFilePaths = false,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
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
    'Use ActivityFiles.importBatch instead. Will be removed in 0.10.0.',
  )
  static Future<BatchImportResult> loadBatch(
    Iterable<Object> sources, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    void Function(int completed, int total)? onProgress,
    bool stopOnError = false,
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
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
    'Use ActivityFiles.import(input, format: ActivityFileFormat.csv) instead '
    '(async, with normalize/validate). For a bare sync parse, use '
    'ActivityParser.parse(input, ActivityFileFormat.csv). '
    'Will be removed in 0.10.0.',
  )
  static ActivityParseResult importFromCsv(String input) =>
      const CsvParser().parse(input);

  /// Import a GeoJSON payload into a [RawActivity].
  @Deprecated(
    'Use ActivityFiles.import(input, format: ActivityFileFormat.geojson) '
    'instead (async, with normalize/validate). For a bare sync parse, use '
    'ActivityParser.parse(input, ActivityFileFormat.geojson). '
    'Will be removed in 0.10.0.',
  )
  static ActivityParseResult importFromGeojson(String input) =>
      const GeojsonParser().parse(input);

  /// Export an activity to CSV format.
  @Deprecated(
    'Use ActivityFiles.export(activity: activity, to: ActivityFileFormat.csv) '
    'instead. Will be removed in 0.10.0.',
  )
  static String exportToCsv(RawActivity activity) =>
      CsvEncoder.encode(activity);

  /// Export multiple activities to CSV format.
  @Deprecated(
    'Will be removed in 0.10.0 with no exact replacement. This concatenates '
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
    'ActivityFileFormat.geojson) instead. Will be removed in 0.10.0.',
  )
  static String exportToGeojson(RawActivity activity) =>
      GeojsonEncoder.encode(activity);

  /// Export an activity to GeoJSON Point FeatureCollection.
  @Deprecated(
    'Use ActivityFiles.export(activity: activity, to: '
    'ActivityFileFormat.geojson, options: EncoderOptions(geojsonGeometry: '
    'GeojsonGeometry.points, geojsonIncludeChannels: includeChannels)) '
    'instead. Will be removed in 0.10.0.',
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
    'Will be removed in 0.10.0.',
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
    'instead. Will be removed in 0.10.0.',
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
    'Will be removed in 0.10.0.',
  )
  static RawActivity sortAndDedup(RawActivity activity) =>
      RawEditor(activity).sortAndDedup().activity;

  /// Convenience wrapper for [RawEditor.trimInvalid].
  @Deprecated(
    'Use ActivityFiles.edit(activity).trimInvalid().activity instead. '
    'Will be removed in 0.10.0.',
  )
  static RawActivity trimInvalid(RawActivity activity) =>
      RawEditor(activity).trimInvalid().activity;

  /// Convenience wrapper for [RawEditor.crop].
  @Deprecated(
    'Use ActivityFiles.edit(activity).crop(start, end).activity instead. '
    'Will be removed in 0.10.0.',
  )
  static RawActivity crop(
    RawActivity activity, {
    required DateTime start,
    required DateTime end,
  }) => RawEditor(activity).crop(start, end).activity;

  /// Convenience wrapper for [RawEditor.smoothHR].
  @Deprecated(
    'Use ActivityFiles.edit(activity).smoothHR(window).activity instead. '
    'Will be removed in 0.10.0.',
  )
  static RawActivity smoothHeartRate(RawActivity activity, {int window = 5}) =>
      RawEditor(activity).smoothHR(window).activity;

  /// Convenience wrapper for [RawEditor.recomputeDistanceAndSpeed].
  @Deprecated(
    'Use ActivityFiles.edit(activity).recomputeDistanceAndSpeed().activity '
    'instead. Will be removed in 0.10.0.',
  )
  static RawActivity recomputeDistanceAndSpeed(RawActivity activity) =>
      RawEditor(activity).recomputeDistanceAndSpeed().activity;

  /// Deprecated name for [RawEditor.merge]; forwards with identical behavior.
  @Deprecated('Use RawEditor.merge instead. Will be removed in 0.10.0.')
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
  @Deprecated('Use RawEditor.splitBySport instead. Will be removed in 0.10.0.')
  static Map<Sport, RawActivity> splitBySport(
    RawActivity activity, {
    bool normalize = true,
  }) => RawEditor.splitBySport(activity, normalize: normalize);

  /// Deprecated name for [RawActivityBuilder.activityLabelNode]; forwards
  /// with identical behavior.
  @Deprecated(
    'Use RawActivityBuilder.activityLabelNode instead. Will be removed in 0.10.0.',
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
    'Use RawActivityBuilder.deviceNode instead. Will be removed in 0.10.0.',
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
    'Use RawActivityBuilder.deviceSummaryNode instead. Will be removed in 0.10.0.',
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
