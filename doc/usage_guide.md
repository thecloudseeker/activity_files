# activity_files usage guide

Everything you can do with an activity file, you can do two ways: in Dart
code through the library, or on the command line with the bundled
`activity_files` tool. The two are kept on par, so every task below shows
both. The [command line reference](#command-line-reference) collects what
only the command line has: exit codes, output streams, JSON, times and
batches.

## Contents

- [Getting started](#getting-started)
- [Quick start](#quick-start)
- [Dart VM and servers](#dart-vm-and-servers)
- Tasks
  - [Convert a file](#converter-facade)
  - [Choose output details](#parsing--encoding)
  - [Inspect a file](#inspect-a-file)
  - [Validate a file](#validation)
  - [Edit an activity](#editing-pipeline)
  - [Edit single points](#point-level-editing)
  - [Resample to a fixed time step](#resampling-to-a-fixed-time-step)
  - [Merge and split activities](#merging-and-splitting-activities)
  - [Many files at once](#batch-import)
  - [Streams and pipes](#async-export--streaming)
- Handling problems
  - [Error handling](#error-handling)
  - [Resilience](#resilience)
  - [Payload limits](#payload-limits)
  - [Troubleshooting](#troubleshooting)
- The model
  - [Format handling](#format-handling)
  - [RawActivity model](#rawactivity-model)
  - [FIT advanced features](#fit-advanced-features)
  - [Performance tips](#performance-tips)
- [Command line reference](#command-line-reference)

## Getting started

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  activity_files: ^0.8.5
```

Then install dependencies:

```shell
dart pub get
```

See `example/main.dart` for a runnable end-to-end program (load, edit,
validate, export).

To use the command line instead, install it once and run `activity_files`
from anywhere:

```shell
dart pub global activate activity_files
activity_files convert --to gpx -i ride.fit -o ride.gpx
```

Inside a project that depends on the package, `dart run activity_files ...`
runs the same tool without a global install. Every command explains its
options with `--help`:

```shell
activity_files edit --help
```

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
  Future<ActivityImportResult> loadRideFromAssets() async {
    final asset = await rootBundle.load('assets/ride.gpx');
    final bytes = asset.buffer.asUint8List();
    return ActivityFiles.import(
      bytes,
      format: ActivityFileFormat.gpx,
      useIsolate: !kIsWeb,
    );
  }

  Future<ActivityExportResult> convertToFit(Uint8List gpxBytes) {
    return ActivityFiles.convert(
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
as usual; the futures resolve to `ActivityImportResult`/`ActivityExportResult`.

> Web note: When targeting Flutter web, use `useIsolate: false` (and `exportInIsolate: false`). The snippets above gate those flags with `!kIsWeb` for convenience.

Building an activity in code (`builder()`, `buildAndExport`) has no
command-line form: the command line works on files that already exist.

### Raw streams

Backends that expose timestamp/value arrays can skip manual `GeoPoint` and `Sample` assembly by using the stream-aware helpers:

```dart
final device = ActivityDeviceMetadata(
  manufacturer: 'Withings',
  model: 'ScanWatch',
);

final export = await ActivityFiles.buildAndExport(
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
    RawActivityBuilder.activityLabelNode('Morning Run'),
  ],
  trackExtensions: [
    RawActivityBuilder.deviceSummaryNode(
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
final result = await ActivityFiles.import(fitBytes, format: ActivityFileFormat.fit);
final summary = result.activity.summary;
print('Distance: ${summary?.totalDistanceMeters}');
print('Avg HR: ${summary?.avgHeartRate}');

for (final lap in result.activity.laps) {
  print('Lap ${lap.name}: ${lap.distanceMeters}m, avg HR ${lap.avgHeartRate}');
}
```

On the command line, `inspect` prints the same summary and laps (see
[Inspect a file](#inspect-a-file)):

```shell
activity_files inspect -i ride.fit
```

## Dart VM and servers

If you are running on the Dart VM (command-line programs, servers, tests), you can keep using `dart:io` to read from disk. Pass `File` instances directly (preferred) or set `allowFilePaths: true` when a plain string should be treated as a path:

```dart
import 'dart:io';
import 'package:activity_files/activity_files.dart';

Future<void> bootstrap() async {
  final ride = await ActivityFiles.import(
    File('assets/ride.gpx'),
    useIsolate: true,
  );
  print('Detected format: ${ride.format}, points: ${ride.activity.points.length}');

  final fit = await ActivityFiles.convert(
    source: File('assets/ride.gpx'),
    to: ActivityFileFormat.fit,
    runValidation: true,
    exportInIsolate: true,
  );
  await File('ride.fit').writeAsBytes(fit.asBytes());
}
```

> Security note: String sources are treated as inline payloads by default. Only set `allowFilePaths: true` (available on `import()` and `convert()`) when you explicitly trust and expect a filesystem path.

## Converter facade

Convert a file from one format to another. The source format is detected
when you leave it out.

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
  final streamed = await ActivityFiles.convert(
    source: input.openRead(),
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.tcx,
    runValidation: true,
    useIsolate: true,
    exportInIsolate: true,
  );
  if (streamed.hasErrors) {
    throw StateError(streamed.diagnosticsSummary());
  }
  await File('converted.tcx').writeAsString(streamed.asString());
}
```

- `convert` accepts `useIsolate`/`exportInIsolate` to offload parsing/encoding
  to a background isolate; `buildAndExport` accepts `exportInIsolate`.
- `export`, `convert`, and `buildAndExport` accept `runValidation: true` to
  populate `hasWarnings`/`warningCount`/`hasErrors` on the result.
- `convert` normalizes by default (sorts, removes duplicate points and invalid
  coordinates); pass `normalize: false` to keep the source exactly as read.
- `convert` accepts `autoFix:` (`ActivityAutoFixOptions`) to repair common
  data problems on the way; see [Resilience](#resilience).
- To round-trip a FIT export, pass the exported `asBytes()` back into
  `ActivityFiles.import(..., format: ActivityFileFormat.fit)`.

Looking for a complete, runnable example? `example/main.dart` demonstrates
loading, normalization, validation, export, streaming conversions, and
diagnostics handling end to end.

### On the command line

```shell
# The source format is detected; --from names it explicitly.
activity_files convert --to tcx -i ride.gpx -o ride.tcx
activity_files convert --from gpx --to fit -i ride.gpx -o ride.fit

# Keep the source exactly as read, and skip validation.
activity_files convert --to gpx -i ride.fit -o ride.gpx --no-normalize --no-validate

# Repair common data problems on the way (see Resilience).
activity_files convert --to gpx -i ride.fit -o ride.gpx --auto-fix
```

`--to` is always required: the tool never guesses the output format from the
file name. Isolate settings have no command-line form; the tool runs each
file to completion.

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
preserved via `RawActivity.additionalTracks`; segment boundaries, waypoints and
routes are kept in `gpxTrackSegments`, `gpxWaypoints` and `gpxRoutes`.

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

GeoJSON output is a single `LineString` by default; set
`geojsonGeometry: GeojsonGeometry.points` for one `Point` feature per sample,
and `geojsonIncludeChannels: true` to write sensor values onto the points.

### On the command line

Every `EncoderOptions` field has an option on `convert`, `edit`, `merge` and
`split`:

```shell
activity_files convert --to tcx -i ride.gpx -o ride.tcx \
  --max-delta-seconds 2 --precision-latlon 6 --precision-ele 1 \
  --channel-max-delta heart_rate=1 --channel-max-delta cadence=1

activity_files convert --to gpx -i ride.fit -o legacy.gpx --gpx-version 1.0
activity_files convert --to tcx -i ride.fit -o legacy.tcx --tcx-version 1
activity_files convert --to geojson -i ride.fit -o ride.geojson \
  --geojson-geometry points --geojson-channels
```

`--channel-max-delta` takes any channel id, custom channels included
(`heart_rate`, `cadence`, `power`, `temperature`, `water_temperature`, `depth`,
`speed`, `course`, `bearing`, `distance`, or a custom name).

## Inspect a file

Look at what a file contains before deciding what to do with it: its format,
sport, time range, channels, laps and the diagnostics the parser reported.

```dart
final result = await ActivityFiles.import(File('ride.fit'));
final activity = result.activity;
print('Format: ${result.format.name}, sport: ${activity.sport.name}');
print('From ${activity.startTime} to ${activity.endTime}');
print('Points: ${activity.points.length}, laps: ${activity.laps.length}');
for (final entry in activity.channels.entries) {
  print('${entry.key.id}: ${entry.value.length} samples');
}
for (final d in result.diagnostics) {
  print('${d.severity.name} ${d.code}: ${d.message}');
}
```

### On the command line

```shell
activity_files inspect -i ride.fit
activity_files inspect -i ride.fit --json
activity_files inspect -i exports/ --recursive
```

Text output looks like this (the summary goes to stdout):

```text
ride.fit
  format     fit
  sport      cycling
  time       2024-05-01T07:30:00Z to 2024-05-01T09:12:41Z (1h42m41s)
  points     6161
  channels   heart_rate 6161, cadence 6161, power 6158, distance 6161
  laps       5
  sessions   1
  events     2
  device     Garmin Edge 540
  creator    Garmin Connect
  warnings   1
    - fit.record.recovered_timestamp: Record timestamp missing; reused recent timestamp context for best-effort extraction.
```

## Validation

```dart
final validation = validateRawActivity(activity);
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

### On the command line

`validate` runs `ActivityFiles.validate` and passes or fails a file as it
does; warnings are listed but do not fail it. What the reader reported,
such as a FIT checksum mismatch, is listed too and does not fail the file.
A file that cannot be read at all fails.

```shell
activity_files validate -i ride.gpx
activity_files validate -i ride.gpx --gap-threshold 3m
activity_files validate -i rides/ --recursive --json
```

The exit code is 0 when every file passes and 65 when any file fails, so a
script can gate on it directly.

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

final total = cleaned.channels[Channel.distance]!.last.value;
print('Distance: ${total.toStringAsFixed(1)} m');
```

### On the command line

`edit` applies its steps in the order you type them, exactly like the chain
above, then writes the result once. It needs at least one step; to change
only the format, use `convert`. `--to` changes the format in the same pass and
defaults to the input's format.

```shell
activity_files edit -i ride.fit -o cleaned.fit \
  --sort-and-dedup --trim-invalid --crop start..end-1m \
  --downsample-time 5s --smooth-hr 5 --recompute-distance-and-speed

# Cut the warm-up and the café stop, and hand Strava a GPX.
activity_files edit -i ride.fit -o ride.gpx --to gpx \
  --crop 5m..end-20m --recompute-distance-and-speed
```

Order matters: `--crop ... --recompute-distance-and-speed` makes distance
start at 0 at the new start, while the reverse order keeps the original
distances. Every step is listed in the
[edit steps table](#edit-steps); times use the forms described in
[Times](#times).

### Resampling to a fixed time step

`RawEditor.downsampleTime` thins a recording by keeping original points and
dropping the rest, so the gaps between the survivors still vary.
`RawTransforms.resample` answers the other question: it puts points and
channels on a fixed grid, synthesizing samples that were never recorded.

```dart
final onGrid = RawTransforms.resample(activity, step: const Duration(seconds: 1));
```

Reach for it when a consumer needs exactly one sample per interval: charting
libraries that assume a regular x axis, models trained on fixed-cadence input,
or comparing two recordings of the same route sample by sample.

What the grid does to the data:

- Points and every channel other than heart rate are interpolated linearly
  between their two neighbouring samples. Latitude, longitude, and elevation
  move along a straight line, which is an approximation, not a recovery of the
  real track.
- Heart rate takes the nearest sample within half a step and emits nothing when
  there is none, so a dropout stays a dropout instead of being smoothed over.
- Past a channel's last sample, its final value is held.
- The activity's last timestamp is always the closing grid point, so the final
  interval can be shorter than `step`.
- Laps, summary, device metadata, and every other field carry over untouched.
  Lap boundary times are not snapped to the grid, so a boundary may no longer
  land on a point.

Activities with fewer than two points come back unchanged, and a zero or
negative `step` throws `ArgumentError`.

Distance and speed are interpolated like any other channel, which is not the
same as deriving them from the new geometry. Recompute after resampling when
they need to agree with the grid:

```dart
final onGrid = RawTransforms.resample(activity, step: const Duration(seconds: 1));
final rebuilt = ActivityFiles.edit(onGrid).recomputeDistanceAndSpeed().activity;
```

On the command line, the same two steps in the same order:

```shell
activity_files edit -i ride.fit -o grid.fit --resample 1s --recompute-distance-and-speed
```

Interpolating across every point of a multi-hour recording is CPU-heavy; see
[Performance tips](#performance-tips) before putting it on a UI thread.

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

### On the command line

The same operations as `edit` steps. Point indexes count from 0, as in the
library.

```shell
activity_files edit -i ride.gpx -o fixed.gpx \
  --insert-point 2024-03-01T10:00:05Z,40.001,-105.001 \
  --update-point 0,lat=40.0001,lon=-105.0001 \
  --delete-point 2 \
  --delete-range 2024-03-01T10:05:00Z..2024-03-01T10:08:00Z \
  --insert-pause 2024-03-01T10:10:00Z,2m \
  --remove-pause 2024-03-01T10:15:00Z..2024-03-01T10:17:00Z
```

Each step sees the result of the steps before it, so an index or time refers
to the activity as it is at that point in the chain.

## Merging and splitting activities

`RawEditor` provides static methods for combining separate activities or splitting multi-sport files:

```dart
final swim = await ActivityFiles.import(File('swim.gpx'));
final bike = await ActivityFiles.import(File('bike.fit'));
final run = await ActivityFiles.import(File('run.tcx'));

final triathlon = RawEditor.merge(
  [swim.activity, bike.activity, run.activity],
  preserveSportPerLap: true,
);

final combined = ActivityFiles.export(
  activity: triathlon,
  to: ActivityFileFormat.tcx,
);

final parsed = await ActivityFiles.import(File('triathlon.tcx'));
final splits = RawEditor.splitBySport(parsed.activity);

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

### On the command line

`merge` takes several inputs and writes one file; `split` takes one file and
writes one file per leg into `--out-dir`.

```shell
activity_files merge -i swim.gpx -i bike.fit -i run.tcx \
  --to tcx -o triathlon.tcx --preserve-sport-per-lap

activity_files split -i triathlon.tcx --out-dir legs/ --to gpx
# legs/triathlon.1-swimming.gpx
# legs/triathlon.2-cycling.gpx
# legs/triathlon.3-running.gpx
```

Inputs are merged in the order given. Split files are numbered by their start
time and named after their sport; `--to` defaults to the input's format.
`merge` also takes `--creator NAME`, and both take `--no-normalize`, like the
library's `creator` and `normalize` parameters.

## Batch import

`ActivityFiles.importBatch` loads a list of sources in sequence and collects
results without stopping on individual failures:

```dart
final files = [File('a.gpx'), File('b.fit'), File('c.tcx')];

final batch = await ActivityFiles.importBatch(
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

### On the command line

`convert`, `edit`, `validate` and `inspect` take any number of inputs, files
and folders mixed. Converted files go into `--out-dir`:

```shell
# A whole Garmin export, subfolders included.
activity_files convert --to gpx -i garmin_export/ --recursive --out-dir gpx/

# Some files, stopping at the first one that fails.
activity_files convert --to tcx -i a.gpx -i b.fit -i c.tcx --out-dir tcx/ --stop-on-error
```

Progress and a summary ("798 converted, 2 failed") go to stderr. See
[Many files and folders](#many-files-and-folders) for the naming rules.

### Re-exporting a loaded activity

`ActivityFiles.channelSamplesFrom` converts all channels of a `RawActivity`
into the `Map<Channel, List<ChannelStreamSample>>` format expected by
`buildAndExport`, removing per-channel reconstruction glue:

```dart
final loaded = await ActivityFiles.import(File('ride.gpx'));
final channels = ActivityFiles.channelSamplesFrom(loaded.activity);
final location = [
  for (final p in loaded.activity.points)
    (
      timestamp: p.time.millisecondsSinceEpoch,
      latitude: p.latitude,
      longitude: p.longitude,
      elevation: p.elevation,
    ),
];
await ActivityFiles.buildAndExport(
  location: location,
  channels: channels,
  to: ActivityFileFormat.fit,
);
```

This rebuilds an activity in code, so it has no command-line form; to write
a loaded file in another format, use `convert`.

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
  final result = await ActivityFiles.convert(
    source: stream,
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.tcx,
    runValidation: true,
  );
  await File('streamed.tcx').writeAsString(result.asString());
}

Future<void> convertFromPath(String path) async {
  final result = await ActivityFiles.convert(
    source: File(path),
    from: null, // auto-detects GPX/TCX/FIT/CSV/GeoJSON
    to: ActivityFileFormat.fit,
    runValidation: true,
    exportInIsolate: true,
  );
  await File('converted.fit').writeAsBytes(result.asBytes());
}
```

> Streaming caveat: the current `parseStream` implementation buffers the entire stream in memory before parsing so it can rewind when needed. This keeps the API consistent across platforms today but means very large uploads still need enough RAM for the full payload. If you need true incremental parsing you can feed the parser with your own chunked loader that enforces back-pressure and chunk sizes.

### On the command line

`-` as input reads stdin, `-` as output writes stdout. stdout then carries
only the file, so the tool fits into a pipe:

```shell
curl -s https://example.com/ride.fit \
  | activity_files convert --to gpx -i - -o - \
  | gzip > ride.gpx.gz
```

Messages always go to stderr, so they never end up inside the file. Writing a
FIT file to a terminal is refused; redirect it or name an output file.

## Error handling

`ActivityFiles.import`, `convert`, and export helpers surface parser/validation issues via diagnostics rather than throwing. Always gate on `hasErrors` (or inspect the diagnostics list) before trusting the returned activity:

```dart
final result = await ActivityFiles.import(sourceBytes, useIsolate: false);
if (result.hasErrors) {
  log('Import failed:\n${result.diagnosticsSummary()}');
  return;
}
final normalized = ActivityFiles.edit(
  result.activity,
).sortAndDedup().trimInvalid().activity;
```

The same pattern applies to conversion/export results:

```dart
final export = await ActivityFiles.convert(
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

### On the command line

The command line does the gating for you: a file whose parser reported an
error is not written, and the exit code says what happened (see
[Exit codes](#exit-codes)). With `--json`, every diagnostic arrives with its
code, severity, message, suggested fix and priority:

```shell
activity_files convert --to fit -i upload.gpx -o upload.fit --json 2> diagnostics.jsonl
```

## Resilience

**FIT corruption**: header/trailer CRC mismatches and truncated files surface as
`fit.header.crc_mismatch`, `fit.trailer.crc_mismatch`, or
`fit.trailer.truncated` diagnostics. The parser continues, filters clearly
corrupt records (timestamps outside 1989–2050, invalid coordinates, points more
than 24 hours or 100 km from their neighbors), and returns what it could
extract. Set `strictFitIntegrity: true` on `import`/`convert`/streamed helpers to
throw `FormatException` instead of returning a partial result.

```dart
final r = await ActivityFiles.import(fitBytes, format: ActivityFileFormat.fit);
final hasIntegrityIssue = r.diagnostics.any(
  (d) => d.code.contains('crc') || d.code.contains('truncated'),
);
if (hasIntegrityIssue && r.activity.points.isNotEmpty) {
  // Accept with flag: data may be usable despite corruption.
}
```

**GPX/TCX malformed**: parse errors surface as `gpx.parse.xml_error` or
`tcx.parse.xml_error`. If the result has no points, reject it.

**Bad GPS / sensor data**: chain
`ActivityFiles.edit(activity).sortAndDedup().trimInvalid().recomputeDistanceAndSpeed()`.
The editor also
removes Null Island sentinel coordinates (lat/lon ≈ 0) and clears Garmin
no-elevation sentinels (elevation ≤ −499 m; the point is kept, only the bogus
elevation is discarded). Check `RawEditor.repairDiagnostics` after a
`trimInvalid()` call, or the `repaired.*` entries in conversion diagnostics,
to see what was repaired.

**Automatic repair**: `ActivityAutoFixOptions` bundles the common repairs
(invalid GPS, channel drift, distance drift, timestamp gaps, laps by
distance) for `convert(autoFix:)` and `RawEditor.autoFix`.

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

### On the command line

```shell
# Refuse a corrupt FIT file instead of keeping what could be read.
activity_files convert --to gpx -i ride.fit -o ride.gpx --strict-fit

# The repair chain as edit steps, with what was repaired on stderr.
activity_files edit -i ride.gpx -o fixed.gpx \
  --sort-and-dedup --trim-invalid --recompute-distance-and-speed

# Automatic repair with every option of ActivityAutoFixOptions.
activity_files convert --to gpx -i ride.fit -o ride.gpx --auto-fix \
  --no-fix-timestamp-gaps --auto-lap --auto-lap-distance 1000

# Legacy text files that are not UTF-8.
activity_files convert --to gpx -i old.gpx -o new.gpx --encoding latin1
```

Lap boundaries are part of `validate`. The auto-fix options are listed in the
[reference](#auto-fix-options).

## Payload limits

- Inline strings/byte arrays and buffered streams are capped at 64MB
  (`ActivityFiles.defaultMaxPayloadBytes`) by default. Larger inputs throw
  `FormatException`.
- To override the limit, pass `maxPayloadBytes` to `import()`, `convert()`,
  or `detectFormat()`. Pass `null` to disable the limit entirely.
- For very large files, stream from disk/network in smaller chunks, split the
  source before parsing/exporting, or set `maxPayloadBytes: null` if you trust
  the input.

```dart
final huge = await ActivityFiles.convert(
  source: File('huge.fit'),
  to: ActivityFileFormat.gpx,
  maxPayloadBytes: null, // a file you trust
);
```

On the command line, `--max-payload-bytes` sets the same limit, and
`--max-payload-bytes none` disables it for a file you trust:

```shell
activity_files convert --to gpx -i huge.fit -o huge.gpx --max-payload-bytes none
```

## Format handling

- GPX: multiple `<trk>` elements are preserved. The first track becomes the
  primary `RawActivity`; subsequent tracks are stored in
  `RawActivity.additionalTracks` and re-emitted when encoding back to GPX.
  Encoding to a single-track format (TCX/FIT/CSV/GeoJSON) merges all tracks
  via `RawActivity.flattened()`, so no points are lost; `ActivityFiles.convert`
  reports this with a `lossy.multi_track_flattened` info diagnostic.
  `RawEditor` operations apply to the primary track only. Segment boundaries,
  waypoints and routes are kept (`gpxTrackSegments`, `gpxWaypoints`,
  `gpxRoutes`).
- TCX: multiple `<Activity>` elements are merged into one `RawActivity` with
  per-lap `sport` (reported via the `tcx.multi_activity` info diagnostic); see
  "Multi-sport activities" below. Re-exporting to TCX splits laps back into
  one `<Activity>` per sport.

The command line reads and writes through the same parsers and encoders, so
everything here applies to it unchanged.

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
- On the command line, convert many files in one run rather than one run per
  file: starting the tool costs about a second with `dart run`.

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
value inherit from the activity's overall sport. To merge separate files or
split a multi-sport file, see
[Merge and split activities](#merging-and-splitting-activities).

## FIT advanced features

Everything below round-trips losslessly through the FIT encoder (absent
values stay absent, encoded as FIT invalid sentinels). On the command line,
`inspect` shows the sessions, laps, lengths, sets and events a file holds,
and `--json` gives them field by field.

### Swim metrics

`ActivitySummary` carries pool-level fields and each `Lap` carries
stroke-level fields, also exposed through the typed `FitSessionView`/
`FitLapView` via `activity.asFitView()`:

```dart
final result = await ActivityFiles.import(fitBytes, format: ActivityFileFormat.fit);
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
final result = await ActivityFiles.import(fitBytes, format: ActivityFileFormat.fit);

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

## Troubleshooting

### "Unable to infer activity format"

Format detection failed on the given content. Pass `format:` explicitly to
`import`/`convert` (`--from` on the command line). If you passed a filesystem
path as a plain string, it was treated as inline content. Pass a `File`
instead, or set `allowFilePaths: true`. For FIT, prefer raw bytes or a `File`
over base64 strings; base64 defeats content sniffing.

### "Payload exceeds size limit" / high memory use

Parsing buffers the full payload in memory (streamed sources too), up to the
`maxPayloadBytes` cap (see the streaming caveat under "Async export &
streaming"). The default 64MB cap exists so untrusted inputs cannot exhaust
memory.

- For trusted larger files, raise the cap (e.g.
  `maxPayloadBytes: 256 * 1024 * 1024`, or `--max-payload-bytes 268435456`)
  or disable it with `null` (`--max-payload-bytes none`).
- Pass `File` objects or streams instead of reading the payload into memory
  yourself, so only one copy is held.
- Set `useIsolate` / `exportInIsolate` to keep buffering and encoding off the
  UI thread.
- If none of that fits, split the source file before parsing.

### "FormatException: Invalid UTF-8" or garbled text

The file is not UTF-8 (common for older GPX/TCX exports). Pass
`encoding: latin1` (or another `dart:convert` codec) to `import`/`convert`, or
`--encoding latin1` on the command line.

### FIT integrity errors (`fit.header.crc_mismatch`, `fit.trailer.truncated`)

The file is corrupt or truncated, usually from an incomplete transfer. By
default parsing continues and reports the problem as error diagnostics;
inspect them and decide whether the partial data is acceptable (see
"Resilience"). Set `strictFitIntegrity: true` (`--strict-fit`) to refuse the
file instead. The reliable fix is a clean copy: resync the device or repeat
the upload.

### Validation reports warnings or errors

The data violates structural constraints: lap boundaries outside the track,
duplicate timestamps, invalid coordinates. Each `ValidationDiagnostic` carries
a `suggestedFix`; most issues are cleared by
`ActivityFiles.edit(activity).sortAndDedup().trimInvalid()` (on the command
line, `edit --sort-and-dedup --trim-invalid`) or a targeted editor chain
(`sortAndDedup`, `trimInvalid`, `crop`, `smoothHR`; see "Editing pipeline").

### Conversion "succeeds" but the output is empty

Load and convert helpers do not throw on bad input; they return a result whose
diagnostics contain the errors, alongside an empty or partial activity. Gate on
`hasErrors` (see "Error handling") and check `result.activity.points.isEmpty`
before trusting the output. The command line does this for you: it does not
write a file whose parser reported an error, and exits with 65.

## Command line reference

### Commands

| Command | What it does | Library |
|---|---|---|
| `convert` | Writes a file in another format | `ActivityFiles.convert` |
| `edit` | Changes an activity, step by step | `ActivityFiles.edit`, then `export` |
| `merge` | Combines several files into one | `RawEditor.merge` |
| `split` | Writes one file per leg of a multi-sport file | `RawEditor.splitBySport` |
| `validate` | Checks files and reports what is wrong | `validateRawActivity`, `validateLapBoundariesList`, `validateDeviceMetadata`, `validateChannels` |
| `inspect` | Summarizes what files contain | `ActivityFiles.import` |

`activity_files --version` prints the version, and `activity_files <command>
--help` lists every option of a command.

### Reading options

All commands read their input the same way.

| Option | Meaning | Library |
|---|---|---|
| `-i`, `--input` | A file, a folder, or `-` for stdin. Repeat it for more inputs. | `import(source)` |
| `--from` | Input format: `gpx`, `tcx`, `fit`, `csv`, `geojson`. Detected when left out. | `format:` / `from:` |
| `--recursive` | Also read the subfolders of a folder input. | |
| `--encoding` | Text encoding of GPX/TCX/CSV/GeoJSON input. Default `utf-8`. | `encoding:` |
| `--strict-fit` | Refuse a FIT file with integrity errors instead of keeping what could be read. | `strictFitIntegrity:` |
| `--max-payload-bytes` | Largest input in bytes, or `none`. Default 67108864 (64 MB). | `maxPayloadBytes:` |
| `--json` | `validate` and `inspect`: the report as JSON Lines on stdout. | |

### Writing options

`convert`, `edit`, `merge` and `split` write files.

| Option | Meaning | Library |
|---|---|---|
| `-o`, `--output` | Output file, or `-` for stdout. One input only. | |
| `--out-dir` | Output folder, for several inputs, folders, and `split`. | |
| `--to` | Output format. Required for `convert` and `merge`; `edit` and `split` default to the input's format. | `to:` |
| `--no-normalize` | Keep the activity exactly as read: no sorting, deduplication or trimming. | `normalize: false` |
| `--no-validate` | Skip validation of the written activity. | `runValidation: false` |
| `--precision-latlon` | Decimal places for latitude and longitude, 0 to 20. Default 6. | `precisionLatLon` |
| `--precision-ele` | Decimal places for elevation, 0 to 20. Default 2. | `precisionEle` |
| `--max-delta-seconds` | How far a sensor sample may lie from a point and still be written with it, as a duration. Default 5s. | `defaultMaxDelta` |
| `--channel-max-delta` | `CHANNEL=DURATION` for one channel; repeat for more. | `maxDeltaPerChannel` |
| `--gpx-version` | `1.1` (default) or `1.0`. | `gpxVersion` |
| `--tcx-version` | `2` (default) or `1`. | `tcxVersion` |
| `--geojson-geometry` | `line` (default) or `points`. | `geojsonGeometry` |
| `--geojson-channels` | Write sensor values onto GeoJSON points. | `geojsonIncludeChannels` |
| `--json` | Diagnostics as JSON Lines on stderr. | |

### Command options

| Option | Command | Library |
|---|---|---|
| `--gap-threshold` | `validate`: report gaps between points longer than this duration. Default 5m. | `validateRawActivity(gapWarningThreshold:)` |
| `--preserve-sport-per-lap` | `merge`: give each lap its source file's sport. | `RawEditor.merge(preserveSportPerLap:)` |
| `--creator` | `merge`: software name written as the creator. | `RawEditor.merge(creator:)` |
| `--auto-fix` | `convert`: repair common data problems during the conversion. | `convert(autoFix:)` |
| `--stop-on-error` | `convert`, `edit`, `validate`, `inspect`: stop at the first file that fails. | `importBatch(stopOnError:)` |

### Edit steps

Steps run in the order typed. Each one sees the result of the steps before
it.

| Step | Argument | Library |
|---|---|---|
| `--sort-and-dedup` | | `sortAndDedup()` |
| `--strict-time-order` | | `ensureStrictTimeOrder()` |
| `--trim-invalid` | | `trimInvalid()` |
| `--crop` | `FROM..TO` | `crop(start, end)` |
| `--shift-time` | duration, may be negative (`-1h`) | `shiftTime(delta)` |
| `--insert-point` | `TIME,LAT,LON` or `TIME,LAT,LON,ELE` | `insertPoint(point)` |
| `--update-point` | `INDEX,lat=..,lon=..,ele=..,time=..` (any of the four) | `updatePoint(index, ...)` |
| `--delete-point` | `INDEX` | `deletePointAt(index)` |
| `--delete-range` | `FROM..TO` | `deleteRange(from, to)` |
| `--insert-pause` | `AT,DURATION` | `insertPause(at, duration)` |
| `--remove-pause` | `FROM..TO` | `removePause(from, to)` |
| `--downsample-time` | duration | `downsampleTime(step)` |
| `--downsample-distance` | meters | `downsampleDistance(meters)` |
| `--smooth-hr` | window size in samples | `smoothHR(window)` |
| `--recompute-distance-and-speed` | | `recomputeDistanceAndSpeed()` |
| `--mark-laps-by-distance` | meters | `markLapsByDistance(meters)` |
| `--resample` | duration | `RawTransforms.resample(step:)` |
| `--auto-fix` | uses the [auto-fix options](#auto-fix-options) | `autoFix(options)` |

### Auto-fix options

`--auto-fix` turns on the repairs of `ActivityAutoFixOptions()`: as an option
of `convert` it runs them during the conversion (`convert(autoFix:)`), as an
`edit` step it runs them at that point in the chain. These options tune it:

| Option | Library field | Default |
|---|---|---|
| `--no-fix-invalid-gps` | `fixInvalidGps` | on |
| `--no-fix-channel-drift` | `fixChannelDrift` | on |
| `--no-fix-distance-drift` | `fixDistanceDrift` | on |
| `--no-fix-timestamp-gaps` | `fixTimestampGaps` | on |
| `--gap-fill-threshold` | `gapThreshold` | 5m |
| `--max-gap-points` | `maxInsertedGapPoints` | 250 |
| `--auto-lap` | `autoLapByDistance` | off |
| `--auto-lap-always` | `autoLapOnlyWhenMissing: false` | off (laps only when the file has none) |
| `--auto-lap-distance` | `autoLapDistanceMeters` | by sport |
| `--running-lap-distance` | `runningLapDistanceMeters` | 1000 |
| `--cycling-lap-distance` | `cyclingLapDistanceMeters` | 5000 |
| `--default-lap-distance` | `defaultLapDistanceMeters` | 1000 |

### Times

Wherever a step takes a time:

| Form | Meaning |
|---|---|
| `5m`, `1h20m`, `90s`, `1h20m30s`, `500ms` | That long after the activity's first recorded sample |
| `start`, `end` | The first and the last recorded sample |
| `end-20m` | 20 minutes before the last recorded sample |
| `2024-05-01T07:35:00Z`, `2024-05-01T09:35:00+02:00` | That exact moment; the zone is required |

A range is `FROM..TO` with any two forms. Durations are wall-clock time, so
pauses count: `1h40m` matches the elapsed time a watch or Strava shows, not
the moving time. Every option that takes a duration also accepts a plain
number of seconds (`--gap-threshold 180` is `3m`). Anything else is rejected
with exit code 64.

### Many files and folders

- `-i` takes files and folders, mixed and repeated. A folder means its
  `.gpx`, `.tcx`, `.fit`, `.csv`, `.geojson` and `.json` files; hidden files
  are skipped. `--recursive` adds subfolders.
- Several inputs, or a folder, need `--out-dir` instead of `-o`. Each output
  keeps its input's name with the new extension, and the folder structure
  below the input folder is repeated under `--out-dir`.
- If two outputs would still get the same name, the run stops before writing
  anything and names both inputs. A file is never overwritten by another
  input's output.
- A file that fails is reported and the others continue; `--stop-on-error`
  stops at the first failure instead.
- Progress and a summary go to stderr.

### Output streams

- **stdout** carries only the result: the written file when the output is
  `-`, the `validate` report, and the `inspect` summary.
- **stderr** carries every message about the work: diagnostics, validation
  warnings, "Converted ...", progress, errors.

### JSON

With `--json`, the tool writes JSON Lines: one JSON object per line, one line
per file. `validate` and `inspect` write their reports to stdout; `convert`,
`edit`, `merge` and `split` write their diagnostics to stderr.

A diagnostic:

```json
{"source": "parser", "severity": "warning", "code": "fit.record.recovered_timestamp", "message": "Record timestamp missing; reused recent timestamp context for best-effort extraction.", "suggestedFix": "Timestamps were inferred from context. ...", "priority": 3, "node": "fit.record (localType=3)"}
```

A line that holds only a `warning` is a message about the command itself, not
about a file.

`source` is `parser`, `validation`, `repair` (what an edit step repaired) or
`export` (what the output format cannot hold, the `lossy.*` codes). Absent
fields are left out.

`validate`:

```json
{"input": "ride.gpx", "format": "gpx", "passed": true, "points": 6161, "diagnostics": [...]}
```

`inspect`:

```json
{"input": "ride.fit", "format": "fit", "sport": "cycling", "start": "2024-05-01T07:30:00.000Z", "end": "2024-05-01T09:12:41.000Z", "points": 6161, "channels": {"heart_rate": 6161, "cadence": 6161}, "laps": 5, "sessions": 1, "lengths": 0, "sets": 0, "events": 2, "device": {"manufacturer": "Garmin", "model": "Edge 540"}, "creator": "Garmin Connect", "diagnostics": [...]}
```

`convert` and `edit`, one line per input:

```json
{"input": "ride.fit", "output": "ride.gpx", "written": true, "diagnostics": [...]}
```

`merge` names its `inputs` as a list, and `split` its `outputs`. A file that
failed has `"written": false` and an `error` with the reason, as does a
`validate` or `inspect` report of a file that could not be read.

The layout is public: fields are only added, never renamed or removed,
without a major version.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Done. Warnings may have been reported. |
| 64 | Usage error: an unknown command or option, an invalid value, or options that do not go together. Nothing was read or written. |
| 65 | Data error: a file could not be read, failed validation, an edit step does not fit the activity (a point index or a time outside it), or, with several inputs, at least one file failed. |
| 66 | An input file or folder does not exist. |
| 70 | Writing failed, or something unexpected went wrong. The message says what. |

### Encodings

`--encoding` takes `utf-8` (also written `utf8`), `latin1` (`iso-8859-1`),
and `ascii` (`us-ascii`). FIT files are binary and ignore it.
