# activity_files
[![Pub Package](https://img.shields.io/pub/v/activity_files.svg)](https://pub.dev/packages/activity_files)
[![Pub Points](https://img.shields.io/pub/points/activity_files)](https://pub.dev/packages/activity_files/score)
[![Pub Likes](https://img.shields.io/pub/likes/activity_files)](https://pub.dev/packages/activity_files/score)
[![codecov](https://codecov.io/gh/thecloudseeker/activity_files/branch/main/graph/badge.svg)](https://codecov.io/gh/thecloudseeker/activity_files)
[![License](https://img.shields.io/badge/license-BSD%203--Clause-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/thecloudseeker/activity_files.svg)](https://github.com/thecloudseeker/activity_files/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/thecloudseeker/activity_files.svg)](https://github.com/thecloudseeker/activity_files/network)
[![GitHub Issues](https://img.shields.io/github/issues/thecloudseeker/activity_files.svg)](https://github.com/thecloudseeker/activity_files/issues)

Licensed under the BSD 3-Clause License. See [LICENSE](./LICENSE) for details.

  A pure Dart toolkit for reading, editing, validating, and writing workoutactivity files. `activity_files` provides format-agnostic models, robust GPX, TCX and FIT parsers/encoders, transformation utilities, and a CLI for quick conversionsor validation.
  
## Highlights

- Format-agnostic `RawActivity` model with builders/editors for GPS points,
  laps, channels, and device metadata.
- Ergonomic `ActivityFiles` facade plus CLI that load, normalize, validate, and
  export GPX/TCX/FIT payloads in a handful of calls.
- Stream-aware builders (`builderFromStreams`, `convertAndExport`) so servers
  can feed timestamp/value tuples directly without manual model wiring.
- Diagnostics-first results with sport mappers, validation stats, and
  namespace-tolerant parsers that never throw on untrusted files.
- Channel cursors, resampling helpers, and encoder options keep exports fast
  while letting you control tolerances/precision.
- Flexible export targets: emit GPX 1.0/1.1 and TCX v1/v2 via `EncoderOptions`
  or CLI flags; FIT encoding focuses on core workout fields (developer fields
  and full SDK coverage intentionally out of scope today).

See the [usage guide](doc/usage_guide.md) for the full feature tour and
performance notes.

## Quick links

- [Usage guide (full README)](doc/usage_guide.md) – Flutter, CLI, streaming,
  and error-handling walkthroughs.
- [Example app](example/main.dart) – minimal GPX round-trip.
- [CLI reference](doc/usage_guide.md#cli-usage) – conversions/validation from
  the terminal.
- [CHANGELOG](CHANGELOG.md) – migration notes and release history.

## Getting started

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  activity_files: ^0.4.1
```

Then install dependencies:

```shell
dart pub get
```

See `example/main.dart` for a complete sample or jump straight into the facade:

```dart
import 'package:activity_files/activity_files.dart';

Future<void> convertGpxToFit(Uint8List bytes) async {
  // 1) Load + detect format; throws if format cannot be inferred.
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
  final export = await ActivityFiles.export(
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

Need to handle large uploads? The loader caps inline payloads/streams at
64MB (`ActivityFiles.defaultMaxPayloadBytes`). For bigger files, stream and
convert without buffering everything:

```dart
Future<ActivityExportResult> streamConvert(File input) {
  return ActivityFiles.convertAndExportStream(
    source: input.openRead(),
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.tcx,
    parseInIsolate: true,
    exportInIsolate: true,
    runValidation: true,
  );
}
```

The [usage guide](doc/usage_guide.md) now hosts the detailed Flutter widget,
streaming, CLI, and isolate walkthroughs that previously lived in this README.
For a complete, runnable walkthrough (load → normalize → validate → export),
see `example/main.dart`.

## Source inputs & isolates

- String inputs are treated as inline payloads. Pass a `File` (preferred) or set
  `allowFilePaths: true` when you explicitly trust the string to reference local
  storage.
- `useIsolate` / `exportInIsolate` offload work when isolates are available.
  Gate both flags with `!kIsWeb` for Flutter web builds.
- Stream-backed loads keep a replayable buffer so `bytesPayload` remains usable
  even after parsing completes.
- Payload limits: inline strings/bytes and buffered streams are capped at 64MB
  (`ActivityFiles.defaultMaxPayloadBytes`). Oversized inputs throw
  `FormatException` (and the CLI rejects them) to avoid unbounded memory use;
  split very large uploads before parsing.

## Diagnostics-first workflows

Parsing, conversion, and export helpers never throw for malformed files—they
surface issues via `ParseDiagnostic`s on the result. Always check `hasErrors`,
`diagnosticsSummary`, or the `diagnostics` list before trusting the returned
`RawActivity`. The [error-handling section](doc/usage_guide.md#error-handling)
shows ready-to-copy patterns for both load and export flows.

### Format limitations

- GPX 1.0/1.1 are both parsed/encoded, including metadata/track names,
  descriptions, and extensions. The parser flattens all tracks/segments into a
  single stream and ignores waypoints/routes, so files that rely on multiple
  tracks or saved waypoints will lose that structure on load/export.
- TCX: only the first `<Activity>` is parsed. Additional activities in a single
  file are skipped.

If you need full fidelity for multi-activity or waypoint-heavy files, split
inputs before loading or extend the parsers to keep those constructs.

## Async export & streaming

`ActivityExportRequest`, `convertAndExport`, and `exportAsync` share the same
builder API for raw location/channel streams plus isolate toggles so you can
pin heavy work off the UI thread. See
[doc/usage_guide.md#async-export--streaming](doc/usage_guide.md#async-export--streaming)
for streamed conversions, CLI pipelines, and memory caveats.

For advanced editing pipelines, parser/encoder samples, and CLI walkthroughs, see the [usage guide](doc/usage_guide.md), which retains the detailed examples previously listed here.

## Contributing

Issues and pull requests are welcome, especially for additional format fixtures. The package is released under the BSD 3-Clause license.
