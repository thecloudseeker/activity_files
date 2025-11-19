# Changelog

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

- pub.dev score fix.

## 0.1.1

- Fix README.

## 0.1.0

- Handle FIT compressed timestamp headers and ensure unknown message types
  advance the reader instead of hanging.
- Add `ActivityParser.parseBytes`, broaden `ActivityConverter.convert` input
  support, and let the CLI operate on raw FIT binaries without manual base64.
- Document the new FIT workflow and add regression coverage for compressed
  headers.

## 0.0.2

- Upgrade dependencies and SDK.
- Add `example/main.dart` illustrating a minimal GPX round-trip.

## 0.0.1

- Initial release of `activity_files` with GPX/TCX parsing, editing, validation,
  and encoding utilities plus a conversion/validation CLI scaffold.
