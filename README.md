# activity_files
Licensed under the BSD 3-Clause License. See [LICENSE](./LICENSE) for details.

A pure Dart toolkit for reading, editing, validating, and writing workout
activity files. `activity_files` provides format-agnostic models, robust GPX and
TCX parsers/encoders, transformation utilities, and a CLI for quick conversions
or validation.

## Highlights

<!-- TODO(doc): Add a performance considerations section detailing common
profiling hotspots and how to tune normalization/export flags. -->
- Unified `RawActivity` model with geographic samples, sensor channels, laps,
  and sport metadata.
- High-level `ActivityFiles` facade for loading, converting, and building
  activities with minimal setup.
- Stream-first builders (`builderFromStreams`) and export helpers accept raw
  timestamp/value tuples so backend streams can export without manual
  `GeoPoint`/`Sample` wiring.
- One-call export pipeline (`ActivityFiles.export` / `convertAndExport`) that
  normalizes, validates, and returns encoded payloads plus aggregated diagnostics, with optional isolate
  offloading via `exportInIsolate`.
- Pluggable sport inference hooks plus GPX device/label helpers remove custom
  mapping glue for popular wearables.
- Declarative `ActivityExportRequest` for orchestrating parse → normalize →
  export flows from a single builder-style object.
- DiagnosticsFormatter utilities and processing stats for consistent diagnostic
  summaries across logs, CLIs, and UIs.
- Namespace-tolerant GPX/TCX parsers that surface non-fatal schema issues as
  warnings instead of throwing.
- Channel-aware encoders with configurable matching tolerances and numeric
  precision via `EncoderOptions`.
- Immutable editing pipeline (`RawEditor`, `RawTransforms`) for cropping,
  resampling, smoothing, and derived metrics.
- Reliability improvements to lap generation, downsampling, and deduplication
  ensure transforms preserve the latest sensor samples and emit accurate splits.
- Structural validation helpers producing concise error/warning reports.
- Builder-level device metadata and namespace-aware GPX extensions for richer
  downstream encoders.
- Optional CLI (`bin/activity_files.dart`) for converting files or running
  validations from the terminal.

## Getting started

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  activity_files: ^0.3.2
```

Then install dependencies:

```shell
dart pub get
```

See `example/main.dart` for a minimal round-trip through the encoders.

## Quick start

### Flutter app (mobile & web)

Bundle your sample data alongside the app so it is available on every
platform:

```yaml
flutter:
  assets:
    - assets/ride.gpx
```

Load the asset via `rootBundle`, wire the isolate toggle for web, and expose
helpers your widgets can call:

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

> Web note: Flutter web does not support isolates. Always pass `useIsolate: false`
> (and `exportInIsolate: false`) when targeting the web. The snippets above gate
> those flags with `!kIsWeb` for convenience.

### Raw streams

Backends that expose timestamp/value arrays can skip manual `GeoPoint` and
`Sample` assembly by using the stream-aware helpers:

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

Each stream uses records (`({timestamp, latitude, longitude, elevation})` and
`({timestamp, value})`), making it trivial to forward arrays from REST or gRPC
payloads. When wearable categories differ from the built-in `Sport` enum, call
`ActivityFiles.registerSportMapper` once during startup to plug in your own
mapping strategy.

### Dart VM / CLI

If you are running on the Dart VM (CLI tools, servers, tests), you can work with
paths and `dart:io` just as before:

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

### Async export & streaming

> Web note: Flutter web does not support isolates. Pass `useIsolate: false`
> (and disable `exportInIsolate`) when running these helpers in a web build.

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
      source: path,
      from: null, // auto-detects GPX/TCX/FIT
      to: ActivityFileFormat.fit,
      runValidation: true,
      exportInIsolate: true,
    ),
  );
  await File('converted.fit').writeAsBytes(result.asBytes());
}
```

> Streaming caveat: the current `parseStream` implementation buffers the entire
> stream in memory before parsing so it can rewind when needed. This keeps the
> API consistent across platforms today but means very large uploads still need
> enough RAM for the full payload. If you need true incremental parsing you can
> feed the parser with your own chunked loader that enforces back-pressure and
> chunk sizes.

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
  creator: 'Example Watch',
);
```

## Parsing and encoding

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
  maxDeltaPerChannel: {
    Channel.heartRate: const Duration(seconds: 1),
    Channel.cadence: const Duration(seconds: 1),
  },
);
final tcxString = ActivityEncoder.encode(activity, ActivityFileFormat.tcx, options: options);

final fitBase64 = ActivityEncoder.encode(activity, ActivityFileFormat.fit, options: options);
final fitBytes = base64Decode(fitBase64);
final fitActivity =
    ActivityParser.parseBytes(fitBytes, ActivityFileFormat.fit).activity;

> Tip: use `ActivityParser.parseStream` for large files (e.g. `File(...).openRead()`)
> and `ActivityParser.parseBytes` when you already have the payload in memory. Call
> `ActivityParser.parseAsync(..., useIsolate: true)` to offload heavy parses from the UI thread.
> Encoding hint: Pass the appropriate `encoding` when loading byte-backed GPX/TCX
> exports (e.g. ISO-8859-1 or Shift-JIS) so text is decoded correctly.
```

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
final resampled = RawTransforms.resample(cleaned, step: const Duration(seconds: 2));
final (activity: withDistance, totalDistance: total) = RawTransforms.computeCumulativeDistance(resampled);
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

// Note: `ActivityFiles.convert` and `convertAndExport` both accept an
// `exportInIsolate` flag when you want to offload heavy encoding work to a
// background isolate while keeping parsing control via `useIsolate`.

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
    source: path,
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
```

## CLI usage

```
$ dart run bin/activity_files.dart convert --from gpx --to tcx -i ride.gpx -o ride.tcx \
    --max-delta-seconds 2 --precision-latlon 7 --hr-max-delta 1
$ dart run bin/activity_files.dart validate --format gpx -i ride.gpx --gap-threshold 180
```

The CLI reports parser diagnostics, validation warnings, and exits with a non-zero
status when validation errors are detected.
Binary FIT inputs are read directly from `.fit` files, and FIT outputs are
written as binary files (base64 is only used when you opt into the string APIs).

## Contributing

Issues and pull requests are welcome, especially for additional format fixtures. The package is released under the BSD 3-Clause license.
