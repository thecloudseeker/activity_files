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
import 'pipeline_options.dart';

/// Callback used to translate arbitrary identifiers into [Sport] values.
typedef SportMapper = Sport? Function(dynamic source);

const int _defaultStreamBufferLimitBytes = 64 * 1024 * 1024;
const int _maxFormatDetectBytes = 128 * 1024;

/// Top-level facade exposing ergonomic helpers for app integrations.
class ActivityFiles {
  const ActivityFiles._();

  static final List<SportMapper> _sportMappers = <SportMapper>[];

  /// Default maximum payload size (bytes) processed by loaders when handling
  /// inline strings/byte arrays or buffered streams.
  static const int defaultMaxPayloadBytes = _defaultStreamBufferLimitBytes;

  static const String gpxDefaultExtensionNamespace =
      'https://schemas.activityfiles.dev/extensions';
  static const String gpxDefaultExtensionPrefix = 'ext';

  /// Loads [source] into a [RawActivity], attempting to infer the file format.
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
  static Future<ActivityLoadResult> load(
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
        '  1. Provide the format parameter: load(source, format: ActivityFileFormat.gpx)\n'
        '  2. Use a file with a recognized extension (.gpx, .tcx, .fit, .csv, .geojson)\n'
        '  3. If passing a filesystem path as a String, enable: load(source, allowFilePaths: true)\n'
        '\n'
        'Tips for common formats:\n'
        '  • GPX/TCX: Usually detected automatically from file extension\n'
        '  • FIT (binary): For base64-encoded FIT data, use load(bytes, format: ActivityFileFormat.fit)\n'
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
    final payloadForResult = await _materializePayload(resolved.payload);
    return ActivityLoadResult._(
      activity: parseResult.activity,
      diagnostics: parseResult.diagnostics,
      format: detected,
      sourceDescription: resolved.description,
      payload: payloadForResult,
    );
  }

  /// Export an activity to CSV format.
  static String exportToCsv(RawActivity activity) =>
      CsvEncoder.encode(activity);

  /// Export multiple activities to CSV format.
  static String exportToCsvMultiple(List<RawActivity> activities) =>
      CsvEncoder.encodeMultiple(activities);

  /// Import a CSV payload into a [RawActivity].
  static ActivityParseResult importFromCsv(String input) =>
      const CsvParser().parse(input);

  /// Export an activity to GeoJSON FeatureCollection (LineString).
  static String exportToGeojson(RawActivity activity) =>
      GeojsonEncoder.encode(activity);

  /// Export an activity to GeoJSON Point FeatureCollection.
  static String exportToGeojsonPoints(
    RawActivity activity, {
    bool includeChannels = false,
  }) => includeChannels
      ? GeojsonEncoder.encodeAsPointsWithChannels(activity)
      : GeojsonEncoder.encodeAsPoints(activity);

  /// Import a GeoJSON payload into a [RawActivity].
  static ActivityParseResult importFromGeojson(String input) =>
      const GeojsonParser().parse(input);

  /// Converts [source] to [to], optionally inferring the source format.
  ///
  /// The returned [ActivityConversionResult] exposes the normalized activity,
  /// encoder output, and parser diagnostics gathered while loading the source.
  /// When [normalize] is `true` (default) the converter applies
  /// `RawEditor.sortAndDedup()` and `RawEditor.trimInvalid()` prior to encoding.
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
  }) async {
    final loadResult = await load(
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
    var diagnostics = List<ParseDiagnostic>.from(loadResult.diagnostics);
    diagnostics.addAll(repairDiagnostics.map((d) => d.toParseDiagnostic()));
    var exportActivity = normalize
        ? activity
        : _ensureOrderedForExport(activity);
    if (autoFix.isEnabled) {
      final fixed = _autoFixCommonIssues(exportActivity, autoFix);
      diagnostics = [
        ...diagnostics,
        ..._autoFixDiagnostics(exportActivity, fixed),
      ];
      exportActivity = fixed;
    }
    if (!exportInIsolate) {
      diagnostics = [...diagnostics, ..._lossyDiagnostics(exportActivity, to)];
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
        diagnostics = [
          ...diagnostics,
          ..._diagnosticsFromValidation(validation),
        ];
      }
      return ActivityConversionResult._(
        activity: exportActivity,
        sourceFormat: loadResult.format,
        targetFormat: to,
        diagnostics: diagnostics,
        encoderOptions: options,
        encoded: encoded,
        validation: validation,
        processingStats: ActivityProcessingStats(
          normalization: normalizationStats,
          validationDuration: validationDuration,
        ),
      );
    }
    final exportResult = await exportAsync(
      activity: activity,
      to: to,
      options: options,
      normalize: false,
      diagnostics: diagnostics,
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
      diagnostics: exportResult.diagnostics,
      validation: exportResult.validation,
      processingStats: exportResult.processingStats.copyWith(
        normalization: normalizationStats,
      ),
    );
  }

  /// Diagnostics for data an [activity] carries that the [to] format cannot
  /// represent, so target-format loss is reported rather than silent.
  ///
  /// Only *full* drops are reported: features the target encoder writes in some
  /// form (e.g. GPX channel extensions, GeoJSON lap aggregates) are not flagged.
  static List<ParseDiagnostic> _lossyDiagnostics(
    RawActivity activity,
    ActivityFileFormat to,
  ) {
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
    if (to != ActivityFileFormat.gpx && activity.additionalTracks.isNotEmpty) {
      add(
        'multi_track_flattened',
        'Source contains ${activity.additionalTracks.length} additional '
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
    return diagnostics;
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

  /// Returns all channels from [activity] as [ChannelStreamSample] lists,
  /// ready to pass directly to [convertAndExport].
  ///
  /// This removes the per-channel reconstruction glue when re-exporting a
  /// previously imported [RawActivity]. Note that [ChannelStreamSample]
  /// timestamps have whole-second resolution, so sub-second sample timing
  /// (recordings above 1 Hz) is truncated:
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
          (
            timestamp: sample.time.millisecondsSinceEpoch ~/ 1000,
            value: sample.value,
          ),
      ];
    }
    return result;
  }

  /// Imports multiple sources in sequence and returns a [BatchImportResult].
  ///
  /// Each [sources] element is forwarded to [ActivityFiles.load]. If a
  /// source fails, the error is captured in [BatchImportResult.failures] and
  /// processing continues unless [stopOnError] is `true`.
  ///
  /// [onProgress] is called after each source completes, whether or not it
  /// succeeded, with the number of completed items and the total count.
  ///
  /// Example:
  /// ```dart
  /// final result = await ActivityFiles.loadBatch(
  ///   files,
  ///   onProgress: (done, total) => print('$done / $total'),
  /// );
  /// print('Imported ${result.successes.length}, failed ${result.failures.length}');
  /// ```
  static Future<BatchImportResult> loadBatch(
    Iterable<Object> sources, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    void Function(int completed, int total)? onProgress,
    bool stopOnError = false,
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) async {
    final sourceList = sources.toList();
    final total = sourceList.length;
    final successes = <ActivityLoadResult>[];
    final failures = <BatchImportFailure>[];
    var completed = 0;
    for (final source in sourceList) {
      try {
        successes.add(
          await load(
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

  static ({
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
    if (!requested ||
        _isAlreadyNormalized(activity, sortAndDedup, trimInvalid)) {
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
  static bool _isAlreadyNormalized(
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
            p.longitude <= 180,
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
      }
    }
    return true;
  }

  static bool _isStrictlyOrderedActivity(RawActivity activity) =>
      _isStrictlyOrdered(activity.points, (p) => p.time) &&
      activity.channels.values.every(
        (samples) => _isStrictlyOrdered(samples, (s) => s.time),
      ) &&
      _isStrictlyOrdered(activity.laps, (l) => l.startTime);

  static RawActivity _ensureOrderedForExport(RawActivity activity) =>
      _isStrictlyOrderedActivity(activity)
      ? activity
      : RawEditor(activity).sortAndDedup().activity;

  /// Checks if a list is sorted by time with no duplicate timestamps
  /// (each entry strictly after its predecessor).
  static bool _isStrictlyOrdered<T>(
    List<T> items,
    DateTime Function(T) timeOf,
  ) {
    for (var i = 1; i < items.length; i++) {
      if (!timeOf(items[i]).toUtc().isAfter(timeOf(items[i - 1]).toUtc())) {
        return false;
      }
    }
    return true;
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

  /// Merges multiple activities into a single unified activity.
  ///
  /// Combines GPS points, sensor channels, and laps from all activities.
  /// The resulting activity will have:
  /// - All points merged and sorted by timestamp (when [normalize] is true)
  /// - All sensor channel samples combined
  /// - All laps preserved with their original sport values
  /// - Sport from the first activity as the overall sport
  /// - Optional custom [creator] metadata
  ///
  /// Set [preserveSportPerLap] to true to retain each source activity's sport
  /// on its laps, enabling multi-sport merges (e.g., combining separate swim/
  /// bike/run files into a triathlon). When false, lap sports remain as defined
  /// in the source activities.
  ///
  /// Enable [normalize] (default: true) to automatically sort and deduplicate
  /// the merged data.
  ///
  /// Example:
  /// ```dart
  /// final swim = await ActivityFiles.load(File('swim.gpx'));
  /// final bike = await ActivityFiles.load(File('bike.gpx'));
  /// final run = await ActivityFiles.load(File('run.gpx'));
  ///
  /// final triathlon = ActivityFiles.merge(
  ///   [swim.activity, bike.activity, run.activity],
  ///   preserveSportPerLap: true,
  ///   creator: 'my_triathlon_app',
  /// );
  /// ```
  static RawActivity merge(
    List<RawActivity> activities, {
    bool preserveSportPerLap = false,
    bool normalize = true,
    String? creator,
  }) {
    if (activities.isEmpty) {
      throw ArgumentError(
        'Cannot merge activities: the input list is empty.\n'
        '\n'
        'You must provide at least one activity to merge:\n'
        '  final merged = ActivityFiles.merge(activities);\n'
        '\n'
        'To combine multiple activities, ensure the list contains at least one element.\n'
        'To split a multi-sport activity instead, use: ActivityFiles.splitBySport(activity)',
      );
    }
    if (activities.length == 1) {
      return activities.first;
    }

    // Flatten multi-track sources so additional-track data is not dropped.
    final sources = [for (final activity in activities) activity.flattened()];
    final mergedChannels = <Channel, List<Sample>>{};
    for (final activity in sources) {
      for (final entry in activity.channels.entries) {
        mergedChannels
            .putIfAbsent(entry.key, () => <Sample>[])
            .addAll(entry.value);
      }
    }

    final merged = RawActivity(
      points: [for (final activity in sources) ...activity.points],
      channels: mergedChannels,
      laps: [
        // Assign the source activity's sport to laps that lack one so the
        // per-lap sport survives multi-sport merges.
        for (final activity in sources)
          for (final lap in activity.laps)
            preserveSportPerLap && lap.sport == null
                ? lap.copyWith(sport: activity.sport)
                : lap,
      ],
      sets: [for (final activity in sources) ...activity.sets],
      events: [for (final activity in sources) ...activity.events],
      lengths: [for (final activity in sources) ...activity.lengths],
      sport: sources.first.sport,
      creator: creator ?? sources.first.creator,
      device: sources.first.device,
    );
    return normalize ? normalizeActivity(merged) : merged;
  }

  /// Splits a multi-sport activity into separate activities by sport type.
  ///
  /// Each returned activity contains only the points, channels, and laps
  /// that fall within the time range of laps with that sport. Useful for
  /// splitting triathlon files into individual swim/bike/run activities.
  ///
  /// Returns a map from [Sport] to [RawActivity]. Laps without an explicit
  /// sport are grouped under the activity's overall sport.
  ///
  /// Enable [normalize] (default: true) to automatically sort and deduplicate
  /// each split activity's data.
  ///
  /// Example:
  /// ```dart
  /// final triathlon = await ActivityFiles.load(File('triathlon.tcx'));
  /// final splits = ActivityFiles.splitBySport(triathlon.activity);
  ///
  /// // Export each sport separately
  /// for (final entry in splits.entries) {
  ///   final filename = '${entry.key.name}.gpx';
  ///   final export = await ActivityFiles.export(
  ///     activity: entry.value,
  ///     to: ActivityFileFormat.gpx,
  ///   );
  ///   await File(filename).writeAsString(export.asString());
  /// }
  /// ```
  static Map<Sport, RawActivity> splitBySport(
    RawActivity activity, {
    bool normalize = true,
  }) {
    if (activity.laps.isEmpty) {
      // No laps - return entire activity under its overall sport
      return {activity.sport: activity};
    }

    // Group laps by sport
    final lapsBySport = <Sport, List<Lap>>{};
    for (final lap in activity.laps) {
      final sport = lap.sport ?? activity.sport;
      lapsBySport.putIfAbsent(sport, () => []).add(lap);
    }

    if (lapsBySport.length == 1) {
      // Single sport - return as-is
      return {lapsBySport.keys.first: activity};
    }

    // Create separate activities for each sport
    final result = <Sport, RawActivity>{};

    for (final entry in lapsBySport.entries) {
      final sport = entry.key;
      final laps = entry.value;

      // Find time range for this sport's laps
      final startTime = laps
          .map((lap) => lap.startTime)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final endTime = laps
          .map((lap) => lap.endTime)
          .reduce((a, b) => a.isAfter(b) ? a : b);

      // Filter points to this time range
      final sportPoints = activity.points
          .where((p) => !p.time.isBefore(startTime) && !p.time.isAfter(endTime))
          .toList();

      // Filter channels to this time range
      final sportChannels = <Channel, List<Sample>>{};
      for (final channelEntry in activity.channels.entries) {
        final samples = channelEntry.value
            .where(
              (s) => !s.time.isBefore(startTime) && !s.time.isAfter(endTime),
            )
            .toList();
        if (samples.isNotEmpty) {
          sportChannels[channelEntry.key] = samples;
        }
      }

      // Strip sport from laps while preserving all lap metadata.
      final normalizedLaps = [for (final lap in laps) lap.copyWithoutSport()];

      var sportActivity = RawActivity(
        points: sportPoints,
        channels: sportChannels,
        laps: normalizedLaps,
        sport: sport,
        creator: activity.creator,
        device: activity.device,
        gpxMetadataName: activity.gpxMetadataName,
        gpxMetadataDescription: activity.gpxMetadataDescription,
        gpxTrackName: activity.gpxTrackName,
        gpxTrackDescription: activity.gpxTrackDescription,
        gpxTrackType: activity.gpxTrackType,
      );

      if (normalize) {
        sportActivity = normalizeActivity(sportActivity);
      }

      result[sport] = sportActivity;
    }

    return result;
  }

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

  static Sport? _inferSportPrimitive(dynamic source) => switch (source) {
    null => null,
    final Sport sport => sport,
    final String text => _inferSportFromString(text),
    final num value
        when value.toInt() >= 0 && value.toInt() < _sportByNumericId.length =>
      _sportByNumericId[value.toInt()],
    _ => null,
  };

  static final RegExp _sportDelimiter = RegExp(r'[^a-z0-9]+');

  /// Keyword matching order matters: earlier entries win on mixed labels.
  static const Map<Sport, List<String>> _sportKeywords = {
    Sport.running: ['run', 'running', 'jog', 'jogging'],
    Sport.cycling: ['cycle', 'cycling', 'bike', 'biking', 'ride'],
    Sport.swimming: ['swim', 'swimming'],
    Sport.walking: ['walk', 'walking'],
    Sport.hiking: ['hike', 'hiking'],
    Sport.other: ['other'],
  };

  static const List<Sport> _sportByNumericId = [
    Sport.other,
    Sport.running,
    Sport.cycling,
    Sport.swimming,
    Sport.walking,
    Sport.hiking,
  ];

  static Sport? _inferSportFromString(String text) {
    final tokens = text
        .trim()
        .toLowerCase()
        .split(_sportDelimiter)
        .where((token) => token.isNotEmpty)
        .toSet();
    for (final entry in _sportKeywords.entries) {
      if (entry.value.any(tokens.contains)) {
        return entry.key;
      }
    }
    return null;
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
    var repairDiagnostics = const <ValidationDiagnostic>[];
    if (!normalize) {
      working = _ensureOrderedForExport(working);
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
      ..._lossyDiagnostics(working, to),
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
  ///
  /// Set [maxPayloadBytes] to override the default 64MB limit for buffered
  /// streams. Pass `null` to disable the limit.
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
          allowFilePaths: allowFilePaths,
          strictFitIntegrity: strictFitIntegrity,
          fitCorruptionHandling: fitCorruptionHandling,
          autoFix: autoFix,
          maxPayloadBytes: maxPayloadBytes,
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
    if (request.activity != null) {
      var activity = request.activity!;
      var diagnostics = List<ParseDiagnostic>.from(request.diagnostics);
      if (request.autoFix.isEnabled) {
        final fixed = _autoFixCommonIssues(activity, request.autoFix);
        diagnostics = [...diagnostics, ..._autoFixDiagnostics(activity, fixed)];
        activity = fixed;
      }
      if (request.exportInIsolate) {
        return exportAsync(
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
      var parseDiagnostics = List<ParseDiagnostic>.from(
        parseResult.diagnostics,
      );
      if (request.autoFix.isEnabled) {
        final fixed = _autoFixCommonIssues(parsedActivity, request.autoFix);
        parseDiagnostics = [
          ...parseDiagnostics,
          ..._autoFixDiagnostics(parsedActivity, fixed),
        ];
        parsedActivity = fixed;
      }
      final downstreamDiagnostics = <ParseDiagnostic>[
        ...parseDiagnostics,
        ...request.diagnostics,
      ];
      final downstreamRequest = ActivityExportRequest.fromActivity(
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
      final conversion = await convert(
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
      'ActivityExportRequest must specify an activity, source, or stream.',
    );
  }

  /// Attempts to detect the activity format without parsing.
  ///
  /// This helper is useful when you want to branch your own logic based on
  /// format before calling [load] or [convert].
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

  static Future<_ResolvedSource> _resolveSource(
    Object source, {
    required bool allowFilePaths,
  }) async {
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
        payload: _ReplayableStreamPayload(
          replay(),
          bufferLimit: _defaultStreamBufferLimitBytes,
        ),
        description: 'stream',
        detectionBytes: sniffBytes,
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
      if (allowFilePaths && file_system.platformPathExists(source)) {
        final bytes = await file_system.readPlatformPath(source);
        return _ResolvedSource(
          payload: bytes,
          description: source,
          fileExtension: _extensionForPath(source),
        );
      }
      return _ResolvedSource(payload: source, description: 'inline');
    }
    throw ArgumentError(
      'Unsupported source type: ${source.runtimeType}.\n'
      '\n'
      'Supported input types:\n'
      '  • String: inline text content or filesystem path (with allowFilePaths: true)\n'
      '  • File: dart:io File instance\n'
      '  • List<int> or Uint8List: raw binary data\n'
      '  • Stream<List<int>>: chunked/streaming data\n'
      '\n'
      'For filesystem paths passed as String, enable: load(source, allowFilePaths: true)\n'
      '\n'
      'Received: ${source.runtimeType}',
    );
  }

  static ActivityFileFormat? _detectFormat(
    _ResolvedSource resolved, {
    required Encoding encoding,
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) {
    if (maxPayloadBytes != null) {
      _enforcePayloadLimit(
        resolved.detectionBytes ?? resolved.payload,
        encoding: encoding,
        limit: maxPayloadBytes,
      );
    }
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
      List<int> bytes => ActivityParser.parseBytes(
        bytes,
        format,
        encoding: encoding,
      ),
      _ => throw ArgumentError(
        'Unsupported payload type in parser: ${payload.runtimeType}.\n'
        '\n'
        'Expected: String or List<int> (bytes)\n'
        '\n'
        'If using a Stream, parse with parseStream() instead:\n'
        '  ActivityParser.parseStream(stream, format)\n'
        '\n'
        'Received type: ${payload.runtimeType}',
      ),
    };
  }

  static Future<ActivityParseResult> _parseResolved(
    Object payload,
    ActivityFileFormat format, {
    bool useIsolate = true,
    Encoding encoding = utf8,
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) async {
    if (payload is _ReplayableStreamPayload) {
      final bytes = await payload.materialize(maxBytes: maxPayloadBytes);
      return isolate_runner.runWithIsolation(
        () => _parseBytesWithBom(bytes, format, encoding),
        useIsolate: useIsolate,
      );
    }
    if (payload is Stream<List<int>>) {
      return ActivityParser.parseStream(
        payload,
        format,
        useIsolate: useIsolate,
        encoding: encoding,
        maxBytes: maxPayloadBytes,
      );
    }
    if (maxPayloadBytes != null) {
      _enforcePayloadLimit(payload, encoding: encoding, limit: maxPayloadBytes);
    }
    return isolate_runner.runWithIsolation(
      () => _parseSync(payload, format, encoding),
      useIsolate: useIsolate,
    );
  }

  static ActivityParseResult _failedParseResult({
    required ActivityFileFormat format,
    required FormatException error,
  }) {
    final formatName = format.name.toUpperCase();
    final trimmed = error.message.trim();
    final message = trimmed.isEmpty ? error.toString() : trimmed;
    return ActivityParseResult(
      activity: RawActivity(),
      diagnostics: <ParseDiagnostic>[
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'parser.format_exception',
          message:
              'Failed to parse $formatName payload: $message. Hint: For GPX/TCX/CSV/GeoJSON, ensure the text encoding matches the file (`encoding` parameter). For FIT, pass raw bytes via `parseBytes`/`load(File)` instead of base64 text and check integrity. If the input is ambiguous, provide `format` explicitly.',
          node: ParseNodeReference(path: '${format.name}.document'),
        ),
      ],
    );
  }

  static Future<Object> _materializePayload(Object payload) async {
    if (payload is _ReplayableStreamPayload) {
      try {
        return await payload.materialize(
          maxBytes: _defaultStreamBufferLimitBytes,
        );
      } catch (_) {
        return Uint8List(0);
      }
    }
    return payload;
  }

  static ActivityFileFormat? _detectFormatSync(
    Object source, {
    required Encoding encoding,
    required bool allowFilePaths,
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) {
    if (source is _ResolvedSource) {
      if (maxPayloadBytes != null) {
        _enforcePayloadLimit(
          source.detectionBytes ?? source.payload,
          encoding: encoding,
          limit: maxPayloadBytes,
        );
      }
      return _detectFormat(
        source,
        encoding: encoding,
        maxPayloadBytes: maxPayloadBytes,
      );
    }
    if (maxPayloadBytes != null) {
      _enforcePayloadLimit(source, encoding: encoding, limit: maxPayloadBytes);
    }
    final filePath = file_system.platformFilePath(source);
    if (filePath != null) {
      return _detectFromExtension(_extensionForPath(filePath));
    }
    if (source is String) {
      if (allowFilePaths && file_system.platformPathExists(source)) {
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

  static const Map<String, ActivityFileFormat> _formatByExtension = {
    '.gpx': ActivityFileFormat.gpx,
    '.tcx': ActivityFileFormat.tcx,
    '.fit': ActivityFileFormat.fit,
    '.csv': ActivityFileFormat.csv,
    '.geojson': ActivityFileFormat.geojson,
    '.json': ActivityFileFormat.geojson,
  };

  static ActivityFileFormat? _detectFromExtension(String? ext) =>
      _formatByExtension[ext];

  static ActivityFileFormat? _detectFromPayload(
    Object payload, {
    required Encoding encoding,
  }) {
    if (payload is String) {
      final sniffed = _sniffTextForDetection(payload);
      return _detectFromText(sniffed.text, allowPartial: sniffed.truncated);
    }
    final sniffed = _sniffBytesForDetection(payload);
    final bytes = sniffed.bytes;
    final bomDecoder = _decoderForBom(bytes);
    if (bomDecoder != null) {
      final decoded = bomDecoder(bytes);
      final detectedFromBom = _detectFromText(
        decoded,
        allowPartial: sniffed.truncated,
      );
      if (detectedFromBom != null) {
        return detectedFromBom;
      }
    }
    if (_looksBinary(bytes)) {
      return ActivityFileFormat.fit;
    }
    try {
      return _detectFromText(
        encoding.decode(bytes),
        allowPartial: sniffed.truncated,
      );
    } on FormatException {
      final fallback = utf8.decode(bytes, allowMalformed: true);
      return _detectFromText(fallback, allowPartial: sniffed.truncated);
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

  static bool _looksBase64(String text, {bool allowPartial = false}) {
    final trimmed = text.replaceAll(RegExp(r'\s+'), '');
    if (trimmed.isEmpty) {
      return false;
    }
    if (!allowPartial && trimmed.length % 4 != 0) {
      return false;
    }
    final matchesAlphabet = RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(trimmed);
    if (!matchesAlphabet) {
      return false;
    }
    if (allowPartial) {
      return trimmed.length >= 8;
    }
    return true;
  }

  static ActivityFileFormat? _detectFromText(
    String text, {
    bool allowPartial = false,
  }) {
    final trimmed = text.trimLeft();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final lower = trimmed.toLowerCase();
      if (lower.contains('"type"') &&
          (lower.contains('"featurecollection"') ||
              lower.contains('"feature"') ||
              lower.contains('"linestring"') ||
              lower.contains('"point"') ||
              lower.contains('"multilinestring"'))) {
        return ActivityFileFormat.geojson;
      }
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
    if (_looksCsv(trimmed, allowPartial: allowPartial)) {
      return ActivityFileFormat.csv;
    }
    if (_looksBase64(trimmed, allowPartial: allowPartial)) {
      return ActivityFileFormat.fit;
    }
    return null;
  }

  static bool _looksCsv(String text, {bool allowPartial = false}) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(3)
        .toList(growable: false);
    if (lines.isEmpty) {
      return false;
    }
    final header = lines.first.toLowerCase();
    if (!(header.contains('timestamp') &&
        header.contains('latitude') &&
        header.contains('longitude'))) {
      return false;
    }
    if (allowPartial) {
      return header.contains(',');
    }
    if (lines.length < 2) {
      return false;
    }
    return lines.first.contains(',') && lines[1].contains(',');
  }

  static ({String text, bool truncated}) _sniffTextForDetection(
    String text, {
    int maxChars = _maxFormatDetectBytes,
  }) {
    if (text.length <= maxChars) {
      return (text: text, truncated: false);
    }
    return (text: text.substring(0, maxChars), truncated: true);
  }

  static ({Uint8List bytes, bool truncated}) _sniffBytesForDetection(
    Object payload, {
    int maxBytes = _maxFormatDetectBytes,
  }) {
    if (payload is Uint8List) {
      if (payload.length <= maxBytes) {
        return (bytes: payload, truncated: false);
      }
      return (
        bytes: Uint8List.sublistView(payload, 0, maxBytes),
        truncated: true,
      );
    }
    final list = payload as List<int>;
    if (list.length <= maxBytes) {
      return (bytes: Uint8List.fromList(list), truncated: false);
    }
    return (
      bytes: Uint8List.fromList(list.take(maxBytes).toList()),
      truncated: true,
    );
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

  static int _totalSamples(RawActivity activity) => activity.channels.values
      .fold(0, (total, samples) => total + samples.length);

  static bool _shouldFailFitIntegrity(
    ActivityFileFormat format,
    Iterable<ParseDiagnostic> diagnostics,
    bool strict,
  ) =>
      strict &&
      format == ActivityFileFormat.fit &&
      diagnostics.any(
        (d) =>
            d.severity == ParseSeverity.error &&
            (d.code.startsWith('fit.header') ||
                d.code.startsWith('fit.trailer')),
      );

  static bool _resolveStrictFitHandling({
    required bool strictFitIntegrity,
    required FitCorruptionHandling fitCorruptionHandling,
  }) =>
      strictFitIntegrity ||
      fitCorruptionHandling == FitCorruptionHandling.strict;

  static RawActivity _autoFixCommonIssues(
    RawActivity activity,
    ActivityAutoFixOptions options,
  ) {
    var editor = RawEditor(activity).sortAndDedup();
    if (options.fixInvalidGps || options.fixChannelDrift) {
      editor = editor.trimInvalid();
    }
    if (options.fixDistanceDrift) {
      editor = editor.recomputeDistanceAndSpeed();
    }
    var fixed = editor.activity;
    if (options.fixTimestampGaps && options.maxInsertedGapPoints > 0) {
      fixed = _fillTimestampGaps(
        fixed,
        options.gapThreshold,
        maxInsertedPoints: options.maxInsertedGapPoints,
      );
    }
    if (options.autoLapByDistance) {
      // Generate auto-laps if:
      // 1. autoLapOnlyWhenMissing is false (always generate), OR
      // 2. autoLapOnlyWhenMissing is true AND laps are missing/placeholder

      final hasPlaceholderLaps =
          fixed.laps.isNotEmpty &&
          fixed.laps.every(
            (lap) =>
                (lap.name?.startsWith('Segment') ?? false) ||
                (lap.name?.startsWith('Split') ?? false),
          );

      final shouldGenerateLaps =
          !options.autoLapOnlyWhenMissing ||
          fixed.laps.isEmpty ||
          hasPlaceholderLaps;

      if (shouldGenerateLaps && fixed.points.length >= 2) {
        // Always recompute distance for auto-lap to ensure accuracy
        // (distance may be lost during format conversions like GPX->TCX roundtrip)
        var lapSource = RawEditor(fixed).recomputeDistanceAndSpeed().activity;
        final splitMeters = _autoLapDistanceForSport(lapSource.sport, options);
        if (splitMeters > 0) {
          fixed = RawEditor(lapSource).markLapsByDistance(splitMeters).activity;
        }
      }
    }
    return fixed;
  }

  static double _autoLapDistanceForSport(
    Sport sport,
    ActivityAutoFixOptions options,
  ) {
    final override = options.autoLapDistanceMeters;
    if (override != null && override > 0) {
      return override;
    }
    switch (sport) {
      case Sport.running:
      case Sport.walking:
      case Sport.hiking:
        return options.runningLapDistanceMeters;
      case Sport.cycling:
        return options.cyclingLapDistanceMeters;
      default:
        return options.defaultLapDistanceMeters;
    }
  }

  static List<ParseDiagnostic> _autoFixDiagnostics(
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
          message:
              'Auto-fix removed $removedPoints invalid/out-of-range points.',
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
          message:
              'Auto-fix recomputed distance/speed channels from GPS points.',
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

  // Fills large timestamp gaps by linearly interpolating position and elevation.
  // Channel samples (HR, power, cadence, etc.) are intentionally not interpolated;
  // inserted points carry no sensor data and will appear as gaps in channel coverage.
  static RawActivity _fillTimestampGaps(
    RawActivity activity,
    Duration threshold, {
    required int maxInsertedPoints,
  }) {
    if (activity.points.length < 2 || threshold <= Duration.zero) {
      return activity;
    }
    final output = <GeoPoint>[];
    var inserted = 0;
    for (var i = 0; i < activity.points.length - 1; i++) {
      final current = activity.points[i];
      final next = activity.points[i + 1];
      output.add(current);
      final gap = next.time.difference(current.time);
      if (gap <= threshold || inserted >= maxInsertedPoints) {
        continue;
      }
      final thresholdMicros = threshold.inMicroseconds;
      if (thresholdMicros <= 0) {
        continue;
      }
      final steps = gap.inMicroseconds ~/ thresholdMicros;
      if (steps <= 1) {
        continue;
      }
      for (var j = 1; j < steps; j++) {
        if (inserted >= maxInsertedPoints) {
          break;
        }
        final ratio = j / steps;
        final time = current.time.add(
          Duration(microseconds: (gap.inMicroseconds * ratio).round()),
        );
        final elevation = current.elevation != null && next.elevation != null
            ? current.elevation! +
                  (next.elevation! - current.elevation!) * ratio
            : null;
        output.add(
          GeoPoint(
            latitude:
                current.latitude + (next.latitude - current.latitude) * ratio,
            longitude:
                current.longitude +
                (next.longitude - current.longitude) * ratio,
            elevation: elevation,
            time: time,
          ),
        );
        inserted++;
      }
    }
    output.add(activity.points.last);
    if (output.length == activity.points.length) {
      return activity;
    }
    return activity.copyWith(points: output);
  }

  static FormatException _fitIntegrityFailure(
    Iterable<ParseDiagnostic> diagnostics,
  ) {
    final diagnosticInfo = diagnostics.isEmpty
        ? ''
        : '\nDiagnostics: ${diagnostics.map((d) => "${d.code} (${d.severity.name})").join(", ")}\n';
    return FormatException(
      'FIT integrity check failed. The file may be corrupted or incomplete.$diagnosticInfo'
      '\n'
      'Troubleshooting steps:\n'
      '  1. Verify the file is complete (not truncated during transfer)\n'
      '  2. Check that header/trailer CRCs are valid using FIT tools\n'
      '  3. Try loading with strictFitIntegrity: false to recover partial data\n'
      '  4. If the file was downloaded/transferred, retry the transfer\n'
      '\n'
      'If you need to proceed despite errors, use strictFitIntegrity: false.',
    );
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

  /// Parsed activity.
  ///
  /// Parse or validation failures never throw; they are recorded in
  /// [diagnostics]. Inspect [hasErrors], [diagnostics], or
  /// [diagnosticsSummary] before trusting [activity].
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

class _ReplayableStreamPayload extends Stream<List<int>> {
  _ReplayableStreamPayload(Stream<List<int>> source, {this.bufferLimit})
    : _source = source;

  final Stream<List<int>> _source;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final Completer<void> _completed = Completer<void>();
  final int? bufferLimit;
  Uint8List? _bytes;
  int _bufferedBytes = 0;
  bool _listened = false;
  Object? _error;
  StackTrace? _errorStack;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listened) {
      throw StateError('Stream payloads can only be listened to once.');
    }
    _listened = true;
    return _source.listen(
      (chunk) {
        if (_completed.isCompleted) {
          return;
        }
        try {
          if (chunk.isNotEmpty) {
            _addChunk(chunk, limit: bufferLimit);
          }
          onData?.call(chunk);
        } catch (error, stackTrace) {
          _finalize(error: error, stackTrace: stackTrace);
          if (onError == null) {
            Zone.current.handleUncaughtError(error, stackTrace);
          } else if (onError is void Function(Object, StackTrace)) {
            onError(error, stackTrace);
          } else {
            (onError as void Function(Object))(error);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _finalize(error: error, stackTrace: stackTrace);
        if (onError == null) {
          Zone.current.handleUncaughtError(error, stackTrace);
        } else if (onError is void Function(Object, StackTrace)) {
          onError(error, stackTrace);
        } else {
          (onError as void Function(Object))(error);
        }
      },
      onDone: () {
        _finalize();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
  }

  Future<Uint8List> materialize({int? maxBytes}) async {
    if (!_listened) {
      _listened = true;
      try {
        await for (final chunk in _source) {
          _addChunk(chunk, limit: maxBytes);
        }
        _finalize();
      } catch (error, stackTrace) {
        _finalize(error: error, stackTrace: stackTrace);
        Error.throwWithStackTrace(error, stackTrace);
      }
    } else if (!_completed.isCompleted) {
      await _completed.future;
    }
    if (_error != null) {
      Error.throwWithStackTrace(_error!, _errorStack ?? StackTrace.current);
    }
    final bytes = _bytes ?? _buffer.takeBytes();
    if (maxBytes != null && bytes.length > maxBytes) {
      throw FormatException(
        'Stream payload exceeds $maxBytes bytes. Hint: prefer streamed workflows (`ActivityParser.parseStream`, `convertAndExportStream`) or raise `maxPayloadBytes` for `load`/`convert`/`export`.',
      );
    }
    return bytes;
  }

  void _addChunk(List<int> chunk, {int? limit}) {
    final threshold = limit ?? bufferLimit;
    if (threshold != null && _bufferedBytes + chunk.length > threshold) {
      throw FormatException(
        'Stream payload exceeds $threshold bytes. Hint: increase buffer limit via `maxPayloadBytes` or switch to processing pipelines that don’t require full buffering.',
      );
    }
    _buffer.add(chunk);
    _bufferedBytes += chunk.length;
  }

  void _finalize({Object? error, StackTrace? stackTrace}) {
    if (_completed.isCompleted) {
      return;
    }
    _bytes ??= _buffer.takeBytes();
    if (error != null) {
      _error = error;
      _errorStack = stackTrace;
      _completed.completeError(error, stackTrace);
    } else {
      _completed.complete();
    }
  }
}

void _enforcePayloadLimit(
  Object payload, {
  required Encoding encoding,
  required int limit,
}) {
  int sizeBytes;
  if (payload is Uint8List) {
    sizeBytes = payload.length;
  } else if (payload is List<int>) {
    sizeBytes = payload.length;
  } else if (payload is String) {
    sizeBytes = encoding.encode(payload).length;
  } else {
    return;
  }
  if (sizeBytes > limit) {
    throw FormatException(
      'Payload exceeds $limit bytes. Hint: use streaming APIs (`ActivityParser.parseStream`, `convertAndExportStream`) or increase `maxPayloadBytes` on `load`/`convert`/`export`. Pass `null` to disable the limit if you fully trust the input size.',
    );
  }
}

/// Result of [ActivityFiles.loadBatch].
class BatchImportResult {
  BatchImportResult({
    required this.successes,
    required this.failures,
    required this.total,
  });

  /// Successfully loaded activities, in input order (skipping failed items).
  final List<ActivityLoadResult> successes;

  /// Sources that could not be loaded, in the order failures occurred.
  final List<BatchImportFailure> failures;

  /// Total number of sources that were attempted.
  final int total;

  /// Number of successfully loaded activities.
  int get successCount => successes.length;

  /// Number of sources that failed to load.
  int get failureCount => failures.length;

  /// Whether all sources were loaded without errors.
  bool get allSucceeded => failures.isEmpty;
}

/// A single failure entry from [ActivityFiles.loadBatch].
class BatchImportFailure {
  BatchImportFailure({
    required this.source,
    required this.error,
    this.stackTrace,
  });

  /// The source that failed (e.g. a [File] or [Uint8List]).
  final Object source;

  /// The error that was thrown.
  final Object error;

  /// Stack trace from the thrown error, if available.
  final StackTrace? stackTrace;

  @override
  String toString() => 'BatchImportFailure(source: $source, error: $error)';
}
