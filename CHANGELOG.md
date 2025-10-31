## 0.1.0

* Handle FIT compressed timestamp headers and ensure unknown message types
  advance the reader instead of hanging.
* Add `ActivityParser.parseBytes`, broaden `ActivityConverter.convert` input
  support, and let the CLI operate on raw FIT binaries without manual base64.
* Document the new FIT workflow and add regression coverage for compressed
  headers.

## 0.0.2

* Upgrade dependencies and sdk
* Add `example/basic_usage.dart` illustrating a minimal GPX round-trip.

## 0.0.1

* Initial release of `activity_files` with GPX/TCX parsing, editing, validation,
  and encoding utilities plus a conversion/validation CLI scaffold.
