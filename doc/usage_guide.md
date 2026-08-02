# activity_files usage guide

## Getting started

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  activity_files: ^0.7.2
```

Then install dependencies:

```shell
dart pub get
```

See `example/main.dart` for a runnable end-to-end program (load, edit,
validate, export).

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

Wire `repository.loadRideFromAssets()` / `.convertToFit()` into a `FutureBuilder`
as usual; the futures resolve to `ActivityLoadResult`/`ActivityExportResult`.

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

Each stream uses records (`({timestamp, latitude, longitude, elevation})` and `({timestamp, value})`), so arrays from REST or gRPC payloads can be forwarded as-is. When wearable categories differ from the built-in `Sport` enum, call `ActivityFiles.registerSportMapper` once during startup to plug in your own mapping.

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

## Resilience

**FIT corruption**: header/trailer CRC mismatches and truncated files surface as
`fit.header.crc_mismatch`, `fit.trailer.crc_mismatch`, or
`fit.trailer.truncated` diagnostics. The parser continues, filters clearly
corrupt records (timestamps outside 1989–2050, invalid coordinates, points more
than 24 hours or 100 km from their neighbors), and returns what it could
extract. Set `strictFitIntegrity: true` on `load`/`convert`/streamed helpers to
throw `FormatException` instead of returning a partial result.

```dart
final r = await ActivityFiles.load(fitBytes, format: ActivityFileFormat.fit);
final hasIntegrityIssue = r.diagnostics.any(
  (d) => d.code.contains('crc') || d.code.contains('truncated'),
);
if (hasIntegrityIssue && r.activity.points.isNotEmpty) {
  // Accept with flag: data may be usable despite corruption.
}
```

**GPX/TCX malformed**: parse errors surface as `gpx.parse.malformed` or
`tcx.parse.malformed`. If the result has no points, reject it.

**Bad GPS / sensor data**: use `normalizeActivity` with `trimInvalid: true`,
`sortAndDedup: true`, and `recomputeDistanceAndSpeed: true`. The editor also
removes Null Island sentinel coordinates (lat/lon ≈ 0) and clears Garmin
no-elevation sentinels (elevation ≤ −499 m; the point is kept, only the bogus
elevation is discarded). Check `RawEditor.repairDiagnostics` after a
`trimInvalid()` call, or the `repaired.*` entries in conversion diagnostics,
to see what was repaired.

**Lap boundaries**: validate after compound edits:

```dart
final laps = RawEditor(activity).validateLapBoundaries();
if (laps.hasIssues) print(laps.errors);
```

**Text encoding**: pass `encoding: latin1` when loading legacy GPX/TCX/CSV
files that are not UTF-8.

**Telemetry**: diagnostic codes are stable strings; count or route them:

```dart
final crcErrors = r.diagnostics.where((d) => d.code == 'fit.trailer.crc_mismatch');
```

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

- GPX: multiple `<trk>` elements are preserved. The first track becomes the
  primary `RawActivity`; subsequent tracks are stored in
  `RawActivity.additionalTracks` and re-emitted when encoding back to GPX.
  Encoding to a single-track format (TCX/FIT/CSV/GeoJSON) merges all tracks
  via `RawActivity.flattened()`, so no points are lost; `ActivityFiles.convert`
  reports this with a `lossy.multi_track_flattened` info diagnostic.
  `RawEditor` operations apply to the primary track only. Segments within a
  track are flattened. Waypoints and routes are not yet parsed.
- TCX: multiple `<Activity>` elements are merged into one `RawActivity` with
  per-lap `sport` (reported via the `tcx.multi_activity` info diagnostic); see
  "Multi-sport activities" below. Re-exporting to TCX splits laps back into
  one `<Activity>` per sport.

## Async export & streaming

> Web note: same `useIsolate`/`exportInIsolate: false` rule as above.

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
      from: null, // auto-detects GPX/TCX/FIT/CSV/GeoJSON
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
  ),
  // Plus optional gpxMetadataName/gpxTrackName/gpxTrackExtensions/... for
  // GPX-specific metadata; see the dartdoc on RawActivity for the full list.
);

final channelMapper = ChannelMapper.cursor(activity.channels);
final snapshot = channelMapper.snapshot(activity.points.first.time);
print('HR: ${snapshot.heartRate}, cadence: ${snapshot.cadence}');

final normalized = ActivityFiles.edit(activity)
    .smoothHR(5)
    .trimInvalid()
    .sortAndDedup()
    .activity;
```

> Tip: see "Raw streams" above for building activities from raw
> timestamp/value tuples without `GeoPoint`/`Sample`.

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
      sport: Sport.swimming,
    ),
    Lap(
      startTime: DateTime.utc(2024, 7, 21, 6, 25),
      endTime: DateTime.utc(2024, 7, 21, 7, 25),
      distanceMeters: 40000,
      sport: Sport.cycling,
    ),
    Lap(
      startTime: DateTime.utc(2024, 7, 21, 7, 30),
      endTime: DateTime.utc(2024, 7, 21, 8, 0),
      distanceMeters: 5000,
      sport: Sport.running,
    ),
  ],
  sport: Sport.swimming,  // Overall activity sport (first segment)
);
```

Parsing TCX files with multiple `<Activity>` elements or FIT files with
multiple sessions merges them automatically this way; see "Format handling"
and "FIT advanced features" for the per-format diagnostics
(`tcx.multi_activity`/`fit.multi_session`). Laps without an explicit `sport`
value inherit from the activity's overall sport.

### Merging and splitting activities

`ActivityFiles` provides convenience methods for combining separate activities or splitting multi-sport files:

```dart
final swim = await ActivityFiles.load(File('swim.gpx'));
final bike = await ActivityFiles.load(File('bike.fit'));
final run = await ActivityFiles.load(File('run.tcx'));

final triathlon = ActivityFiles.merge(
  [swim.activity, bike.activity, run.activity],
  preserveSportPerLap: true,
);

final combined = ActivityFiles.export(
  activity: triathlon,
  to: ActivityFileFormat.tcx,
);

final parsed = await ActivityFiles.load(File('triathlon.tcx'));
final splits = ActivityFiles.splitBySport(parsed.activity);

final swimActivity = splits[Sport.swimming]!;
final bikeActivity = splits[Sport.cycling]!;
final runActivity = splits[Sport.running]!;

final swimGpx = ActivityFiles.export(activity: swimActivity, to: ActivityFileFormat.gpx);
final bikeGpx = ActivityFiles.export(activity: bikeActivity, to: ActivityFileFormat.gpx);
final runGpx = ActivityFiles.export(activity: runActivity, to: ActivityFileFormat.gpx);
```

`merge()` combines GPS points, sensor channels, and laps from all activities. Set `preserveSportPerLap: true` to create multi-sport activities where each lap retains its source activity's sport.

`splitBySport()` divides activities by lap sport assignments, filtering points and channels to each sport's time range. Each resulting activity contains only data from laps with that sport type. In the split outputs the per-lap `sport` is cleared (each activity is single-sport, so its laps inherit the activity-level sport again), while every other lap field (distance, calories, avg/max metrics, FIT event fields, swim stroke and lengths) is preserved.

To clear the per-lap sport on your own laps, use `Lap.copyWithoutSport()`; `copyWith` cannot set a field back to `null`:

```dart
final lapWithoutSport = lap.copyWithoutSport();
assert(lapWithoutSport.sport == null);
```

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
```

GPX specifics: both 1.0 and 1.1 payloads are parsed and encoded, including root
name/description/time fields and metadata/track extensions. Multiple tracks are
preserved via `RawActivity.additionalTracks`; segments within each track are
flattened; waypoints and routes are not yet parsed.

GPX supports the full Garmin TrackPointExtension v2 schema, covering these
channel types:
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

Every check emits a `ValidationDiagnostic` with a stable `code`,
`suggestedFix`, and `priority`. Use `validation.diagnostics` to route or
display structured results:

```dart
for (final d in validation.diagnostics) {
  print('[${d.severity.name}] ${d.code}: ${d.message}');
  if (d.suggestedFix != null) print('  → ${d.suggestedFix}');
}
```

### Device metadata and channel validation

```dart
final device = activity.device;
final deviceDiags = device != null
    ? validateDeviceMetadata(device)
    : <ValidationDiagnostic>[];
// Flags blank strings, out-of-range FIT manufacturer/product IDs,
// and manufacturer name mismatches against the built-in FIT SDK table.

final channelDiags = validateChannels(activity.channels);
// Flags empty channels and single-sample channels (interpolation not
// meaningful).
```

### Repair diagnostics

`RawEditor.trimInvalid()` removes Null Island sentinel coordinates, clears
Garmin no-elevation sentinels (keeping the points), and records what it
repaired:

```dart
final editor = RawEditor(activity)..trimInvalid();
for (final d in editor.repairDiagnostics) {
  print('Repaired ${d.code}: ${d.message}');
}
final cleaned = editor.activity;
```

## Point-level editing

Beyond the bulk editing methods, `RawEditor` supports precise point-level
mutations for manual correction flows:

```dart
final editor = RawEditor(activity);

// Insert a new GPS point in chronological order (no channel/lap changes).
editor.insertPoint(GeoPoint(
  latitude: 40.001,
  longitude: -105.001,
  time: DateTime.utc(2024, 3, 1, 10, 0, 5),
));

// Update a point in place; re-sorts by time when time is changed.
editor.updatePoint(0, latitude: 40.0001, longitude: -105.0001);

// Remove the point at index 2.
editor.deletePointAt(2);

// Delete all GPS points and channel samples in [from, to] (inclusive)
// and clip laps/sets that straddle the boundary.
editor.deleteRange(
  DateTime.utc(2024, 3, 1, 10, 5),
  DateTime.utc(2024, 3, 1, 10, 8),
);

// Shift everything strictly after `at` forward by `duration` (insert pause).
editor.insertPause(
  DateTime.utc(2024, 3, 1, 10, 10),
  const Duration(minutes: 2),
);

// Close a time gap: removes points inside (from, to) and shifts ≥ to back.
editor.removePause(
  DateTime.utc(2024, 3, 1, 10, 15),
  DateTime.utc(2024, 3, 1, 10, 17),
);
```

## Batch import

`ActivityFiles.loadBatch` loads a list of sources in sequence and collects
results without stopping on individual failures:

```dart
final files = [File('a.gpx'), File('b.fit'), File('c.tcx')];

final batch = await ActivityFiles.loadBatch(
  files,
  onProgress: (done, total) => print('$done / $total'),
  stopOnError: false, // default: continue past failures
);

print('Imported: ${batch.successCount}, failed: ${batch.failureCount}');
for (final failure in batch.failures) {
  print('${failure.source}: ${failure.error}');
}
for (final result in batch.successes) {
  print('${result.activity.points.length} points');
}
```

### Re-exporting a loaded activity

`ActivityFiles.channelSamplesFrom` converts all channels of a `RawActivity`
into the `Map<Channel, List<ChannelStreamSample>>` format expected by
`convertAndExport`, removing per-channel reconstruction glue:

```dart
final loaded = await ActivityFiles.load(File('ride.gpx'));
final channels = ActivityFiles.channelSamplesFrom(loaded.activity);
final location = [
  for (final p in loaded.activity.points)
    (
      timestamp: p.time.millisecondsSinceEpoch ~/ 1000,
      latitude: p.latitude,
      longitude: p.longitude,
      elevation: p.elevation,
    ),
];
await ActivityFiles.convertAndExport(
  location: location,
  channels: channels,
  to: ActivityFileFormat.fit,
);
```

## FIT advanced features

Everything below round-trips losslessly through the FIT encoder (absent
values stay absent, encoded as FIT invalid sentinels).

### Swim metrics

`ActivitySummary` carries pool-level fields and each `Lap` carries
stroke-level fields, also exposed through the typed `FitSessionView`/
`FitLapView` via `activity.asFitView()`:

```dart
final result = await ActivityFiles.load(fitBytes, format: ActivityFileFormat.fit);
final summary = result.activity.summary;

print('Pool length: ${summary?.poolLengthMeters}m');
print('Active lengths: ${summary?.numActiveLengths}');
print('Stroke: ${summary?.swimStroke?.name}'); // e.g. "freestyle"
print('Avg strokes/length: ${summary?.avgStrokeCount}');

for (final lap in result.activity.laps) {
  print('Lap: ${lap.numActiveLengths} lengths, '
      'stroke: ${lap.swimStroke?.name}');
}
```

`ActivitySummary` also carries `subSport` (raw FIT sub-sport integer, e.g. 45
for jump rope) and `totalCycles` (sport-specific movement cycles: strides,
pedal revolutions, swimming strokes, jumps).

### Multi-session (triathlons)

The first session becomes `RawActivity.summary` (and sets the activity
sport); every further session is preserved in
`RawActivity.additionalSessions`, each with its own `ActivitySummary.sport`.
The parser reports multi-session files with the info diagnostic
`fit.multi_session`:

```dart
print('Primary: ${result.activity.sport.name}');
for (final session in result.activity.additionalSessions) {
  print('${session.sport?.name}: ${session.totalDistanceMeters}m');
}
```

### Timer events and per-length swim data

Timer events (FIT message 21) parse into `RawActivity.events`; a stop event
followed by a start event delimits a pause. Per-length pool-swim data (FIT
message 101) parses into `RawActivity.lengths`:

```dart
for (final e in result.activity.events.where((e) => e.isTimerEvent)) {
  print('${e.isStop ? "pause" : "resume"} at ${e.time}');
}
for (final l in result.activity.lengths.where((l) => l.isActive)) {
  print('${l.elapsed.inSeconds}s, ${l.totalStrokes} strokes '
      '(${l.swimStroke?.name})');
}
```

Unknown numeric FIT record fields are preserved as `fit_field_<n>` custom
channels; unknown CSV columns, GeoJSON properties, and GPX
TrackPointExtension tags become custom channels under their own names, and
foreign GPX point extension elements survive on `GeoPoint.gpxExtensions`.

### Strength-training sets

FIT set messages (message ID 225) parse into `RawActivity.sets` (also
accessible via `activity.asFitView().sets`):

```dart
final result = await ActivityFiles.load(fitBytes, format: ActivityFileFormat.fit);

for (final s in result.activity.sets) {
  if (s.isRest) {
    print('Rest: ${s.elapsed.inSeconds}s');
  } else {
    print('${s.exerciseCategory ?? "Set"}: '
        '${s.repetitions} reps × ${s.weightKg}kg '
        '(${s.elapsed.inSeconds}s)');
  }
}
```

`WorkoutSet.categoryLabel(int?)` maps a raw FIT `exercise_category` integer to
a human-readable label (e.g. `28` → `"Squat"`); the raw integer is preserved
on `WorkoutSet.exerciseCategoryId`.

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
```

- `convert`, `convertAndExport`, and `convertAndExportStream` all accept
  `useIsolate`/`exportInIsolate` to offload parsing/encoding to a background
  isolate.
- `export` and `convertAndExport` accept `runValidation: true` to populate
  `hasWarnings`/`warningCount`/`hasErrors` on the result.
- To round-trip a FIT export, pass the exported `asBytes()` back into
  `ActivityFiles.load(..., format: ActivityFileFormat.fit)`.

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

`convert` accepts any of the five formats (`gpx`, `tcx`, `fit`, `csv`,
`geojson`) as `--from`/`--to`; `validate` accepts the same set via `--format`.

Prefer a global install? Activate the package once (`dart pub global activate activity_files`)
and invoke it via `dart pub global run activity_files:activity_files.dart ...`.
The CLI reports parser diagnostics, validation warnings, and exits with a non-zero
status when conversion/validation errors occur. Use `--encoding` for non-UTF8 GPX/TCX/CSV/GeoJSON
inputs. FIT inputs/outputs are handled as raw binary files by default (the string
APIs only use base64).

## Troubleshooting

### "Unable to infer activity format"

Format detection failed on the given content. Pass `format:` explicitly to
`load`/`convert`. If you passed a filesystem path as a plain string, it was
treated as inline content. Pass a `File` instead, or set
`allowFilePaths: true`. For FIT, prefer raw bytes or a `File` over base64
strings; base64 defeats content sniffing.

### "Payload exceeds size limit" / high memory use

Parsing buffers the full payload in memory (streamed sources too), up to the
`maxPayloadBytes` cap (see the streaming caveat under "Async export &
streaming"). The default 64MB cap exists so untrusted inputs cannot exhaust
memory.

- For trusted larger files, raise the cap (e.g.
  `maxPayloadBytes: 256 * 1024 * 1024`) or disable it with `null`.
- Pass `File` objects or streams instead of reading the payload into memory
  yourself, so only one copy is held.
- Set `useIsolate` / `exportInIsolate` to keep buffering and encoding off the
  UI thread.
- If none of that fits, split the source file before parsing.

### "FormatException: Invalid UTF-8" or garbled text

The file is not UTF-8 (common for older GPX/TCX exports). Pass
`encoding: latin1` (or another `dart:convert` codec) to `load`/`convert`, or
`--encoding iso-8859-1` on the CLI.

### FIT integrity errors (`fit.header.crc_mismatch`, `fit.trailer.truncated`)

The file is corrupt or truncated, usually from an incomplete transfer. By
default parsing continues and reports the problem as error diagnostics;
inspect them and decide whether the partial data is acceptable (see
"Resilience"). Set `strictFitIntegrity: true` to throw instead. The reliable
fix is a clean copy: resync the device or repeat the upload.

### Validation reports warnings or errors

The data violates structural constraints: lap boundaries outside the track,
duplicate timestamps, invalid coordinates. Each `ValidationDiagnostic` carries
a `suggestedFix`; most issues are cleared by
`ActivityFiles.normalizeActivity(activity)` or a targeted editor chain
(`sortAndDedup`, `trimInvalid`, `crop`, `smoothHR`; see "Editing pipeline").

### Conversion "succeeds" but the output is empty

Load and convert helpers do not throw on bad input; they return a result whose
diagnostics contain the errors, alongside an empty or partial activity. Gate on
`hasErrors` (see "Error handling") and check `result.activity.points.isEmpty`
before trusting the output.
