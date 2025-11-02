# Changelog

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
