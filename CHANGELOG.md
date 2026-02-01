# Changelog

## 0.4.3
### Fixed
- Fix FIT parser to remove corrupted data points with invalid timestamps or coordinates, ensuring FIT→GPX and FIT→TCX output matches reference files

## 0.4.2
### Fixed
- Fix FIT parser for non-standard message ordering. Thanks [@hallr-boulder](https://github.com/hallr-boulder) for reporting (fixes #2)
- Improved support for swimming activity files with non-standard message ordering
- Parser now gracefully handles unknown message types instead of crashing

## 0.4.1
### Fixed
- Fix formatting and prevent it from happening again with a local git hook

## 0.4.0
### Breaking
- Plain string sources are always treated as inline payloads; pass a `File` or
  set `allowFilePaths: true` on `load`/`convert`/`convertAndExport`/
  `ActivityExportRequest.fromSource` to read from disk.
- A 64MB cap (`ActivityFiles.defaultMaxPayloadBytes`) applies to
  load/convert/detect and streamed pipelines; oversized inputs throw or emit
  error diagnostics. Stream from disk/network or split files to go larger; only
  `ActivityParser.parseStream(maxBytes: ...)` lets you override the limit.

### Added
- Stream-backed loads are replayable; `ActivityLoadResult.bytesPayload` exposes
  buffered bytes even when the source was a `Stream<List<int>>`.
- FIT integrity: header/trailer CRCs and truncation are reported as error
  diagnostics (or throw when `strictFitIntegrity: true`); the encoder now emits
  invalid coordinate sentinels for sensor-only activities.
- Structural validation enforces lap ordering/overlap and warns when sensor
  channels extend past the point timeline during load/convert/export flows.
- GPX/TCX version selection: `EncoderOptions` and CLI flags can emit GPX 1.0/1.1
  and TCX v1/v2; defaults remain GPX 1.1/TCX v2. FIT remains core-workout only.
- GPX 1.0 round-trips root metadata, track extensions, and labels when
  `gpxVersion` is `GpxVersion.v1_0`.

### Changed
- `RawTransforms` and `RawEditor` live in dedicated modules
  (`transforms/raw_transforms.dart`, `transforms/raw_editor.dart`); `transforms.dart`
  still exports both for existing imports.
- `ChannelMapper.cursor` exposes reusable per-channel cursors; `mapAt` now wraps
  it so overlays reuse cached lookups.
- GPX/TCX/FIT encoders reuse the cursor (TCX/FIT also use distance readings) to
  avoid repeated binary searches.
- Resampling pre-sizes timetables and reuses sliding cursors to keep
  `RawTransforms.resample`/`_resampleNearest` fast on long recordings.
- `RawEditor` skips work on sorted/valid inputs and reuses its timestamp cursor
  during `downsampleTime`.
- FIT exports defer base64 decoding until `asBytes()` when FIT sources arrive as
  base64 strings.
- `RawEditor.smoothHR` now uses a sliding window to stay O(n).

### Fixed
- `RawEditor.downsampleDistance` keeps the final point even on short hops or
  duplicate timestamps, preserving distance/duration and channel alignment.
- `RawEditor.markLapsByDistance` recovers from non-monotonic distance channels
  (e.g. pause resets) to keep splits accurate.
- `RawEditor.smoothHR` respects even-numbered windows instead of averaging an
  extra sample.
- Format detection inspects only a small prefix and honors payload caps.
- Exports with `normalize: false` auto-sort/dedup when needed; `recomputeDistanceAndSpeed`
  also self-sorts to avoid invalid speed/distance.
- `RawEditor.sortAndDedup` clones lists before sorting to keep prior
  `RawActivity` instances immutable.
- Malformed GPX/TCX and invalid FIT binaries now return structured
  `ParseDiagnostic` errors instead of raw exceptions.
- Stream parsing (`parseStream`, `convertAndExportStream`, `runPipeline` with
  streams) returns diagnostics for malformed/oversized payloads instead of
  throwing.
- CLI `convert` honors explicit `--encoding`, reads GPX/TCX as bytes to avoid
  Latin-1 corruption, and exits non-zero on parser errors.
- `ActivityFiles.runPipeline` no longer runs validation twice when
  `runValidation` is enabled.
- `RawActivity.copyWith` keeps collections immutable, recognizes canonical
  inputs to avoid clones, and reuses cached distances.
- `RawTransforms.resample` sorts points before resampling to avoid RangeErrors
  and keep start/end ordering.
- `ActivityFiles.convert` enforces the export ordering guard when
  `normalize` is `false`; `detectFormat` no longer probes filesystem paths
  unless allowed.


## 0.3.2
### Fixed
- wrong version in pubspec.yaml

## 0.3.1

### Fixed
- `ActivityFiles.load`/`convert` now honor the `encoding` parameter for GPX/TCX
  byte payloads (without BOMs), so Latin-1 and other single-byte exports no
  longer throw `FormatException`.
- `ActivityParser.parseBytes` exposes an `encoding` argument for callers that
  read non-UTF-8 text files directly into byte buffers.

## 0.3.0

### Added
- `ActivityFiles.export` produces encoded payloads with optional validation, normalization, and aggregated diagnostics in a single helper.
- `ActivityFiles.convertAndExport` exposes the same workflow directly from raw sources, including optional validation.
- `ActivityFiles.exportAsync` and `convertAndExportStream` mirror the export workflow off the UI thread and for streamed payloads.
- `ActivityExportRequest` and `ActivityFiles.runPipeline` let callers describe parse → normalize → export pipelines with consistent isolate controls.
- Diagnostic summary getters (`warningCount`, `hasErrors`,
  `diagnosticsSummary`, etc.) are now available on load, conversion, and export results to simplify UI surfacing.
- `ActivityProcessingStats` and `NormalizationStats` capture normalization and validation metrics alongside export diagnostics.
- Facade convenience wrappers expose common transforms (`sortAndDedup`,
  `trimInvalid`, `smoothHeartRate`, `crop`), structural validation, and channel snapshots.
- `RawActivity` and `RawActivityBuilder` gained device metadata and namespace aware GPX extension support, enabling richer encoder output without custom glue.
- `DiagnosticsFormatter` provides reusable helpers for summarising `ParseDiagnostic` collections across logs and UI surfaces.
- Stream-aware builder/export helpers (`builderFromStreams`,
  `convertAndExport` with `location`/`channels`) accept timestamp/value tuples
  so backends can export without manual model translation.
- `ActivityFiles.registerSportMapper` supplies pluggable sport inference and
  ships string/ID heuristics for common wearable categories.
- GPX encoders honour builder-supplied metadata/track names and expose helper
  factories (`gpxActivityLabelNode`, `gpxDeviceSummaryNode`) for custom
  extensions with automatic namespace registration.

### Changed
- GPX encoder now emits device metadata and custom extensions, automatically declaring any additional namespaces used.
- TCX encoder/parser preserve device metadata and custom extensions, and FIT files now round-trip device metadata, including explicit manufacturer/product identifiers supplied via `ActivityDeviceMetadata`.
- `ActivityFiles.convert` and `convertAndExport` now accept `exportInIsolate`, bringing isolate offloading parity while ensuring FIT byte caches refresh when the encoded payload changes.

### Fixed
- `RawEditor.markLapsByDistance` now reports per-split distances correctly and
  always emits a trailing partial lap when applicable, ensuring summary totals
  stay accurate.
- `RawEditor.downsampleTime` keeps the final point in the activity and performs
  sample matching without quadratic scans, avoiding data loss on closely spaced
  tracks.
- Channel deduplication retains the most recent sample when multiple readings
  share the same timestamp instead of discarding later values.
- `ActivityFiles.channelSnapshot` now uses binary search when resolving channel
  samples, reducing lookup cost from O(n) to O(log n) for large time-series
  streams.

## 0.2.0

### Added
- Asynchronous parsing surface: `ActivityParser.parseAsync`,
  `parseBytesAsync`, and `parseStream` optionally offload work to isolates for
  smoother UIs and streaming IO.
- `ActivityFiles` facade providing ergonomic `load`, `convert`, and `edit`
  helpers tailored for app integrations.
- `RawActivityBuilder` for incremental creation of activities.
- Asset-backed integration tests cover `ActivityFiles.load`, `detectFormat`,
  and conversion flows with real GPX/TCX/FIT fixtures.

### Changed
- GPX, TCX, and FIT parsers emit structured diagnostics instead of raw strings.
- Converter, CLI, documentation, examples, and tests now surface diagnostics in
  output flows.
- README/example now highlight the high-level facade and builder workflows.
- Added facade-focused regression tests covering format detection and builder
  seeding.

### Deprecated
- `ActivityParseResult.warnings` remains available but now forwards to the new
  structured diagnostics; it is marked deprecated to encourage migration.
- `ActivityConverter.convert` still accepts the `warnings` parameter, which is
  deprecated in favor of the richer `diagnostics` sink.

## 0.1.2

### Fixed
- pub.dev score fix.

## 0.1.1

### Fixed
- Fix README.

## 0.1.0

### Added
- Handle FIT compressed timestamp headers and ensure unknown message types
  advance the reader instead of hanging.
- Add `ActivityParser.parseBytes`, broaden `ActivityConverter.convert` input
  support, and let the CLI operate on raw FIT binaries without manual base64.
- Document the new FIT workflow and add regression coverage for compressed
  headers.

## 0.0.2

### Added
- Add `example/main.dart` illustrating a minimal GPX round-trip.

### Changed
- Upgrade dependencies and SDK.

## 0.0.1

### Added
- Initial release of `activity_files` with GPX/TCX parsing, editing, validation,
  and encoding utilities plus a conversion/validation CLI scaffold.
