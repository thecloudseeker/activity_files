# activity_files usage guide

## Getting started

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  activity_files: ^0.5.1
```

Then install dependencies:

```shell
dart pub get
```

See `example/main.dart` for a minimal round-trip through the encoders.

## Quick start

### Flutter app (mobile & web)

Bundle your sample data alongside the app so it is available on every platform:

```yaml
flutter:
  assets:
    - assets/ride.gpx
```

Load the asset via `rootBundle`, wire the isolate toggle for web, and expose helpers your widgets can call:

```dart
import 'dart:typed_data';
import 'package:activity_files/activity_files.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ActivityRepository {
  Future<ActivityLoadResult> loadRideFromAssets() async {
    final asset = await rootBundle.load('assets/ride.gpx');
    final bytes = asset.buffer.asUint8List();
    return ActivityFiles.load(
      bytes,
      format: ActivityFileFormat.gpx,
      useIsolate: !kIsWeb,
    );
  }

  Future<ActivityExportResult> convertToFit(Uint8List gpxBytes) {
    return ActivityFiles.convertAndExport(
      source: gpxBytes,
      from: ActivityFileFormat.gpx,
      to: ActivityFileFormat.fit,
      runValidation: true,
      useIsolate: !kIsWeb,
      exportInIsolate: !kIsWeb,
    );
  }

  Future<ActivityExportResult> buildSyntheticRun() async {
    final builder = ActivityFiles.builder()
      ..sport = Sport.running
      ..setDeviceMetadata(
        const ActivityDeviceMetadata(
          manufacturer: 'Example Watch',
          fitManufacturerId: 201,
          fitProductId: 42,
        ),
      )
      ..addPoint(
        latitude: 40.0,
        longitude: -105.0,
        time: DateTime.utc(2024, 5, 1, 7, 30),
      )
      ..addSample(
        channel: Channel.heartRate,
        time: DateTime.utc(2024, 5, 1, 7, 30),
        value: 142,
      );
    final activity = builder.build();
    return ActivityFiles.export(
      activity: activity,
      to: ActivityFileFormat.gpx,
    );
  }
}
```

Drop the repository into a widget so newcomers can see the end-to-end flow:

```dart
class RidePreview extends StatelessWidget {
  const RidePreview({super.key, required this.repository});

  final ActivityRepository repository;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ActivityLoadResult>(
      future: repository.loadRideFromAssets(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const CircularProgressIndicator();
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Text('Failed to load: ${snapshot.error}');
        }
        final ride = snapshot.data!;
        return Text(
          'Format: ${ride.format.name}, points: ${ride.activity.points.length}',
        );
      },
    );
  }
}
```

> Web note: When targeting Flutter web, use `useIsolate: false` (and `exportInIsolate: false`). The snippets above gate those flags with `!kIsWeb` for convenience.

### Raw streams

Backends that expose timestamp/value arrays can skip manual `GeoPoint` and `Sample` assembly by using the stream-aware helpers:

```dart
final device = ActivityDeviceMetadata(
  manufacturer: 'Withings',
  model: 'ScanWatch',
);

final export = await ActivityFiles.convertAndExport(
  location: locationStream,
  channels: {
    Channel.heartRate: heartRateStream,
    Channel.temperature: temperatureStream,
  },
  laps: lapStream,
  label: 'Morning Run',
  creator: 'withings-exporter',
  sportSource: withingsCategory,
  device: device,
  gpxMetadataDescription: 'Withings export',
  includeCreatorInGpxMetadataDescription: false,
  metadataExtensions: [
    ActivityFiles.gpxActivityLabelNode('Morning Run'),
  ],
  trackExtensions: [
    ActivityFiles.gpxDeviceSummaryNode(
      device,
      extras: {'battery': 95},
    ),
  ],
  to: ActivityFileFormat.gpx,
  normalize: true,
  runValidation: true,
);
```

Each stream uses records (`({timestamp, latitude, longitude, elevation})` and `({timestamp, value})`), making it trivial to forward arrays from REST or gRPC payloads. When wearable categories differ from the built-in `Sport` enum, call `ActivityFiles.registerSportMapper` once during startup to plug in your own mapping strategy.

### FIT session/lap stats

When parsing FIT files, session summary values (distance, time, avg/max metrics) are surfaced on `RawActivity.summary`, and lap stats are populated on each `Lap` when available:

```dart
final result = await ActivityFiles.load(fitBytes, format: ActivityFileFormat.fit);
final summary = result.activity.summary;
print('Distance: ${summary?.totalDistanceMeters}');
print('Avg HR: ${summary?.avgHeartRate}');

for (final lap in result.activity.laps) {
  print('Lap ${lap.name}: ${lap.distanceMeters}m, avg HR ${lap.avgHeartRate}');
}
```

## Dart VM / CLI

If you are running on the Dart VM (CLI tools, servers, tests), you can keep using `dart:io` to read from disk. Pass `File` instances directly (preferred) or set `allowFilePaths: true` when a plain string should be treated as a path:

```dart
import 'dart:io';
import 'package:activity_files/activity_files.dart';

Future<void> bootstrap() async {
  final ride = await ActivityFiles.load(
    File('assets/ride.gpx'),
    useIsolate: true,
  );
  print('Detected format: ${ride.format}, points: ${ride.activity.points.length}');

  final fit = await ActivityFiles.convertAndExport(
    source: File('assets/ride.gpx'),
    to: ActivityFileFormat.fit,
    runValidation: true,
    exportInIsolate: true,
  );
  await File('ride.fit').writeAsBytes(fit.asBytes());
}
```

> Security note: String sources are treated as inline payloads by default. Only set `allowFilePaths: true` (available on `load`, `convert`, `convertAndExport`, and `ActivityExportRequest.fromSource`) when you explicitly trust and expect a filesystem path.

## Error handling

`ActivityFiles.load`, `convert`, and export helpers surface parser/validation issues via diagnostics rather than throwing. Always gate on `hasErrors` (or inspect the diagnostics list) before trusting the returned activity:

```dart
final result = await ActivityFiles.load(sourceBytes, useIsolate: false);
if (result.hasErrors) {
  log('Load failed:\n${result.diagnosticsSummary()}');
  return;
}
final normalized = ActivityFiles.normalizeActivity(result.activity);
```

The same pattern applies to conversion/export results:

```dart
final export = await ActivityFiles.convertAndExport(
  source: someFile,
  to: ActivityFileFormat.fit,
  runValidation: true,
);
if (export.hasErrors) {
  report(export.diagnostics);
} else {
  upload(export.asBytes());
}
```

> Streaming note: `parseStream` / streamed conversion helpers return
> diagnostics for malformed or oversized payloads instead of throwing. Check
> `hasErrors` on the result to surface failures gracefully.

> FIT integrity: Header/trailer CRC mismatches and truncated FIT payloads are
> surfaced as error diagnostics. Parsing continues and may yield usable points;
> the parser also filters corrupt data points (for example timestamps outside
> 1989–2050, invalid coordinates, or points that are more than 24 hours apart
> or 100 km from neighbors) and emits warning diagnostics when it removes
> them. Decide to accept with warnings or reject.

> Strict mode: Pass `strictFitIntegrity: true` to `ActivityFiles.load` /
> `convert` / streamed export helpers when you want FIT integrity errors to
> throw `FormatException` instead of returning diagnostics.

## Resilience (kurz)

- **FIT Korruption**: CRC/trailer Fehler → `fit.header.crc_mismatch`,
  `fit.trailer.crc_mismatch`, `fit.trailer.truncated`; Parser liest, was geht.
  Unknown definitions → `fit.definition.missing`; compressed header ohne
  timestamp → `fit.compressed_header.missing_timestamp` (Warnung).
- **Strict reject**: `strictFitIntegrity: true` setzen.
- **Tolerant**:

  ```dart
  final r = await ActivityFiles.load(fitBytes);
  final hasCrc = r.diagnostics.any((d) => d.code.contains('crc') || d.code.contains('truncated'));
  if (hasCrc && r.activity.points.isNotEmpty) {
    // akzeptieren, aber flaggen
  }
  ```

- **GPX/TCX malformed**: `gpx.parse.malformed` / `tcx.parse.malformed`; keine Daten → ablehnen.
- **Bad GPS/Sensor-Daten**: `normalizeActivity(... trimInvalid: true, sortAndDedup: true, recomputeDistanceAndSpeed: true)`; Channels clampen via `trimInvalid(... channelsBoundToPoints: true)`.
- **Laps prüfen**:

  ```dart
  final laps = RawEditor(activity).validateLapBoundaries();
  if (laps.hasIssues) log(laps.errors);
  ```

- **Encoding**: Legacy GPX/TCX mit `encoding: latin1` laden.
- **Telemetry**: Diagnostic-Codes zählen (z.B. `fit.trailer.crc_mismatch`, `gpx.parse.malformed`).

## Payload limits

- Inline strings/byte arrays and buffered streams are capped at 64MB
  (`ActivityFiles.defaultMaxPayloadBytes`) by default. Larger inputs throw
  `FormatException` and the CLI rejects them to prevent unbounded buffering.
- To override the limit, pass `maxPayloadBytes` to `load()`, `convert()`,
  `convertAndExport()`, `convertAndExportStream()`, or `detectFormat()`. Pass
  `null` to disable the limit entirely.
- For very large files, stream from disk/network in smaller chunks, split the
  source before parsing/exporting, or set `maxPayloadBytes: null` if you trust
  the input.

## Format handling

- GPX parsing merges all tracks and segments into one unified activity stream.
- TCX parsing reads the first `<Activity>` element.

For files with multiple activities, split them before parsing or extend the parsers for your specific needs.

## Async export & streaming

> Web note: When targeting Flutter web, use `useIsolate: false` and `exportInIsolate: false`.

```dart
Future<void> exportOffMainThread(
  RawActivity activity, {
  bool supportsIsolates = true,
}) async {
  final result = await ActivityFiles.exportAsync(
    activity: activity,
    to: ActivityFileFormat.fit,
    runValidation: true,
    useIsolate: supportsIsolates,
  );
  print('Normalization Δ: ${result.processingStats.normalization?.pointsDelta}');
  print('Validation took: ${result.processingStats.validationDuration}');
}

Future<void> convertStreamedGpx(Stream<List<int>> stream) async {
  final request = ActivityExportRequest.fromStream(
    stream: stream,
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.tcx,
    runValidation: true,
  );
  final result = await ActivityFiles.runPipeline(request);
  await File('streamed.tcx').writeAsString(result.asString());
}

Future<void> pipelineFromPath(String path) async {
  final result = await ActivityFiles.runPipeline(
    ActivityExportRequest.fromSource(
      source: File(path),
      from: null, // auto-detects GPX/TCX/FIT
      to: ActivityFileFormat.fit,
      runValidation: true,
      exportInIsolate: true,
    ),
  );
  await File('converted.fit').writeAsBytes(result.asBytes());
}
```

> Streaming caveat: the current `parseStream` implementation buffers the entire stream in memory before parsing so it can rewind when needed. This keeps the API consistent across platforms today but means very large uploads still need enough RAM for the full payload. If you need true incremental parsing you can feed the parser with your own chunked loader that enforces back-pressure and chunk sizes.

## Performance tips

- Prefer enabling `normalize: true` (the default) when exporting or converting.
  Sorting, deduplication, and invalid point trimming significantly reduce the
  work downstream encoders perform and ensure channel cursors align quickly.
- When exporting on the UI thread, set `useIsolate` / `exportInIsolate` to
  `false` on Flutter web (isolate support is missing) and `true` elsewhere so
  parsing and encoding happen off the main isolate.
- `EncoderOptions.defaultMaxDelta` controls the tolerance between trajectory
  points and sensor samples; tune it per device cadence and override specific
  channels via `maxDeltaPerChannel`.
- Resampling multi-hour recordings with `RawTransforms.resample` is CPU-heavy
  because it performs interpolation across every point. Only invoke it when
  downstream consumers require fixed time steps (and consider isolate offload).
- `RawEditor.downsampleTime` / `downsampleDistance` / `smoothHR` are linear
  passes and operate on copies of the activity. Avoid redundant passes to keep
  memory churn low.
- Channel cursors (`ChannelMapper.cursor`) cache per-channel indices. Reuse a
  single cursor instance when streaming exports so lookups stay near O(1).

## RawActivity model

```dart
final activity = RawActivity(
  points: [
    GeoPoint(latitude: 40.0, longitude: -105.0, elevation: 1601, time: DateTime.utc(2024, 3, 1, 10)),
    GeoPoint(latitude: 40.0005, longitude: -105.0005, elevation: 1602, time: DateTime.utc(2024, 3, 1, 10, 0, 10)),
  ],
  channels: {
    Channel.heartRate: [
      Sample(time: DateTime.utc(2024, 3, 1, 10), value: 140),
      Sample(time: DateTime.utc(2024, 3, 1, 10, 0, 10), value: 142),
    ],
  },
  laps: [
    Lap(
      startTime: DateTime.utc(2024, 3, 1, 10),
      endTime: DateTime.utc(2024, 3, 1, 10, 0, 10),
      distanceMeters: 70,
    ),
  ],
  sport: Sport.running,
  creator: 'activity_files',
  device: const ActivityDeviceMetadata(
    manufacturer: 'Example Watch',
    model: 'Forerunner 965',
    product: 'Forerunner',
    serialNumber: 'ABC123',
  ),
  gpxMetadataName: 'Morning Run',
  gpxMetadataDescription: 'Workout pulled from Example Watch',
  gpxIncludeCreatorMetadataDescription: false,
  gpxTrackName: 'Morning Run',
  gpxTrackDescription: 'Uphill repeats',
  gpxTrackType: 'Run',
  gpxMetadataExtensions: [
    ActivityFiles.gpxActivityLabelNode('Morning Run'),
  ],
  gpxTrackExtensions: [
    ActivityFiles.gpxDeviceSummaryNode(
      const ActivityDeviceMetadata(
        manufacturer: 'Example Watch',
        model: 'Forerunner 965',
      ),
      extras: {'battery': 98},
    ),
  ],
);

final channelMapper = ChannelMapper.cursor(activity.channels);
final snapshot = channelMapper.snapshot(activity.points.first.time);
print('HR: ${snapshot.heartRate}, cadence: ${snapshot.cadence}');

final builder = ActivityFiles.builder(activity)
  ..smoothHR(5)
  ..trimInvalid()
  ..sortAndDedup();
final normalized = builder.build();
```

> Tip: Use `ActivityFiles.builderFromStreams` or `ActivityFiles.convertAndExport`
> when you have raw timestamp/value tuples from the backend. They accept
> `({timestamp, latitude, longitude, elevation})` and `({timestamp, value})`
> records so pipelines can avoid manually instantiating `GeoPoint` / `Sample`
> data.

### Multi-sport activities (triathlons)

`activity_files` supports multi-sport activities like triathlons where different segments have different sports. The `Lap` class includes an optional `sport` field that allows each lap to specify its own sport type:

```dart
final triathlon = RawActivity(
  points: [/* GPS points */],
  laps: [
    Lap(
      startTime: DateTime.utc(2024, 7, 21, 6, 0),
      endTime: DateTime.utc(2024, 7, 21, 6, 20),
      distanceMeters: 750,
      sport: Sport.swimming,  // Swim leg
    ),
    Lap(
      startTime: DateTime.utc(2024, 7, 21, 6, 25),
      endTime: DateTime.utc(2024, 7, 21, 7, 25),
      distanceMeters: 40000,
      sport: Sport.cycling,  // Bike leg
    ),
    Lap(
      startTime: DateTime.utc(2024, 7, 21, 7, 30),
      endTime: DateTime.utc(2024, 7, 21, 8, 0),
      distanceMeters: 5000,
      sport: Sport.running,  // Run leg
    ),
  ],
  sport: Sport.swimming,  // Overall activity sport (first segment)
);
```

When parsing TCX files with multiple `<Activity>` elements or FIT files with multiple sessions, the parser automatically:
- Merges all segments into a single `RawActivity`
- Assigns the appropriate sport to each lap based on its parent activity/session
- Emits an info-level diagnostic (`tcx.multi_activity` or `fit.multi_session`) indicating the number of sport segments detected

Laps without an explicit `sport` value inherit from the activity's overall sport.

### Merging and splitting activities

`ActivityFiles` provides convenience methods for combining separate activities or splitting multi-sport files:

```dart
// Merge separate swim/bike/run files into a triathlon
final swim = await ActivityFiles.load(File('swim.gpx'));
final bike = await ActivityFiles.load(File('bike.fit'));
final run = await ActivityFiles.load(File('run.tcx'));

final triathlon = ActivityFiles.merge(
  [swim.activity, bike.activity, run.activity],
  preserveSportPerLap: true,  // Assigns each source's sport to its laps
);

// Export as a single multi-sport file
await ActivityFiles.export(
  activity: triathlon,
  to: ActivityFileFormat.tcx,
);

// Split a triathlon file into separate sport-specific files
final parsed = await ActivityFiles.load(File('triathlon.tcx'));
final splits = ActivityFiles.splitBySport(parsed.activity);

// Each split contains only points/channels/laps for that sport
final swimActivity = splits[Sport.swimming]!;
final bikeActivity = splits[Sport.cycling]!;
final runActivity = splits[Sport.running]!;

// Export each segment separately
await ActivityFiles.export(activity: swimActivity, to: ActivityFileFormat.gpx);
await ActivityFiles.export(activity: bikeActivity, to: ActivityFileFormat.gpx);
await ActivityFiles.export(activity: runActivity, to: ActivityFileFormat.gpx);
```

`merge()` combines GPS points, sensor channels, and laps from all activities. Set `preserveSportPerLap: true` to create multi-sport activities where each lap retains its source activity's sport.

`splitBySport()` divides activities by lap sport assignments, filtering points and channels to each sport's time range. Each resulting activity contains only data from laps with that sport type.

## Parsing + encoding

```dart
// Parse GPX to RawActivity (plus non-fatal diagnostics).
final result = ActivityParser.parse(gpxString, ActivityFileFormat.gpx);
for (final warning in result.warningDiagnostics) {
  final node = warning.node?.format();
  final context = node != null ? ' @ $node' : '';
  print('Warning ${warning.code}$context: ${warning.message}');
}
final formatter = DiagnosticsFormatter(result.diagnostics);
print('Warnings: ${formatter.warningCount}, errors: ${formatter.errorCount}');
print(formatter.summary(includeNode: true));
final activity = result.activity;

// Encode back to TCX with custom tolerances & precision.
final options = EncoderOptions(
  defaultMaxDelta: const Duration(seconds: 2),
  precisionLatLon: 6,
  precisionEle: 1,
  gpxVersion: GpxVersion.v1_0, // emit GPX 1.0 when needed for legacy consumers
  tcxVersion: TcxVersion.v1, // emit TCX v1 when older TrainingCenter parsers need it
  maxDeltaPerChannel: {
    Channel.heartRate: const Duration(seconds: 1),
    Channel.cadence: const Duration(seconds: 1),
  },
);
final tcxString =
    ActivityEncoder.encode(activity, ActivityFileFormat.tcx, options: options);

final fitBase64 =
    ActivityEncoder.encode(activity, ActivityFileFormat.fit, options: options);
final fitBytes = base64Decode(fitBase64);
final fitActivity =
    ActivityParser.parseBytes(fitBytes, ActivityFileFormat.fit).activity;

// GPX version: default is 1.1, set gpxVersion to GpxVersion.v1_0 to feed older tools.
// TCX version: default is v2, set tcxVersion to TcxVersion.v1 for legacy TCX parsers.

// Streaming tip: use ActivityParser.parseStream for large files (e.g. File(...).openRead())
// and ActivityParser.parseBytes when you already have the payload in memory. Call
// ActivityParser.parseAsync(..., useIsolate: true) to offload heavy parses from the UI thread.
```

GPX specifics: both 1.0 and 1.1 payloads are parsed and encoded, including root
name/description/time fields and metadata/track extensions. Tracks/segments are
still flattened, and waypoints/routes are ignored, so waypoint-heavy or
multi-track files will lose that structure on round-trip.

GPX now supports the full Garmin TrackPointExtension v2 schema, which includes
these channel types:
- `Channel.heartRate` - Heart rate (BPM)
- `Channel.cadence` - Cadence (RPM)
- `Channel.power` - Power (watts)
- `Channel.temperature` - Air temperature (Celsius)
- `Channel.waterTemperature` - Water temperature (Celsius)
- `Channel.depth` - Depth (meters)
- `Channel.speed` - Speed (m/s)
- `Channel.course` - Course/heading (degrees true, 0-360)
- `Channel.bearing` - Bearing (degrees true, 0-360)

All v2 fields are automatically parsed from GPX files and encoded when present
in the activity's channel data. Use `ChannelSnapshot` convenience accessors
(e.g., `snapshot.waterTemperature`, `snapshot.depth`) to read these values.

## Editing pipeline

```dart
final editor = ActivityFiles.edit(activity)
    .sortAndDedup()
    .trimInvalid()
    .crop(activity.startTime!, activity.endTime!.subtract(const Duration(minutes: 1)))
    .downsampleTime(const Duration(seconds: 5))
    .smoothHR(5)
    .recomputeDistanceAndSpeed();

final cleaned = editor.activity;

// Validate lap boundaries after compound edits
final lapValidation = editor.validateLapBoundaries();
if (lapValidation.hasIssues) {
  print('Lap validation errors: ${lapValidation.errors}');
  print('Lap validation warnings: ${lapValidation.warnings}');
}
final resampled = RawTransforms.resample(cleaned, step: const Duration(seconds: 2));
final (activity: withDistance, totalDistance: total) =
    RawTransforms.computeCumulativeDistance(resampled);
print('Distance: ${total.toStringAsFixed(1)} m');
```

## Validation

```dart
final validation = validateRawActivity(withDistance);
if (validation.errors.isEmpty) {
  print('Activity valid with ${validation.warnings.length} warning(s).');
} else {
  print('Validation failed:');
  validation.errors.forEach(print);
}
```

## Converter facade

```dart
Future<void> convertGpxToTcx() async {
  final conversion = await ActivityFiles.convert(
    source: gpxString,
    to: ActivityFileFormat.tcx,
    options: options,
    useIsolate: false,
  );
  for (final diagnostic in conversion.diagnostics) {
    print('${diagnostic.severity.name}: ${diagnostic.message}');
  }

  final tcxString = conversion.asString();
  final normalized = conversion.activity;
  print(
    'Loaded ${conversion.sourceFormat.name} → '
    '${conversion.targetFormat.name}, points: ${normalized.points.length}',
  );
}

// `convert` and `convertAndExport` both accept `exportInIsolate` when you want to
// offload encoding work to a background isolate while keeping parsing control via `useIsolate`.

Future<void> convertGpxToFit() async {
  final conversion = await ActivityFiles.convert(
    source: gpxString,
    to: ActivityFileFormat.fit,
    options: options,
    exportInIsolate: true,
    useIsolate: false,
  );
  final fitBytes = conversion.asBytes();
  final roundTrip = await ActivityFiles.load(
    fitBytes,
    format: ActivityFileFormat.fit,
    useIsolate: false,
  );
  print('FIT diagnostics: ${conversion.diagnostics.length}');
  print('Round-trip points: ${roundTrip.activity.points.length}');
}

Future<void> exportWithDiagnostics(RawActivity activity) async {
  final export = ActivityFiles.export(
    activity: activity,
    to: ActivityFileFormat.gpx,
  );
  if (export.hasDiagnostics) {
    print(export.diagnosticsSummary());
  }
  await File('normalized.gpx').writeAsString(export.asString());
}

Future<void> convertAndExportWithValidation(String path) async {
  final export = await ActivityFiles.convertAndExport(
    source: File(path),
    to: ActivityFileFormat.fit,
    runValidation: true,
    exportInIsolate: true,
    useIsolate: false,
  );
  if (export.hasWarnings) {
    print('Warnings: ${export.warningCount}');
  }
  await File('converted.fit').writeAsBytes(export.asBytes());
}

Future<void> streamAndConvert(File input) async {
  final streamed = await ActivityFiles.convertAndExportStream(
    source: input.openRead(),
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.tcx,
    runValidation: true,
    parseInIsolate: true,
    exportInIsolate: true,
  );
  if (streamed.hasErrors) {
    throw StateError(streamed.diagnosticsSummary());
  }
  await File('converted.tcx').writeAsString(streamed.asString());
}

Looking for a complete, runnable example? `example/main.dart` demonstrates
loading, normalization, validation, export, streaming conversions, and
diagnostics handling end to end.

## CLI usage

Run the bundled converter/validator directly from your project:

```shell
dart run activity_files:activity_files.dart convert \
  --from gpx --to tcx -i ride.gpx -o ride.tcx \
  --max-delta-seconds 2 --precision-latlon 7 --hr-max-delta 1 \
  --encoding latin1

dart run activity_files:activity_files.dart convert \
  --from gpx --to gpx -i legacy.gpx -o legacy-1-0.gpx --gpx-version 1.0

dart run activity_files:activity_files.dart convert \
  --from tcx --to tcx -i legacy.tcx -o legacy-v1.tcx --tcx-version 1

dart run activity_files:activity_files.dart validate \
  --format gpx -i ride.gpx --gap-threshold 180
```

Prefer a global install? Activate the package once (`dart pub global activate activity_files`)
and invoke it via `dart pub global run activity_files:activity_files.dart ...`.
The CLI reports parser diagnostics, validation warnings, and exits with a non-zero
status when conversion/validation errors occur. Use `--encoding` for non-UTF8 GPX/TCX
inputs. FIT inputs/outputs are handled as raw binary files by default (the string
APIs only use base64).

## Troubleshooting common errors

### Format not recognized: "Unable to infer activity format"

**Cause**: The loader could not detect the format from the file content or extension.

**Solutions**:
- **Pass `format` explicitly**:
  ```dart
  final result = await ActivityFiles.load(
    source,
    format: ActivityFileFormat.gpx,  // or tcx, fit
  );
  ```
- **For filesystem paths**: Enable `allowFilePaths` if you're passing a path string:
  ```dart
  final result = await ActivityFiles.load(
    'path/to/file.gpx',
    allowFilePaths: true,
  );
  ```
- **For FIT files**: Prefer raw bytes or `File` over base64 strings:
  ```dart
  // Good: raw bytes
  final bytes = await File('activity.fit').readAsBytes();
  final result = await ActivityFiles.load(bytes, format: ActivityFileFormat.fit);
  
  // Less ideal: base64 string (still works, but harder to detect)
  final base64Fit = base64Encode(bytes);
  final result = await ActivityFiles.load(
    base64Fit,
    format: ActivityFileFormat.fit,  // specify format explicitly
  );
  ```

### Payload exceeds size limit

**Cause**: The input file is larger than the default 64MB limit for security/resource safety.

**Solutions**:
- **For one-off large files**: Increase or disable the limit:
  ```dart
  final result = await ActivityFiles.load(
    source,
    maxPayloadBytes: null,  // disable limit (use only for trusted inputs!)
  );
  ```
- **For production code**: Use streaming APIs that don't require full buffering:
  ```dart
  // Streaming parse
  final stream = File('large.fit').openRead();
  final result = await ActivityFiles.load(
    stream,
    // Streams buffer in smaller chunks and can handle very large files
  );
  
  // Streaming conversion/export
  final converted = await ActivityFiles.convertAndExportStream(
    source: File('large.gpx').openRead(),
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.fit,
  );
  ```
- **Route large inputs through pipelines**:
  ```dart
  // ActivityExportRequest supports streaming sources
  final request = ActivityExportRequest.fromStream(
    stream: largeFileStream,
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.fit,
  );
  final result = await ActivityFiles.runPipeline(request);
  ```

### Text encoding mismatch (GPX/TCX)

**Cause**: The file is encoded in a non-UTF-8 format (e.g., ISO-8859-1, Windows-1252), but the loader expected UTF-8.

**Symptom**: `FormatException: Invalid UTF-8` or garbled character output.

**Solutions**:
- **Specify the correct encoding**:
  ```dart
  import 'dart:convert';
  
  final result = await ActivityFiles.load(
    source,
    encoding: latin1,  // or iso-8859-1, windows1252, etc.
  );
  ```
- **For CLI**: Use the `--encoding` flag:
  ```bash
  dart pub global run activity_files convert \
    --source activity.gpx \
    --from gpx \
    --to fit \
    --encoding iso-8859-1
  ```
- **When reading from disk**: Let Dart auto-detect or specify encoding:
  ```dart
  final file = File('activity.gpx');
  final content = await file.readAsString(encoding: latin1);
  final result = await ActivityFiles.load(content, encoding: latin1);
  ```

### FIT integrity check failed

**Cause**: The FIT file has corrupted header/trailer CRCs or is truncated, often due to incomplete upload/transfer.

**Solutions**:
- **If the file is legitimate**: Disable strict integrity checks for parsing (but data may be incomplete):
  ```dart
  final result = await ActivityFiles.load(
    source,
    format: ActivityFileFormat.fit,
    strictFitIntegrity: false,  // Allows corrupt CRCs; still parses what's available
  );
  ```
- **To catch integrity issues early**: Enable strict checks:
  ```dart
  final result = await ActivityFiles.load(
    source,
    format: ActivityFileFormat.fit,
    strictFitIntegrity: true,  // Throws if CRCs don't match
  );
  ```
- **Re-download or regenerate the file**: The best solution is to obtain a clean copy:
  - From a watch/device: resync or re-export.
  - From an upload: check that the transfer completed fully.
  - From a conversion: re-run the conversion from a trusted source.

### Validation warnings and errors

**Cause**: The activity data violates structural constraints (e.g., laps outside the point time range, duplicate timestamps, invalid coordinates).

**Solutions**:
- **Review diagnostics**:
  ```dart
  final result = await ActivityFiles.load(source);
  for (final diagnostic in result.diagnostics) {
    print('${diagnostic.severity}: ${diagnostic.message}');
    if (diagnostic.node != null) {
      print('  Location: ${diagnostic.node!.format()}');
    }
  }
  ```
- **Auto-fix common issues** via normalization:
  ```dart
  final activity = result.activity;
  
  // Remove duplicate/out-of-order timestamps and invalid coordinates
  final cleaned = ActivityFiles.normalizeActivity(activity);
  
  // Trim points outside the activity time window
  final trimmed = ActivityFiles.trimInvalid(activity);
  ```
- **Custom fixes** for specific scenarios:
  ```dart
  final editor = ActivityFiles.edit(activity)
    ..sortAndDedup()           // Sort points/channels/laps, remove duplicates
    ..trimInvalid()            // Remove invalid coordinates
    ..crop(start: t1, end: t2) // Trim to a time range
    ..smoothHR(window: 5);     // Moving average on heart rate
  
  final fixed = editor.activity;
  ```
- **For multi-sport activities**: Check lap sport assignments:
  ```dart
  final result = await ActivityFiles.load(source);
  for (final lap in result.activity.laps) {
    print('Lap sport: ${lap.sport ?? result.activity.sport}');
  }
  ```

### Convert/export failing silently

**Cause**: Parser diagnostics contain errors, but the result is returned (with empty/partial activity).

**Solutions**:
- **Always check for errors before processing**:
  ```dart
  final result = await ActivityFiles.load(source);
  
  if (result.hasErrors) {
    print('Parse failed with errors:');
    for (final diag in result.diagnostics
        .where((d) => d.severity == ParseSeverity.error)) {
      print('  ERROR: ${diag.message}');
    }
    return;  // Don't proceed
  }
  
  // Safe to process result.activity now
  ```
- **Run validation to surface data quality issues**:
  ```dart
  final result = await ActivityFiles.convertAndExport(
    source: source,
    to: ActivityFileFormat.fit,
    runValidation: true,  // Appends validation diagnostics
  );
  
  if (result.validation?.isValid == false) {
    print('Data validation issues:');
    for (final error in result.validation!.errors) {
      print('  $error');
    }
  }
  ```
- **Check the `activity` in the result** to verify data was loaded:
  ```dart
  final result = await ActivityFiles.load(source);
  if (result.activity.points.isEmpty) {
    print('No points were parsed (format or content issue)');
    print('Diagnostics: ${result.diagnostics}');
  }
  ```

### Large file memory usage

**Cause**: Streaming or large conversion is using excessive memory due to buffering.

**Solutions**:
- **Prefer `parseStream` and `convertAndExportStream`**: They buffer in fixed chunks:
  ```dart
  final result = await ActivityFiles.convertAndExportStream(
    source: File('huge.gpx').openRead(),
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.fit,
  );
  // Stream is consumed incrementally; minimal memory for the file itself.
  ```
- **Avoid `maxPayloadBytes: null`** on streamed inputs; let it default:
  ```dart
  // Good: reasonable limit on buffered payload
  final stream = File('large.fit').openRead();
  final result = await ActivityFiles.load(stream);  // Uses default 64MB buffer
  
  // Risky: no limit could cause OOM on very large files
  final result = await ActivityFiles.load(
    stream,
    maxPayloadBytes: null,  // Only if you trust the file size!
  );
  ```
- **Post-process in isolates** to avoid blocking the UI:
  ```dart
  final result = await ActivityFiles.convert(
    source: source,
    to: ActivityFileFormat.fit,
    useIsolate: true,           // Parse in background
    exportInIsolate: true,      // Encode in background
  );
  ```
