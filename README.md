# activity_files
Licensed under the BSD 3-Clause License. See [LICENSE](./LICENSE) for details.

A pure Dart toolkit for reading, editing, validating, and writing workout
activity files. `activity_files` provides format-agnostic models, robust GPX and
TCX parsers/encoders, transformation utilities, and a CLI for quick conversions
or validation.

> FIT payloads are exchanged as base64 strings so they can flow through the
> string-based APIs without loss.

## Highlights

- Unified `RawActivity` model with geographic samples, sensor channels, laps,
  and sport metadata.
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
  activity_files: ^0.0.2
```

Then install dependencies:

```shell
dart pub get
```

See `example/basic_usage.dart` for a minimal round-trip through the encoders.

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
// Parse GPX to RawActivity (plus non-fatal warnings).
final result = ActivityParser.parse(gpxString, ActivityFileFormat.gpx);
for (final warning in result.warnings) {
  print('Warning: $warning');
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

// FIT payloads are emitted as base64 strings, but you can work with the raw
// bytes directly using ActivityParser.parseBytes.
final fitBase64 = ActivityEncoder.encode(activity, ActivityFileFormat.fit, options: options);
final fitBytes = base64Decode(fitBase64);
final fitActivity =
    ActivityParser.parseBytes(fitBytes, ActivityFileFormat.fit).activity;

> Tip: `ActivityParser.parseBytes` accepts binary FIT payloads directly, so you
> can feed `File('ride.fit').readAsBytesSync()` without wrapping it in base64.
```

## Editing pipeline

```dart
final editor = RawEditor(activity)
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
final warnings = <String>[];
final converted = ActivityConverter.convert(
  gpxString,
  from: ActivityFileFormat.gpx,
  to: ActivityFileFormat.tcx,
  encoderOptions: options,
  warnings: warnings,
);
if (warnings.isNotEmpty) {
  warnings.forEach(print);
}

// FIT conversions yield base64 strings containing the binary payload.
final fitWarnings = <String>[];
final fitResult = ActivityConverter.convert(
  gpxString,
  from: ActivityFileFormat.gpx,
  to: ActivityFileFormat.fit,
  encoderOptions: options,
  warnings: fitWarnings,
);
final fitRoundTrip =
    ActivityParser.parse(fitResult, ActivityFileFormat.fit).activity;
```

## CLI usage

```
$ dart run bin/activity_files.dart convert --from gpx --to tcx -i ride.gpx -o ride.tcx \
    --max-delta-seconds 2 --precision-latlon 7 --hr-max-delta 1
$ dart run bin/activity_files.dart validate --format gpx -i ride.gpx --gap-threshold 180
```

The CLI reports parser warnings, validation warnings, and exits with a non-zero
status when validation errors are detected.
Binary FIT inputs/outputs are handled automatically via base64 conversion.

## Contributing

Issues and pull requests are welcome, especially for additional format fixtures. The package is released under the MIT license.
