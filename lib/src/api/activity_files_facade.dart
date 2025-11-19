// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:async/async.dart';
import '../channel_mapper.dart';
import '../encode/activity_encoder.dart';
import '../encode/encoder_options.dart';
import '../platform/file_system.dart' as file_system;
import '../platform/isolate_runner.dart' as isolate_runner;
import '../models.dart';
import '../parse/activity_parser.dart';
import '../parse/parse_result.dart';
import '../transforms.dart';
import '../validation.dart';
import 'activity_export_request.dart';
import 'export_serialization.dart';
import 'export_stats.dart';

/// Callback used to translate arbitrary identifiers into [Sport] values.
typedef SportMapper = Sport? Function(dynamic source);

/// Top-level facade exposing ergonomic helpers for app integrations.
class ActivityFiles {
  const ActivityFiles._();

  static final List<SportMapper> _sportMappers = <SportMapper>[];

  static const String gpxDefaultExtensionNamespace =
      'https://schemas.activityfiles.dev/extensions';
  static const String gpxDefaultExtensionPrefix = 'ext';

  /// Loads [source] into a [RawActivity], attempting to infer the file format.
  ///
  /// Supported source types:
  /// * `String` containing either inline text content or a path to a file.
  /// * `File`
  /// * `List<int>`/`Uint8List` with raw bytes (FIT binaries or already-encoded
  ///   text).
  /// * `Stream<List<int>>` representing chunked payloads.
  ///
  /// When [format] is omitted the loader will attempt to detect it from file
  /// extensions or by inspecting the payload. Specify [format] when the input
  /// is ambiguous (e.g. a FIT payload provided as a base64 string).
  static Future<ActivityLoadResult> load(
    Object source, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    Encoding encoding = utf8,
  }) async {
    final resolved = await _resolveSource(source);
    final detected = format ?? _detectFormat(resolved, encoding: encoding);
    if (detected == null) {
      throw ArgumentError(
        'Unable to infer activity format. Provide format explicitly.',
      );
    }
    final parseResult = await _parseResolved(
      resolved.payload,
      detected,
      useIsolate: useIsolate,
      encoding: encoding,
    );
    return ActivityLoadResult._(
      activity: parseResult.activity,
      diagnostics: parseResult.diagnostics,
      format: detected,
      sourceDescription: resolved.description,
      payload: resolved.payload,
    );
  }

  /// Converts [source] to [to], optionally inferring the source format.
  ///
  /// The returned [ActivityConversionResult] exposes the normalized activity,
  /// encoder output, and parser diagnostics gathered while loading the source.
  /// When [normalize] is `true` (default) the converter applies
  /// `RawEditor.sortAndDedup()` and `RawEditor.trimInvalid()` prior to encoding.
  /// Set [exportInIsolate] to `true` to offload encoding onto a background
  /// isolate while keeping parsing control via [useIsolate].
  static Future<ActivityConversionResult> convert({
    required Object source,
    required ActivityFileFormat to,
    ActivityFileFormat? from,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool useIsolate = true,
    Encoding encoding = utf8,
    bool exportInIsolate = false,
  }) async {
    final loadResult = await load(
      source,
      format: from,
      useIsolate: useIsolate,
      encoding: encoding,
    );
    var activity = loadResult.activity;
    NormalizationStats? normalizationStats;
    if (normalize) {
      final normalized = _normalize(
        activity,
        sortAndDedup: true,
        trimInvalid: true,
        captureStats: true,
      );
      activity = normalized.activity;
      normalizationStats = normalized.stats;
    }
    // TODO(perf-benchmark): After channel-cursor + distance lookup optimizations
    // ship, run large GPX/FIT export benchmarks to quantify the win and detect
    // regressions in conversion hot paths.
    if (!exportInIsolate) {
      final encoded = ActivityEncoder.encode(activity, to, options: options);
      final binary = to == ActivityFileFormat.fit
          ? Uint8List.fromList(base64Decode(encoded))
          : null;
      return ActivityConversionResult._(
        activity: activity,
        sourceFormat: loadResult.format,
        targetFormat: to,
        diagnostics: loadResult.diagnostics,
        encoderOptions: options,
        encoded: encoded,
        binary: binary,
        processingStats: ActivityProcessingStats(
          normalization: normalizationStats,
        ),
      );
    }
    final exportResult = await exportAsync(
      activity: activity,
      to: to,
      options: options,
      normalize: false,
      diagnostics: loadResult.diagnostics,
      runValidation: false,
      useIsolate: true,
    );
    return ActivityConversionResult._(
      activity: exportResult.activity,
      sourceFormat: loadResult.format,
      targetFormat: to,
      encoderOptions: options,
      encoded: exportResult.encoded,
      binary: exportResult.isBinary ? exportResult.asBytes() : null,
      diagnostics: exportResult.diagnostics,
      validation: exportResult.validation,
      processingStats: exportResult.processingStats.copyWith(
        normalization: normalizationStats,
      ),
    );
  }

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
    // TODO(extensibility): Support asynchronous/streamed iterables so extremely
    // large exports don't require the entire location/channel data in memory.
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

  /// Returns a [RawEditor] for fluent editing pipelines.
  static RawEditor edit(RawActivity activity) => RawEditor(activity);

  /// Returns a normalized copy applying common cleanup transforms.
  ///
  /// When [sortAndDedup] or [trimInvalid] are `false` the corresponding step is
  /// skipped. Additional transforms can be chained post-call via
  /// [ActivityFiles.edit].
  static RawActivity normalizeActivity(
    RawActivity activity, {
    bool sortAndDedup = true,
    bool trimInvalid = true,
  }) => _normalize(
    // TODO(perf): Short-circuit when the caller already normalized the data to
    // avoid redundant cloning in UI hot paths.
    activity,
    sortAndDedup: sortAndDedup,
    trimInvalid: trimInvalid,
    captureStats: false,
  ).activity;

  /// Convenience wrapper for [RawEditor.sortAndDedup].
  static RawActivity sortAndDedup(RawActivity activity) =>
      RawEditor(activity).sortAndDedup().activity;

  /// Convenience wrapper for [RawEditor.trimInvalid].
  static RawActivity trimInvalid(RawActivity activity) =>
      RawEditor(activity).trimInvalid().activity;

  /// Convenience wrapper for [RawEditor.crop].
  static RawActivity crop(
    RawActivity activity, {
    required DateTime start,
    required DateTime end,
  }) => RawEditor(activity).crop(start, end).activity;

  /// Convenience wrapper for [RawEditor.smoothHR].
  static RawActivity smoothHeartRate(RawActivity activity, {int window = 5}) =>
      RawEditor(activity).smoothHR(window).activity;

  /// Convenience wrapper for [RawEditor.recomputeDistanceAndSpeed].
  static RawActivity recomputeDistanceAndSpeed(RawActivity activity) =>
      RawEditor(activity).recomputeDistanceAndSpeed().activity;

  static ({RawActivity activity, NormalizationStats? stats}) _normalize(
    RawActivity activity, {
    required bool sortAndDedup,
    required bool trimInvalid,
    required bool captureStats,
  }) {
    if (!sortAndDedup && !trimInvalid) {
      final stats = captureStats
          ? NormalizationStats(
              applied: false,
              pointsBefore: activity.points.length,
              pointsAfter: activity.points.length,
              totalSamplesBefore: _totalSamples(activity),
              totalSamplesAfter: _totalSamples(activity),
              duration: Duration.zero,
            )
          : null;
      return (activity: activity, stats: stats);
    }
    final beforePoints = captureStats ? activity.points.length : 0;
    final beforeSamples = captureStats ? _totalSamples(activity) : 0;
    final stopwatch = captureStats ? Stopwatch() : null;
    stopwatch?.start();
    var editor = RawEditor(activity);
    if (sortAndDedup) {
      editor = editor.sortAndDedup();
    }
    if (trimInvalid) {
      editor = editor.trimInvalid();
    }
    final normalized = editor.activity;
    if (!captureStats) {
      return (activity: normalized, stats: null);
    }
    stopwatch!.stop();
    final stats = NormalizationStats(
      applied: true,
      pointsBefore: beforePoints,
      pointsAfter: normalized.points.length,
      totalSamplesBefore: beforeSamples,
      totalSamplesAfter: _totalSamples(normalized),
      duration: stopwatch.elapsed,
    );
    return (activity: normalized, stats: stats);
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

  /// Creates a GPX extension node representing an activity label.
  static GpxExtensionNode gpxActivityLabelNode(
    String label, {
    String prefix = gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, String> attributes = const <String, String>{},
  }) => GpxExtensionNode(
    name: 'activity',
    namespacePrefix: prefix,
    namespaceUri: namespaceUri ?? gpxDefaultExtensionNamespace,
    value: label,
    attributes: attributes,
  );

  /// Creates a GPX extension node describing a device payload.
  static GpxExtensionNode gpxDeviceNode(
    ActivityDeviceMetadata metadata, {
    String prefix = gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, String> attributes = const <String, String>{},
    Map<String, Object?> extras = const <String, Object?>{},
  }) {
    final uri = namespaceUri ?? gpxDefaultExtensionNamespace;
    return GpxExtensionNode(
      name: 'device',
      namespacePrefix: prefix,
      namespaceUri: uri,
      attributes: attributes,
      children: _deviceMetadataChildren(
        metadata,
        prefix: prefix,
        namespaceUri: uri,
        extras: extras,
      ),
    );
  }

  /// Creates a GPX extension node summarizing device metadata plus [extras].
  static GpxExtensionNode gpxDeviceSummaryNode(
    ActivityDeviceMetadata metadata, {
    String prefix = gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, Object?> extras = const <String, Object?>{},
  }) {
    final uri = namespaceUri ?? gpxDefaultExtensionNamespace;
    return GpxExtensionNode(
      name: 'deviceSummary',
      namespacePrefix: prefix,
      namespaceUri: uri,
      children: _deviceMetadataChildren(
        metadata,
        prefix: prefix,
        namespaceUri: uri,
        extras: extras,
      ),
    );
  }

  static DateTime _defaultTimestampDecoder(int timestamp) =>
      DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);

  static List<GpxExtensionNode> _deviceMetadataChildren(
    ActivityDeviceMetadata metadata, {
    required String? prefix,
    required String namespaceUri,
    Map<String, Object?> extras = const <String, Object?>{},
  }) {
    final children = <GpxExtensionNode>[];
    void addChild(String name, Object? value) {
      if (value == null) {
        return;
      }
      final text = value is DateTime
          ? value.toUtc().toIso8601String()
          : value.toString();
      if (text.trim().isEmpty) {
        return;
      }
      children.add(
        GpxExtensionNode(
          name: name,
          namespacePrefix: prefix,
          namespaceUri: namespaceUri,
          value: text,
        ),
      );
    }

    addChild('manufacturer', metadata.manufacturer);
    addChild('model', metadata.model);
    addChild('product', metadata.product);
    addChild('serialNumber', metadata.serialNumber);
    addChild('softwareVersion', metadata.softwareVersion);
    addChild('fitManufacturerId', metadata.fitManufacturerId);
    addChild('fitProductId', metadata.fitProductId);
    extras.forEach(addChild);
    return children;
  }

  static Sport? _resolveSport(dynamic source) {
    final custom = _applySportMappers(source);
    if (custom != null) {
      return custom;
    }
    final primitive = _inferSportPrimitive(source);
    if (primitive != null) {
      return primitive;
    }
    if (source is Map) {
      for (final value in source.values) {
        final nested = _resolveSport(value);
        if (nested != null) {
          return nested;
        }
      }
    } else if (source is Iterable) {
      for (final value in source) {
        final nested = _resolveSport(value);
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  static Sport? _applySportMappers(dynamic source) {
    for (var i = _sportMappers.length - 1; i >= 0; i--) {
      final result = _sportMappers[i](source);
      if (result != null) {
        return result;
      }
    }
    return null;
  }

  static Sport? _inferSportPrimitive(dynamic source) {
    if (source == null) {
      return null;
    }
    if (source is Sport) {
      return source;
    }
    if (source is String) {
      final normalized = source.trim().toLowerCase();
      if (normalized.isEmpty) {
        return null;
      }
      final tokens = _tokenizeSportString(normalized);
      if (_containsKeyword(tokens, _runningKeywords)) {
        return Sport.running;
      }
      if (_containsKeyword(tokens, _cyclingKeywords)) {
        return Sport.cycling;
      }
      if (_containsKeyword(tokens, _swimmingKeywords)) {
        return Sport.swimming;
      }
      if (_containsKeyword(tokens, _walkingKeywords)) {
        return Sport.walking;
      }
      if (_containsKeyword(tokens, _hikingKeywords)) {
        return Sport.hiking;
      }
      if (_containsKeyword(tokens, _otherKeywords)) {
        return Sport.other;
      }
      return null;
    }
    if (source is num) {
      switch (source.toInt()) {
        case 0:
          return Sport.other;
        case 1:
          return Sport.running;
        case 2:
          return Sport.cycling;
        case 3:
          return Sport.swimming;
        case 4:
          return Sport.walking;
        case 5:
          return Sport.hiking;
      }
    }
    return null;
  }

  static final RegExp _sportDelimiter = RegExp(r'[^a-z0-9]+');

  static const List<String> _runningKeywords = [
    'run',
    'running',
    'jog',
    'jogging',
  ];

  static const List<String> _cyclingKeywords = [
    'cycle',
    'cycling',
    'bike',
    'biking',
    'ride',
  ];

  static const List<String> _swimmingKeywords = ['swim', 'swimming'];
  static const List<String> _walkingKeywords = ['walk', 'walking'];
  static const List<String> _hikingKeywords = ['hike', 'hiking'];
  static const List<String> _otherKeywords = ['other'];

  static Set<String> _tokenizeSportString(String value) {
    return value
        .split(_sportDelimiter)
        .where((token) => token.isNotEmpty)
        .toSet();
  }

  static bool _containsKeyword(Set<String> tokens, List<String> keywords) {
    for (final keyword in keywords) {
      if (tokens.contains(keyword)) {
        return true;
      }
    }
    return false;
  }

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

  static ActivityExportResult _exportFromActivity({
    required RawActivity activity,
    required ActivityFileFormat to,
    required EncoderOptions options,
    required bool normalize,
    required Iterable<ParseDiagnostic> diagnostics,
    required bool runValidation,
    ValidationResult? validation,
  }) {
    var working = activity;
    NormalizationStats? normalizationStats;
    if (normalize) {
      final normalized = _normalize(
        working,
        sortAndDedup: true,
        trimInvalid: true,
        captureStats: true,
      );
      working = normalized.activity;
      normalizationStats = normalized.stats;
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

  static Map<String, Object?> _runExportIsolate(Map<String, Object?> request) {
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
    final result = export(
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

  /// Converts a [source] stream, normalizes, and exports to [to].
  ///
  /// Parsing occurs via [ActivityParser.parseStream]. Toggle [parseInIsolate]
  /// and [exportInIsolate] to control isolate offloading for parse and export.
  static Future<ActivityExportResult> convertAndExportStream({
    required Stream<List<int>> source,
    required ActivityFileFormat from,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool parseInIsolate = true,
    bool exportInIsolate = false,
    Encoding encoding = utf8,
    bool runValidation = false,
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
    ),
  );

  /// Converts directly to an encoded payload, returning the export result for
  /// chaining.
  ///
  /// Provide [source] to convert file/byte-backed content, or supply
  /// [location] (plus optional [channels]) to build from raw sensor streams.
  /// When [runValidation] is `true`, the normalized activity is validated and
  /// findings are appended to the diagnostics collection. Set [exportInIsolate]
  /// to `true` to offload encoding work to an isolate, matching [convert].
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
    bool runValidation = false,
    bool exportInIsolate = false,
  }) {
    final hasSource = source != null;
    final hasStreams = location != null;
    if (hasSource == hasStreams) {
      // TODO(ux): Surface parameter conflicts in the exception message and
      // reference documentation so API consumers know how to fix their inputs.
      throw ArgumentError(
        'Provide either source or location streams when converting, not both.',
      );
    }

    if (source != null) {
      return _runPipeline(
        ActivityExportRequest.fromSource(
          source: source,
          from: from,
          to: to,
          options: options,
          normalize: normalize,
          parseInIsolate: useIsolate,
          runValidation: runValidation,
          encoding: encoding,
          exportInIsolate: exportInIsolate,
        ),
      );
    }
    final primarySport =
        sport ??
        (sportSource != null
            ? inferSport(sportSource, fallback: Sport.unknown)
            : Sport.unknown);
    final derivedSport = (primarySport == Sport.unknown && label != null)
        ? inferSport(label, fallback: Sport.unknown)
        : primarySport;
    final builder = builderFromStreams(
      location: location!,
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
      ),
    );
  }

  /// Runs the export pipeline using a declarative [ActivityExportRequest].
  static Future<ActivityExportResult> runPipeline(
    ActivityExportRequest request,
  ) => _runPipeline(request);

  static Future<ActivityExportResult> _runPipeline(
    ActivityExportRequest request,
  ) async {
    // TODO(refactor): Break this branching logic into focused helpers so new
    // request types (e.g. async streams) can plug in without growing the
    // nested conditionals.
    if (request.activity != null) {
      final diagnostics = List<ParseDiagnostic>.from(request.diagnostics);
      if (request.exportInIsolate) {
        return exportAsync(
          activity: request.activity!,
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
        activity: request.activity!,
        to: request.to,
        options: request.options,
        normalize: request.normalize,
        diagnostics: diagnostics,
        runValidation: request.runValidation,
        validation: request.validation,
      );
    }
    if (request.stream != null) {
      final parseResult = await ActivityParser.parseStream(
        request.stream!,
        request.from!,
        useIsolate: request.parseInIsolate,
        encoding: request.encoding,
      );
      final downstreamDiagnostics = <ParseDiagnostic>[
        ...parseResult.diagnostics,
        ...request.diagnostics,
      ];
      final downstreamRequest = ActivityExportRequest.fromActivity(
        activity: parseResult.activity,
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
      final conversion = await convert(
        source: request.source!,
        to: request.to,
        from: request.from,
        options: request.options,
        normalize: request.normalize,
        useIsolate: request.parseInIsolate,
        encoding: request.encoding,
        exportInIsolate: request.exportInIsolate,
      );
      var mergedDiagnostics = <ParseDiagnostic>[
        ...conversion.diagnostics,
        ...request.diagnostics,
      ];
      var result = conversion.copyWith(diagnostics: mergedDiagnostics);
      if (request.runValidation) {
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
      'ActivityExportRequest must specify an activity, source, or stream.',
    );
  }

  /// Attempts to detect the activity format without parsing.
  ///
  /// This helper is useful when you want to branch your own logic based on
  /// format before calling [load] or [convert].
  static ActivityFileFormat? detectFormat(
    Object source, {
    Encoding encoding = utf8,
  }) => _detectFormatSync(source, encoding: encoding);

  static Future<_ResolvedSource> _resolveSource(Object source) async {
    if (source is _ResolvedSource) {
      return source;
    }
    if (source is Stream<List<int>>) {
      const sniffLimit = 64 * 1024;
      final queue = StreamQueue(source);
      final consumedChunks = <List<int>>[];
      final sniffBuffer = BytesBuilder(copy: false);
      var sniffedBytes = 0;
      while (sniffedBytes < sniffLimit && await queue.hasNext) {
        final chunk = await queue.next;
        consumedChunks.add(chunk);
        if (chunk.isEmpty) {
          continue;
        }
        final remaining = sniffLimit - sniffedBytes;
        if (remaining <= 0) {
          continue;
        }
        if (chunk.length <= remaining) {
          sniffBuffer.add(chunk);
          sniffedBytes += chunk.length;
        } else {
          sniffBuffer.add(chunk.sublist(0, remaining));
          sniffedBytes += remaining;
        }
      }
      Stream<List<int>> replay() async* {
        for (final chunk in consumedChunks) {
          if (chunk.isNotEmpty) {
            yield chunk;
          }
        }
        yield* queue.rest;
      }

      final sniffBytes = sniffedBytes == 0 ? null : sniffBuffer.takeBytes();
      return _ResolvedSource(
        payload: replay(),
        description: 'stream',
        detectionBytes: sniffBytes,
      );
    }
    if (source is Uint8List) {
      return _ResolvedSource(
        payload: Uint8List.fromList(source),
        description: 'bytes',
      );
    }
    if (source is List<int>) {
      return _ResolvedSource(
        payload: Uint8List.fromList(source),
        description: 'bytes',
      );
    }
    final fileRead = await file_system.readPlatformFile(source);
    if (fileRead != null) {
      return _ResolvedSource(
        payload: fileRead.bytes,
        description: fileRead.path,
        fileExtension: _extensionForPath(fileRead.path),
      );
    }
    if (source is String) {
      if (file_system.platformPathExists(source)) {
        final bytes = await file_system.readPlatformPath(source);
        return _ResolvedSource(
          payload: bytes,
          description: source,
          fileExtension: _extensionForPath(source),
        );
      }
      return _ResolvedSource(payload: source, description: 'inline');
    }
    throw ArgumentError('Unsupported source type ${source.runtimeType}.');
  }

  static ActivityFileFormat? _detectFormat(
    _ResolvedSource resolved, {
    required Encoding encoding,
  }) {
    final detectedFromExt = _detectFromExtension(resolved.fileExtension);
    if (detectedFromExt != null) {
      return detectedFromExt;
    }
    final candidate = resolved.detectionBytes ?? resolved.payload;
    if (candidate is Stream<List<int>>) {
      // Cannot inspect an unbuffered stream without consuming it.
      return null;
    }
    return _detectFromPayload(candidate, encoding: encoding);
  }

  static ActivityParseResult _parseSync(
    Object payload,
    ActivityFileFormat format,
    Encoding encoding,
  ) {
    return switch (payload) {
      String text => ActivityParser.parse(text, format),
      Uint8List bytes => _parseBytesWithBom(bytes, format, encoding),
      List<int> bytes =>
          ActivityParser.parseBytes(bytes, format, encoding: encoding),
      _ => throw ArgumentError(
        'Unsupported payload type ${payload.runtimeType}; expected String or List<int>.',
      ),
    };
  }

  static Future<ActivityParseResult> _parseResolved(
    Object payload,
    ActivityFileFormat format, {
    bool useIsolate = true,
    Encoding encoding = utf8,
  }) {
    if (payload is Stream<List<int>>) {
      return ActivityParser.parseStream(
        payload,
        format,
        useIsolate: useIsolate,
        encoding: encoding,
      );
    }
    return isolate_runner.runWithIsolation(
      () => _parseSync(payload, format, encoding),
      useIsolate: useIsolate,
    );
  }

  static ActivityFileFormat? _detectFormatSync(
    Object source, {
    required Encoding encoding,
  }) {
    if (source is _ResolvedSource) {
      return _detectFormat(source, encoding: encoding);
    }
    final filePath = file_system.platformFilePath(source);
    if (filePath != null) {
      return _detectFromExtension(_extensionForPath(filePath));
    }
    if (source is String) {
      if (file_system.platformPathExists(source)) {
        return _detectFromExtension(_extensionForPath(source));
      }
      return _detectFromPayload(source, encoding: encoding);
    }
    if (source is List<int> || source is Uint8List) {
      return _detectFromPayload(source, encoding: encoding);
    }
    if (source is Stream<List<int>>) {
      // Cannot inspect streams without consuming; return null.
      return null;
    }
    return null;
  }

  static ActivityFileFormat? _detectFromExtension(String? ext) {
    switch (ext) {
      case '.gpx':
        return ActivityFileFormat.gpx;
      case '.tcx':
        return ActivityFileFormat.tcx;
      case '.fit':
        return ActivityFileFormat.fit;
      default:
        return null;
    }
  }

  static ActivityFileFormat? _detectFromPayload(
    Object payload, {
    required Encoding encoding,
  }) {
    if (payload is String) {
      return _detectFromText(payload);
    }
    final bytes = payload is Uint8List
        ? payload
        : Uint8List.fromList(payload as List<int>);
    final bomDecoder = _decoderForBom(bytes);
    if (bomDecoder != null) {
      final decoded = bomDecoder(bytes);
      final detectedFromBom = _detectFromText(decoded);
      if (detectedFromBom != null) {
        return detectedFromBom;
      }
    }
    if (_looksBinary(bytes)) {
      return ActivityFileFormat.fit;
    }
    try {
      return _detectFromText(encoding.decode(bytes));
    } on FormatException {
      final fallback = utf8.decode(bytes, allowMalformed: true);
      return _detectFromText(fallback);
    }
  }

  static String? _extensionForPath(String path) {
    final normalized = path.trim();
    final dot = normalized.lastIndexOf('.');
    if (dot < 0 || dot == normalized.length - 1) {
      return null;
    }
    return normalized.substring(dot).toLowerCase();
  }

  static bool _looksBinary(Uint8List bytes) {
    var controlCount = 0;
    for (final byte in bytes) {
      if (byte == 0) {
        return true;
      }
      if (byte < 9 && byte != 0) {
        controlCount++;
      }
      if (controlCount > 4) {
        return true;
      }
    }
    return false;
  }

  static bool _looksBase64(String text) {
    final trimmed = text.replaceAll(RegExp(r'\s+'), '');
    if (trimmed.isEmpty || trimmed.length % 4 != 0) {
      return false;
    }
    return RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(trimmed);
  }

  static ActivityFileFormat? _detectFromText(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.startsWith('<')) {
      final lower = trimmed.toLowerCase();
      if (lower.contains('<gpx')) {
        return ActivityFileFormat.gpx;
      }
      if (lower.contains('trainingcenterdatabase') || lower.contains('<tcx')) {
        return ActivityFileFormat.tcx;
      }
    }
    if (_looksBase64(trimmed)) {
      return ActivityFileFormat.fit;
    }
    return null;
  }

  static String Function(Uint8List bytes)? _decoderForBom(Uint8List bytes) {
    if (bytes.length >= 2) {
      final first = bytes[0];
      final second = bytes[1];
      if (first == 0xFF && second == 0xFE) {
        return (data) => _decodeUtf16(data, Endian.little);
      }
      if (first == 0xFE && second == 0xFF) {
        return (data) => _decodeUtf16(data, Endian.big);
      }
    }
    if (bytes.length >= 4) {
      final b0 = bytes[0];
      final b1 = bytes[1];
      final b2 = bytes[2];
      final b3 = bytes[3];
      if (b0 == 0x00 && b1 == 0x00 && b2 == 0xFE && b3 == 0xFF) {
        return (data) => _decodeUtf32(data, Endian.big);
      }
      if (b0 == 0xFF && b1 == 0xFE && b2 == 0x00 && b3 == 0x00) {
        return (data) => _decodeUtf32(data, Endian.little);
      }
    }
    return null;
  }

  static String _decodeUtf32(Uint8List bytes, Endian endian) {
    if (bytes.length < 4) {
      return '';
    }
    final buffer = StringBuffer();
    final view = bytes.buffer.asByteData();
    final usableLength = bytes.length - (bytes.length % 4);
    for (var offset = 4; offset < usableLength; offset += 4) {
      final codePoint = view.getUint32(offset, endian);
      if (codePoint == 0) {
        continue;
      }
      buffer.writeCharCode(codePoint);
    }
    return buffer.toString();
  }

  static String _decodeUtf16(Uint8List bytes, Endian endian) {
    if (bytes.length < 2) {
      return '';
    }
    final view = bytes.buffer.asByteData();
    final usableLength = bytes.length - (bytes.length % 2);
    final codeUnits = <int>[];
    for (var offset = 2; offset < usableLength; offset += 2) {
      final value = view.getUint16(offset, endian);
      if (value == 0) {
        continue;
      }
      codeUnits.add(value);
    }
    final buffer = StringBuffer();
    for (var i = 0; i < codeUnits.length; i++) {
      final unit = codeUnits[i];
      if (_isHighSurrogate(unit) && i + 1 < codeUnits.length) {
        final next = codeUnits[i + 1];
        if (_isLowSurrogate(next)) {
          final composed = 0x10000 + ((unit - 0xD800) << 10) + (next - 0xDC00);
          buffer.writeCharCode(composed);
          i++;
          continue;
        }
      }
      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  static bool _isHighSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;
  static bool _isLowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;

  static ActivityParseResult _parseBytesWithBom(
    Uint8List bytes,
    ActivityFileFormat format,
    Encoding encoding,
  ) {
    if (format != ActivityFileFormat.fit) {
      final bomDecoder = _decoderForBom(bytes);
      if (bomDecoder != null) {
        final decoded = bomDecoder(bytes);
        return ActivityParser.parse(decoded, format);
      }
    }
    return ActivityParser.parseBytes(bytes, format, encoding: encoding);
  }

  static int _totalSamples(RawActivity activity) {
    var total = 0;
    for (final samples in activity.channels.values) {
      total += samples.length;
    }
    return total;
  }
}

Map<String, Object?> _encodeExportResult(ActivityExportResult result) => {
  'activity': ExportSerialization.activityToJson(result.activity),
  'targetFormat': result.targetFormat.index,
  'options': ExportSerialization.encoderOptionsToJson(result.encoderOptions),
  'encoded': result.encoded,
  'binary': result.isBinary ? result.asBytes() : null,
  'diagnostics': result.diagnostics
      .map(ExportSerialization.diagnosticToJson)
      .toList(growable: false),
  'validation': result.validation == null
      ? null
      : ExportSerialization.validationToJson(result.validation!),
  'processing': ExportSerialization.processingStatsToJson(
    result.processingStats,
  ),
};

ActivityExportResult _decodeExportResult(Map<String, Object?> data) {
  final validation = data['validation'] is Map
      ? ExportSerialization.validationFromJson(
          (data['validation'] as Map).cast<String, Object?>(),
        )
      : null;
  final diagnostics = (data['diagnostics'] as List<dynamic>)
      .map<ParseDiagnostic>(
        (entry) => ExportSerialization.diagnosticFromJson(
          (entry as Map).cast<String, Object?>(),
        ),
      )
      .toList(growable: false);
  final binaryRaw = data['binary'];
  Uint8List? binary;
  if (binaryRaw is Uint8List) {
    binary = Uint8List.fromList(binaryRaw);
  } else if (binaryRaw is List<dynamic>) {
    binary = Uint8List.fromList(binaryRaw.cast<int>());
  }
  return ActivityExportResult._(
    activity: ExportSerialization.activityFromJson(
      (data['activity'] as Map).cast<String, Object?>(),
    ),
    targetFormat: ActivityFileFormat.values[data['targetFormat'] as int],
    encoderOptions: ExportSerialization.encoderOptionsFromJson(
      (data['options'] as Map).cast<String, Object?>(),
    ),
    encoded: data['encoded'] as String,
    binary: binary,
    diagnostics: diagnostics,
    validation: validation,
    processingStats: ExportSerialization.processingStatsFromJson(
      (data['processing'] as Map?)?.cast<String, Object?>(),
    ),
  );
}

List<ParseDiagnostic> _diagnosticsFromValidation(ValidationResult validation) {
  final diagnostics = <ParseDiagnostic>[];
  for (final message in validation.errors) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.error,
        code: 'validation.error',
        message: message,
      ),
    );
  }
  for (final message in validation.warnings) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.warning,
        code: 'validation.warning',
        message: message,
      ),
    );
  }
  return diagnostics;
}

mixin _DiagnosticSummaryMixin {
  List<ParseDiagnostic> get diagnostics;

  DiagnosticsFormatter get _formatter => DiagnosticsFormatter(diagnostics);

  /// Whether diagnostics were recorded.
  bool get hasDiagnostics => _formatter.hasDiagnostics;

  /// Number of info-level diagnostics.
  int get infoCount => _formatter.infoCount;

  /// Number of warning-level diagnostics.
  int get warningCount => _formatter.warningCount;

  /// Number of error-level diagnostics.
  int get errorCount => _formatter.errorCount;

  /// Convenience flag indicating warnings were recorded.
  bool get hasWarnings => _formatter.hasWarnings;

  /// Convenience flag indicating errors were recorded.
  bool get hasErrors => _formatter.hasErrors;

  /// Returns the number of diagnostics matching [severity].
  int countBySeverity(ParseSeverity severity) => _formatter.count(severity);

  /// Formats diagnostics into a single string for quick logging or UI badges.
  String diagnosticsSummary({
    ParseSeverity minSeverity = ParseSeverity.warning,
    bool includeSeverity = true,
    bool includeCodes = true,
    bool includeNode = false,
    String separator = '\n',
  }) => _formatter.summary(
    minSeverity: minSeverity,
    includeSeverity: includeSeverity,
    includeCodes: includeCodes,
    includeNode: includeNode,
    separator: separator,
  );
}

/// Result of [ActivityFiles.load].
class ActivityLoadResult with _DiagnosticSummaryMixin {
  ActivityLoadResult._({
    required this.activity,
    required Iterable<ParseDiagnostic> diagnostics,
    required this.format,
    required this.sourceDescription,
    required this.payload,
  }) : diagnostics = List.unmodifiable(diagnostics);
  // TODO(perf): Share payload/diagnostic views when possible instead of
  // cloning large buffers for every load result.

  /// Parsed activity.
  final RawActivity activity;

  @override
  final List<ParseDiagnostic> diagnostics;

  /// Detected format of the payload.
  final ActivityFileFormat format;

  /// Human-readable description of the source (e.g. file path).
  final String sourceDescription;

  /// Raw payload used during parsing (String or Uint8List).
  final Object payload;

  /// Returns the raw payload as bytes when available.
  Uint8List? get bytesPayload =>
      payload is Uint8List ? payload as Uint8List : null;

  /// Returns the raw payload as text when available.
  String? get stringPayload => payload is String ? payload as String : null;
}

/// Encoded export bundle returned by [ActivityFiles.export].
class ActivityExportResult with _DiagnosticSummaryMixin {
  ActivityExportResult._({
    required this.activity,
    required this.targetFormat,
    required this.encoderOptions,
    required this.encoded,
    Uint8List? binary,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
    this.validation,
    this.processingStats = const ActivityProcessingStats(),
  }) : _binary = binary != null ? Uint8List.fromList(binary) : null,
       diagnostics = List.unmodifiable(List<ParseDiagnostic>.from(diagnostics));
  // TODO(perf): Avoid double-copying FIT binaries/diagnostics when callers
  // already hand over owned buffers.

  /// Normalized activity that was encoded.
  final RawActivity activity;

  /// Target format for the encoded payload.
  final ActivityFileFormat targetFormat;

  /// Encoder options used for the export.
  final EncoderOptions encoderOptions;

  /// Encoder output as a string. FIT payloads are base64 strings.
  final String encoded;

  /// Validation findings emitted during export, if requested.
  final ValidationResult? validation;

  final Uint8List? _binary;

  /// Processing metrics collected during normalization/validation.
  final ActivityProcessingStats processingStats;

  @override
  final List<ParseDiagnostic> diagnostics;

  /// Whether the payload is binary (FIT).
  bool get isBinary => targetFormat == ActivityFileFormat.fit;

  /// Returns the payload as bytes (UTF-8 for text formats).
  Uint8List asBytes({Encoding encoding = utf8}) {
    if (isBinary) {
      return Uint8List.fromList(_binary ?? base64Decode(encoded));
    }
    return Uint8List.fromList(encoding.encode(encoded));
  }

  /// Returns the payload as a string, decoding binary payloads to base64.
  String asString() => encoded;

  /// Clones the export result with overrides.
  ActivityExportResult copyWith({
    RawActivity? activity,
    ActivityFileFormat? targetFormat,
    EncoderOptions? encoderOptions,
    String? encoded,
    Uint8List? binary,
    Iterable<ParseDiagnostic>? diagnostics,
    ValidationResult? validation,
    ActivityProcessingStats? processingStats,
  }) {
    final nextTargetFormat = targetFormat ?? this.targetFormat;
    final encodedProvided = encoded != null;
    final nextEncoded = encoded ?? this.encoded;
    final encodedChanged = encodedProvided && encoded != this.encoded;
    final reuseExistingBinary =
        binary == null &&
        !encodedChanged &&
        nextTargetFormat == this.targetFormat;
    final nextBinary = nextTargetFormat == ActivityFileFormat.fit
        ? (binary ?? (reuseExistingBinary ? _binary : null))
        : null;
    return ActivityExportResult._(
      activity: activity ?? this.activity,
      targetFormat: nextTargetFormat,
      encoderOptions: encoderOptions ?? this.encoderOptions,
      encoded: nextEncoded,
      binary: nextBinary,
      diagnostics: diagnostics ?? this.diagnostics,
      validation: validation ?? this.validation,
      processingStats: processingStats ?? this.processingStats,
    );
  }
}

/// Result of [ActivityFiles.convert].
class ActivityConversionResult extends ActivityExportResult {
  ActivityConversionResult._({
    required this.sourceFormat,
    required super.activity,
    required super.targetFormat,
    required super.encoderOptions,
    required super.encoded,
    super.binary,
    super.diagnostics = const <ParseDiagnostic>[],
    super.validation,
    super.processingStats = const ActivityProcessingStats(),
  }) : super._();

  /// Detected format of the source payload.
  final ActivityFileFormat sourceFormat;

  /// Clones the conversion result with overrides.
  @override
  ActivityConversionResult copyWith({
    RawActivity? activity,
    ActivityFileFormat? sourceFormat,
    ActivityFileFormat? targetFormat,
    EncoderOptions? encoderOptions,
    String? encoded,
    Uint8List? binary,
    Iterable<ParseDiagnostic>? diagnostics,
    ValidationResult? validation,
    ActivityProcessingStats? processingStats,
  }) {
    final nextSourceFormat = sourceFormat ?? this.sourceFormat;
    final nextTargetFormat = targetFormat ?? this.targetFormat;
    final encodedProvided = encoded != null;
    final nextEncoded = encoded ?? this.encoded;
    final encodedChanged = encodedProvided && encoded != this.encoded;
    final reuseExistingBinary =
        binary == null &&
        !encodedChanged &&
        nextTargetFormat == this.targetFormat;
    final nextBinary = nextTargetFormat == ActivityFileFormat.fit
        ? (binary ?? (reuseExistingBinary ? _binary : null))
        : null;
    return ActivityConversionResult._(
      activity: activity ?? this.activity,
      sourceFormat: nextSourceFormat,
      targetFormat: nextTargetFormat,
      encoderOptions: encoderOptions ?? this.encoderOptions,
      encoded: nextEncoded,
      binary: nextBinary,
      diagnostics: diagnostics ?? this.diagnostics,
      validation: validation ?? this.validation,
      processingStats: processingStats ?? this.processingStats,
    );
  }
}

/// Fluent builder for assembling [RawActivity] instances.
class RawActivityBuilder {
  RawActivityBuilder({RawActivity? seed})
    : sport = seed?.sport ?? Sport.unknown,
      creator = seed?.creator,
      device = seed?.device,
      gpxMetadataName = seed?.gpxMetadataName,
      gpxMetadataDescription = seed?.gpxMetadataDescription,
      gpxIncludeCreatorMetadataDescription =
          seed?.gpxIncludeCreatorMetadataDescription ?? true,
      gpxTrackName = seed?.gpxTrackName,
      gpxTrackDescription = seed?.gpxTrackDescription,
      gpxTrackType = seed?.gpxTrackType {
    if (seed != null) {
      addPoints(seed.points);
      seed.channels.forEach(addChannel);
      addLaps(seed.laps);
      _metadataExtensions.addAll(seed.gpxMetadataExtensions);
      _trackExtensions.addAll(seed.gpxTrackExtensions);
    }
  }

  /// Dominant sport classification.
  Sport sport;

  /// Originating device or software label.
  String? creator;

  /// Metadata describing the recording device.
  ActivityDeviceMetadata? device;

  /// Optional metadata title used for GPX exports.
  String? gpxMetadataName;

  /// Optional metadata description used for GPX exports.
  String? gpxMetadataDescription;

  /// Whether GPX encoders should fall back to [creator] when description null.
  bool gpxIncludeCreatorMetadataDescription;

  /// Optional GPX track name override.
  String? gpxTrackName;

  /// Optional GPX track description.
  String? gpxTrackDescription;

  /// Optional GPX track type override.
  String? gpxTrackType;

  final List<GeoPoint> _points = <GeoPoint>[];
  final Map<Channel, List<Sample>> _channels = <Channel, List<Sample>>{};
  final List<Lap> _laps = <Lap>[];
  final List<GpxExtensionNode> _metadataExtensions = <GpxExtensionNode>[];
  final List<GpxExtensionNode> _trackExtensions = <GpxExtensionNode>[];

  /// Adds a geographic point.
  RawActivityBuilder addPoint({
    required double latitude,
    required double longitude,
    double? elevation,
    required DateTime time,
  }) {
    _points.add(
      GeoPoint(
        latitude: latitude,
        longitude: longitude,
        elevation: elevation,
        time: time,
      ),
    );
    return this;
  }

  /// Adds multiple points.
  RawActivityBuilder addPoints(Iterable<GeoPoint> points) {
    _points.addAll(points.map((point) => point.copyWith()));
    return this;
  }

  /// Adds or replaces a channel with the provided samples.
  RawActivityBuilder addChannel(Channel channel, Iterable<Sample> samples) {
    _channels[channel] = samples.map((sample) => sample.copyWith()).toList();
    return this;
  }

  /// Adds a single sample to [channel].
  RawActivityBuilder addSample({
    required Channel channel,
    required DateTime time,
    required double value,
  }) {
    final list = _channels.putIfAbsent(channel, () => <Sample>[]);
    list.add(Sample(time: time, value: value));
    return this;
  }

  /// Appends laps.
  RawActivityBuilder addLaps(Iterable<Lap> laps) {
    _laps.addAll(laps.map((lap) => lap.copyWith()));
    return this;
  }

  /// Adds a single lap.
  RawActivityBuilder addLap({
    required DateTime startTime,
    required DateTime endTime,
    double? distanceMeters,
    String? name,
  }) {
    _laps.add(
      Lap(
        startTime: startTime,
        endTime: endTime,
        distanceMeters: distanceMeters,
        name: name,
      ),
    );
    return this;
  }

  /// Replaces the device metadata payload.
  RawActivityBuilder setDeviceMetadata(ActivityDeviceMetadata? metadata) {
    device = metadata;
    return this;
  }

  /// Configures GPX metadata name/description behaviour.
  RawActivityBuilder configureGpxMetadata({
    String? name,
    String? description,
    bool? includeCreatorDescription,
  }) {
    gpxMetadataName = name ?? gpxMetadataName;
    gpxMetadataDescription = description ?? gpxMetadataDescription;
    if (includeCreatorDescription != null) {
      gpxIncludeCreatorMetadataDescription = includeCreatorDescription;
    }
    return this;
  }

  /// Configures GPX track presentation values.
  RawActivityBuilder configureGpxTrack({
    String? name,
    String? description,
    String? type,
  }) {
    gpxTrackName = name ?? gpxTrackName;
    gpxTrackDescription = description ?? gpxTrackDescription;
    gpxTrackType = type ?? gpxTrackType;
    return this;
  }

  /// Adds GPX metadata-level extensions.
  RawActivityBuilder addGpxMetadataExtensions(
    Iterable<GpxExtensionNode> extensions,
  ) {
    _metadataExtensions.addAll(extensions);
    return this;
  }

  /// Adds a single GPX metadata-level extension.
  RawActivityBuilder addGpxMetadataExtension(GpxExtensionNode extension) {
    _metadataExtensions.add(extension);
    return this;
  }

  /// Adds GPX track-level extensions.
  RawActivityBuilder addGpxTrackExtensions(
    Iterable<GpxExtensionNode> extensions,
  ) {
    _trackExtensions.addAll(extensions);
    return this;
  }

  /// Adds a single GPX track-level extension.
  RawActivityBuilder addGpxTrackExtension(GpxExtensionNode extension) {
    _trackExtensions.add(extension);
    return this;
  }

  /// Removes any previously added GPX extensions.
  RawActivityBuilder clearGpxExtensions() {
    _metadataExtensions.clear();
    _trackExtensions.clear();
    return this;
  }

  /// Builds the immutable [RawActivity].
  ///
  /// When [normalize] is `true` (default) the builder applies sorting and
  /// trimming to match encoder expectations.
  RawActivity build({bool normalize = true}) {
    final activity = RawActivity(
      points: _points.map((point) => point.copyWith()).toList(),
      channels: {
        for (final entry in _channels.entries)
          entry.key: entry.value.map((sample) => sample.copyWith()),
      },
      laps: _laps.map((lap) => lap.copyWith()).toList(),
      sport: sport,
      creator: creator,
      device: device,
      gpxMetadataName: gpxMetadataName,
      gpxMetadataDescription: gpxMetadataDescription,
      gpxIncludeCreatorMetadataDescription:
          gpxIncludeCreatorMetadataDescription,
      gpxTrackName: gpxTrackName,
      gpxTrackDescription: gpxTrackDescription,
      gpxTrackType: gpxTrackType,
      gpxMetadataExtensions: _metadataExtensions.toList(),
      gpxTrackExtensions: _trackExtensions.toList(),
    );
    if (!normalize) {
      return activity;
    }
    return RawEditor(activity).sortAndDedup().trimInvalid().activity;
  }

  /// Resets the builder state.
  void clear() {
    _points.clear();
    _channels.clear();
    _laps.clear();
    sport = Sport.unknown;
    creator = null;
    device = null;
    gpxMetadataName = null;
    gpxMetadataDescription = null;
    gpxIncludeCreatorMetadataDescription = true;
    gpxTrackName = null;
    gpxTrackDescription = null;
    gpxTrackType = null;
    _metadataExtensions.clear();
    _trackExtensions.clear();
  }
}

class _ResolvedSource {
  _ResolvedSource({
    required this.payload,
    required this.description,
    this.fileExtension,
    this.detectionBytes,
  });

  final Object payload;
  final String description;
  final String? fileExtension;
  final Uint8List? detectionBytes;
}
