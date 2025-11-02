# activity_files
Licensed under the BSD 3-Clause License. See [LICENSE](./LICENSE) for details.

A pure Dart toolkit for reading, editing, validating, and writing workout
activity files. `activity_files` provides format-agnostic models, robust GPX and
TCX parsers/encoders, transformation utilities, and a CLI for quick conversions
or validation.

> FIT payloads can be handled as raw bytes or base64 strings; the library now
> provides both string- and byte-oriented APIs.

## Highlights

- Unified `RawActivity` model with geographic samples, sensor channels, laps,
  and sport metadata.
- High-level `ActivityFiles` facade for loading, converting, and building
  activities with minimal setup.
- Namespace-tolerant GPX/TCX parsers that surface non-fatal schema issues as
  warnings instead of throwing.
- Channel-aware encoders with configurable matching tolerances and numeric
  precision via `EncoderOptions`.
- Immutable editing pipeline (`RawEditor`, `RawTransforms`) for cropping,
  resampling, smoothing, and derived metrics.
- Structural validation helpers producing concise error/warning reports.
- Optional CLI (`bin/activity_files.dart`) for converting files or running
  validations from the terminal.

## Getting started

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  activity_files: ^0.2.0
```

Then install dependencies:

```shell
dart pub get
```

See `example/main.dart` for a minimal round-trip through the encoders.

## Quick start

```dart
import 'dart:io';
import 'package:activity_files/activity_files.dart';

Future<void> bootstrap() async {
  // Load and inspect an existing GPX file.
  final ride = await ActivityFiles.load('assets/ride.gpx');
  print('Detected format: ${ride.format}, points: ${ride.activity.points.length}');

  // Convert to FIT and persist the binary payload.
  final fit = await ActivityFiles.convert(
    source: 'assets/ride.gpx',
    to: ActivityFileFormat.fit,
  );
  await File('ride.fit').writeAsBytes(fit.asBytes());

  // Build a new activity incrementally.
  final builder = ActivityFiles.builder()
    ..sport = Sport.running
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
  print('New activity: ${activity.points.length} point(s)');
}
```

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

Future<void> convertGpxToFit() async {
  final conversion = await ActivityFiles.convert(
    source: gpxString,
    to: ActivityFileFormat.fit,
    options: options,
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
