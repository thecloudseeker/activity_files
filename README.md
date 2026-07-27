# activity_files
[![Pub Package](https://img.shields.io/pub/v/activity_files.svg)](https://pub.dev/packages/activity_files)
[![License](https://img.shields.io/badge/license-BSD%203--Clause-blue.svg)](LICENSE)
[![codecov](https://codecov.io/gh/thecloudseeker/activity_files/branch/main/graph/badge.svg)](https://codecov.io/gh/thecloudseeker/activity_files)
[![Pub Points](https://img.shields.io/pub/points/activity_files)](https://pub.dev/packages/activity_files/score)
[![GitHub Issues](https://img.shields.io/github/issues/thecloudseeker/activity_files.svg)](https://github.com/thecloudseeker/activity_files/issues)
[![Pub Likes](https://img.shields.io/pub/likes/activity_files)](https://pub.dev/packages/activity_files/score)
[![GitHub Stars](https://img.shields.io/github/stars/thecloudseeker/activity_files.svg)](https://github.com/thecloudseeker/activity_files/stargazers)

A pure Dart toolkit for parsing, editing, validating, and converting workout activity files in GPX, TCX, FIT, GeoJSON, and CSV formats.

## Highlights

- Format-agnostic `RawActivity` model covering GPS points, laps, sensor
  channels, and device metadata.
- `ActivityFiles` facade and CLI: load, normalize, validate, and convert
  between all five formats in a few calls.
- Stream-aware builders (`builderFromStreams`, `convertAndExport`) accept raw
  timestamp/value tuples, so servers can skip manual model assembly.
- Parsers never throw on malformed files; every issue is reported as a
  diagnostic with a stable `code`, a `suggestedFix`, and a `priority`.
- FIT session and lap statistics on `ActivitySummary` and `Lap`, mapped per the
  official FIT profile and verified against real device files, including swim
  metrics (pool length, stroke, lengths) and strength sets (`WorkoutSet`).
- Point-level editing on `RawEditor`: `insertPoint`, `deletePointAt`,
  `updatePoint`, `deleteRange`, `insertPause`, `removePause`.
- Multi-sport workflows: `ActivityFiles.merge(preserveSportPerLap: true)`
  combines swim/bike/run files into one triathlon; `splitBySport()` breaks a
  multi-sport file back into single-sport activities.
- Batch import (`ActivityFiles.loadBatch`) with per-file error capture and
  progress reporting.
- Multi-track GPX round-trips: extra `<trk>` elements survive GPX export;
  single-track targets (TCX/FIT/CSV/GeoJSON) merge them so no points are lost.
- Encoder options for GPX 1.0/1.1 and TCX v1/v2 output, channel tolerances,
  and coordinate precision.

## Call for real-world files
As I only have one fitness tracking device, real-world GPX, TCX, FIT, GeoJSON, and CSV files are highly appreciated. Contributed files are used for local testing only; they are never published or committed to the repository.
Please send them to: `packages@eikedreier.xyz`

## Quick links

- [Usage guide](doc/usage_guide.md) – Flutter, CLI, streaming, and
  error-handling walkthroughs.
- [Example app](example/main.dart) – runnable end-to-end demo: load, edit,
  validate, export.
- [CHANGELOG](CHANGELOG.md) – migration notes and release history.

## Getting started

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  activity_files: ^0.7.0
```

Then install dependencies:

```shell
dart pub get
```

Then jump straight into the facade:

```dart
import 'package:activity_files/activity_files.dart';

Future<void> convertGpxToFit(Uint8List bytes) async {
  // 1) Load + auto-detect format.
  final load = await ActivityFiles.load(
    bytes,
    useIsolate: true,
  );
  if (load.hasErrors) {
    throw StateError('Load failed:\n${load.diagnosticsSummary()}');
  }

  // 2) Normalize (sort/dedup + trim invalid points) before exporting.
  final normalized = ActivityFiles.normalizeActivity(load.activity);

  // 3) Export with validation so warnings/errors surface alongside the payload.
  final export = ActivityFiles.export(
    activity: normalized,
    to: ActivityFileFormat.fit,
    runValidation: true,
  );
  if (export.hasErrors) {
    throw StateError('Export failed:\n${export.diagnosticsSummary()}');
  }

  // 4) Use the payload. FIT is binary; GPX/TCX use `asString()`.
  final fitBytes = export.asBytes();
  // upload(fitBytes);
}
```

For the detailed Flutter, streaming, CLI, and isolate walkthroughs, see the
[usage guide](doc/usage_guide.md); for a complete runnable program
(load → normalize → validate → export), see `example/main.dart`.

## Working with large or malformed files

- Parsing/export never throw on malformed input; check `hasErrors` and
  `diagnosticsSummary()` on the result (see
  [error handling](doc/usage_guide.md#error-handling)).
- Inline payloads/streams are capped at 64MB
  (`ActivityFiles.defaultMaxPayloadBytes`); use `useIsolate`/`exportInIsolate`
  and the streaming APIs for bigger files (see
  [async export & streaming](doc/usage_guide.md#async-export--streaming)).
- GPX multi-track inputs are flattened when exported to single-track formats
  (no points lost); TCX multi-activity inputs are merged on parse instead,
  with per-lap sport preserved. See
  [format handling](doc/usage_guide.md#format-handling) for details.

## Contributing

Issues and pull requests are welcome, especially for additional format fixtures. The package is released under the BSD 3-Clause license.
