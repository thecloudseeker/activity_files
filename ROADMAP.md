# Activity Files - Roadmap

## v0.5.5

TODO(0.5.5)(fit): Replace static local->definition snapshots with definition timelines so local redefinitions decode against the active schema at each message offset. [lib/src/parse/fit_parser.dart:113]

TODO(0.5.5)(fit): Apply in-stream definition updates in pass 2 (do not freeze to pass1) to support files that redefine record locals many times. [lib/src/parse/fit_parser.dart:267]

TODO(0.5.5)(fit): Add bounded timestamp recovery fallback (compressed offset/history) before dropping records from valid containers with variant layouts. [lib/src/parse/fit_parser.dart:416]

TODO(0.5.5)(determinism): Avoid DateTime.now() fallback for missing timestamps. [lib/src/parse/geojson_parser.dart:253]

TODO(0.5.5)(perf): Limit or scope XML lookup caches to avoid retaining parsed documents. [lib/src/parse/tcx_parser.dart:14]

TODO(0.5.5)(refactor): Reuse shared lap boundary logic from RawEditor. [lib/src/validation.dart:27]

TODO(0.5.5)(refactor): Share lap boundary checks with validateRawActivity(). [lib/src/transforms/raw_editor.dart:461]

## v0.6.0

TODO(0.6.0): Configurable handling of corrupted FIT files. [lib/src/api/activity_files_facade.dart:36]

TODO(0.6.0): Auto-fix common data issues (gaps, drift, invalid GPS). [lib/src/api/activity_files_facade.dart:37]

TODO(0.6.0): Test suite for malformed files. [lib/src/api/activity_files_facade.dart:38]

TODO(0.6.0): Channel lookup optimization (cursor indexing, distance lookup, reduce payload copying) — tracked centrally at ActivityFiles header; local hotspot here. [lib/src/api/activity_files_facade.dart:252, 1408, 2183, 2225]

TODO(0.6.0): Validation auto-corrections (timestamp gaps, sensor drift, invalid coordinates). [lib/src/validation.dart:4]

TODO(0.6.0): Actionable error messages with recovery suggestions and warning prioritization. [lib/src/validation.dart:5]

TODO(0.6.0): Validate device metadata and handle edge cases in channel mappings. [lib/src/models.dart:491]

TODO(0.6.0): Channel mapping validation and edge case handling. [lib/src/transforms/raw_transforms.dart:16, lib/src/transforms/raw_editor.dart:80]

## v0.7.0

TODO(0.7.0): Faster file parsing for csv and geojson. [lib/src/api/activity_files_facade.dart:41]

TODO(0.7.0): Batch import with progress tracking and error recovery. [lib/src/api/activity_files_facade.dart:42]

TODO(0.7.0): Repair tools for malformed files. [lib/src/api/activity_files_facade.dart:43]

TODO(0.7.0): Full GPX/TCX round-trip preservation (no data loss). [lib/src/api/activity_files_facade.dart:44]

TODO(0.7.0): Async/streamed iterables for large file handling. [lib/src/api/activity_files_facade.dart:350]

TODO(0.7.0): GPX: Implement round-trip preservation for waypoints/routes/metadata and multiple tracks. [lib/src/parse/gpx_parser.dart:9]

TODO(0.7.0): TCX: Support courses, workouts, and extensions round-trip. [lib/src/parse/tcx_parser.dart:13]

TODO(0.7.0)(feature): Handle developer fields and broader Garmin SDK profile coverage. [lib/src/parse/fit_parser.dart:11]

TODO(0.7.0)(feature): Decode developer fields for known metrics [lib/src/parse/fit_parser.dart:899]

TODO(0.7.0)(feature): Allow selecting FIT protocol/profile version when broader profile coverage is implemented. [lib/src/encode/fit_encoder.dart:12]

TODO(0.7.0): GPX round-trip preservation - waypoints, routes, metadata, and multiple tracks (no data loss). [lib/src/encode/gpx_encoder.dart:10]

TODO(0.7.0): TCX round-trip preservation - courses, workouts, waypoints, and extensions (no data loss). [lib/src/encode/tcx_encoder.dart:12]

## v0.8.0

TODO(0.8.0): Route/segment matching. [lib/src/api/activity_files_facade.dart:47]

TODO(0.8.0): Merge multiple activities. [lib/src/api/activity_files_facade.dart:48]

TODO(0.8.0): Power zone analysis (FTP, time-in-zone). [lib/src/api/activity_files_facade.dart:49]

TODO(0.8.0): Heart rate zone analysis (LTHR, zones). [lib/src/api/activity_files_facade.dart:50]

TODO(0.8.0): Comprehensive analytics suite (power/HR zones, threshold analysis, HRV, segment detection, elevation analysis, outlier detection, track simplification, privacy zones). [lib/src/transforms/raw_editor.dart:11]

## v0.9.0

TODO(0.9.0): Advanced threshold detection (FTP, LTHR, critical power). [lib/src/api/activity_files_facade.dart:53]

TODO(0.9.0): HRV metrics for recovery tracking. [lib/src/api/activity_files_facade.dart:54]

TODO(0.9.0): Automatic segment detection (climbs, intervals, rest). [lib/src/api/activity_files_facade.dart:55]

TODO(0.9.0): Detect and flag bad data (GPS errors, sensor spikes). [lib/src/api/activity_files_facade.dart:56]
