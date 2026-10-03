// SPDX-License-Identifier: BSD-3-Clause
part of '../activity_files_facade.dart';

// Internal description of one export pipeline run, consumed by _runPipeline.
// The facade's own entry points build this directly; the public
// ActivityExportRequest converts into it at its single call site.
class _ExportRequest {
  _ExportRequest._({
    this.activity,
    this.source,
    this.stream,
    required this.to,
    this.from,
    required this.options,
    required this.normalize,
    required this.runValidation,
    required this.parseInIsolate,
    required this.exportInIsolate,
    required this.encoding,
    required this.allowFilePaths,
    required this.strictFitIntegrity,
    required this.fitCorruptionHandling,
    required this.autoFix,
    required Iterable<ParseDiagnostic> diagnostics,
    this.validation,
    this.maxPayloadBytes,
  }) : diagnostics = List<ParseDiagnostic>.unmodifiable(diagnostics);

  // Skips parsing and exports an already-parsed activity.
  factory _ExportRequest.fromActivity({
    required RawActivity activity,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool runValidation = true,
    bool exportInIsolate = false,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
    ValidationResult? validation,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
  }) => _ExportRequest._(
    activity: activity,
    to: to,
    options: options,
    normalize: normalize,
    runValidation: runValidation,
    parseInIsolate: false,
    exportInIsolate: exportInIsolate,
    encoding: utf8,
    allowFilePaths: false,
    strictFitIntegrity: strictFitIntegrity,
    fitCorruptionHandling: fitCorruptionHandling,
    autoFix: autoFix,
    diagnostics: diagnostics,
    validation: validation,
    maxPayloadBytes: null,
  );

  // Parses a file/path/byte source before exporting.
  factory _ExportRequest.fromSource({
    required Object source,
    required ActivityFileFormat? from,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool runValidation = false,
    bool parseInIsolate = true,
    bool exportInIsolate = false,
    Encoding encoding = utf8,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
    bool allowFilePaths = false,
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) => _ExportRequest._(
    source: source,
    from: from,
    to: to,
    options: options,
    normalize: normalize,
    runValidation: runValidation,
    parseInIsolate: parseInIsolate,
    exportInIsolate: exportInIsolate,
    encoding: encoding,
    allowFilePaths: allowFilePaths,
    strictFitIntegrity: strictFitIntegrity,
    fitCorruptionHandling: fitCorruptionHandling,
    autoFix: autoFix,
    diagnostics: diagnostics,
    validation: null,
    maxPayloadBytes: maxPayloadBytes,
  );

  // Buffers a byte stream before parsing and exporting.
  factory _ExportRequest.fromStream({
    required Stream<List<int>> stream,
    required ActivityFileFormat from,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool runValidation = false,
    bool parseInIsolate = true,
    bool exportInIsolate = false,
    Encoding encoding = utf8,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
    bool strictFitIntegrity = false,
    FitCorruptionHandling fitCorruptionHandling =
        FitCorruptionHandling.bestEffort,
    ActivityAutoFixOptions autoFix = const ActivityAutoFixOptions.disabled(),
    int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
  }) => _ExportRequest._(
    stream: stream,
    from: from,
    to: to,
    options: options,
    normalize: normalize,
    runValidation: runValidation,
    parseInIsolate: parseInIsolate,
    exportInIsolate: exportInIsolate,
    encoding: encoding,
    allowFilePaths: false,
    strictFitIntegrity: strictFitIntegrity,
    fitCorruptionHandling: fitCorruptionHandling,
    autoFix: autoFix,
    diagnostics: diagnostics,
    validation: null,
    maxPayloadBytes: maxPayloadBytes,
  );

  final RawActivity? activity;
  final Object? source;
  final Stream<List<int>>? stream;
  final ActivityFileFormat? from;
  final ActivityFileFormat to;
  final EncoderOptions options;
  final bool normalize;
  final bool runValidation;
  final bool parseInIsolate;
  final bool exportInIsolate;
  final Encoding encoding;
  final bool allowFilePaths;
  final bool strictFitIntegrity;
  final FitCorruptionHandling fitCorruptionHandling;
  final ActivityAutoFixOptions autoFix;
  final int? maxPayloadBytes;
  final List<ParseDiagnostic> diagnostics;
  final ValidationResult? validation;
}
