part of '../activity_files_facade.dart';

Map<String, Object?> _encodeExportResult(ActivityExportResult result) => {
  'activity': ExportSerialization.activityToJson(result.activity),
  'targetFormat': result.targetFormat.index,
  'options': ExportSerialization.encoderOptionsToJson(result.encoderOptions),
  'encoded': result.encoded,
  'binary': result.isBinary ? result.asBytes() : null,
  'diagnostics': result.diagnostics
      .map(ExportSerialization.diagnosticToJson)
      .toList(growable: false),
  'validation': result.validation == null
      ? null
      : ExportSerialization.validationToJson(result.validation!),
  'processing': ExportSerialization.processingStatsToJson(
    result.processingStats,
  ),
};

ActivityExportResult _decodeExportResult(Map<String, Object?> data) {
  final validation = data['validation'] is Map
      ? ExportSerialization.validationFromJson(
          (data['validation'] as Map).cast<String, Object?>(),
        )
      : null;
  final diagnostics = (data['diagnostics'] as List<dynamic>)
      .map<ParseDiagnostic>(
        (entry) => ExportSerialization.diagnosticFromJson(
          (entry as Map).cast<String, Object?>(),
        ),
      )
      .toList(growable: false);
  final binaryRaw = data['binary'];
  Uint8List? binary;
  if (binaryRaw is Uint8List) {
    binary = Uint8List.fromList(binaryRaw);
  } else if (binaryRaw is List<dynamic>) {
    binary = Uint8List.fromList(binaryRaw.cast<int>());
  }
  return ActivityExportResult._(
    activity: ExportSerialization.activityFromJson(
      (data['activity'] as Map).cast<String, Object?>(),
    ),
    targetFormat: ActivityFileFormat.values[data['targetFormat'] as int],
    encoderOptions: ExportSerialization.encoderOptionsFromJson(
      (data['options'] as Map).cast<String, Object?>(),
    ),
    encoded: data['encoded'] as String,
    binary: binary,
    diagnostics: diagnostics,
    validation: validation,
    processingStats: ExportSerialization.processingStatsFromJson(
      (data['processing'] as Map?)?.cast<String, Object?>(),
    ),
  );
}

List<ParseDiagnostic> _diagnosticsFromValidation(ValidationResult validation) {
  final diagnostics = <ParseDiagnostic>[];
  for (final message in validation.errors) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.error,
        code: 'validation.error',
        message: message,
      ),
    );
  }
  for (final message in validation.warnings) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.warning,
        code: 'validation.warning',
        message: message,
      ),
    );
  }
  return diagnostics;
}

mixin _DiagnosticSummaryMixin {
  List<ParseDiagnostic> get diagnostics;

  DiagnosticsFormatter get _formatter => DiagnosticsFormatter(diagnostics);

  /// Whether diagnostics were recorded.
  bool get hasDiagnostics => _formatter.hasDiagnostics;

  /// Number of info-level diagnostics.
  int get infoCount => _formatter.infoCount;

  /// Number of warning-level diagnostics.
  int get warningCount => _formatter.warningCount;

  /// Number of error-level diagnostics.
  int get errorCount => _formatter.errorCount;

  /// Convenience flag indicating warnings were recorded.
  bool get hasWarnings => _formatter.hasWarnings;

  /// Convenience flag indicating errors were recorded.
  bool get hasErrors => _formatter.hasErrors;

  /// Returns the number of diagnostics matching [severity].
  int countBySeverity(ParseSeverity severity) => _formatter.count(severity);

  /// Formats diagnostics into a single string for quick logging or UI badges.
  String diagnosticsSummary({
    ParseSeverity minSeverity = ParseSeverity.warning,
    bool includeSeverity = true,
    bool includeCodes = true,
    bool includeNode = false,
    String separator = '\n',
  }) => _formatter.summary(
    minSeverity: minSeverity,
    includeSeverity: includeSeverity,
    includeCodes: includeCodes,
    includeNode: includeNode,
    separator: separator,
  );
}

/// Deprecated name for [ActivityImportResult], kept as an alias so existing
/// variable declarations and signatures keep compiling. Renamed alongside
/// `load` -> `import` so the result type matches the verb that returns it.
@Deprecated('Use ActivityImportResult instead. Will be removed in 0.10.0.')
typedef ActivityLoadResult = ActivityImportResult;

/// Result of [ActivityFiles.import].
class ActivityImportResult with _DiagnosticSummaryMixin {
  ActivityImportResult._({
    required this.activity,
    required Iterable<ParseDiagnostic> diagnostics,
    required this.format,
    required this.sourceDescription,
    required this.payload,
  }) : diagnostics = List.unmodifiable(diagnostics);

  /// Parsed activity.
  ///
  /// Parse or validation failures never throw; they are recorded in
  /// [diagnostics]. Inspect [hasErrors], [diagnostics], or
  /// [diagnosticsSummary] before trusting [activity].
  final RawActivity activity;

  @override
  final List<ParseDiagnostic> diagnostics;

  /// Detected format of the payload.
  final ActivityFileFormat format;

  /// Human-readable description of the source (e.g. file path).
  final String sourceDescription;

  /// Raw payload used during parsing (String or Uint8List).
  final Object payload;

  /// Returns the raw payload as bytes when available.
  Uint8List? get bytesPayload =>
      payload is Uint8List ? payload as Uint8List : null;

  /// Returns the raw payload as text when available.
  String? get stringPayload => payload is String ? payload as String : null;
}

/// Encoded export bundle returned by [ActivityFiles.export].
class ActivityExportResult with _DiagnosticSummaryMixin {
  ActivityExportResult._({
    required this.activity,
    required this.targetFormat,
    required this.encoderOptions,
    required this.encoded,
    Uint8List? binary,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
    this.validation,
    this.processingStats = const ActivityProcessingStats(),
  }) : _binary = binary != null ? Uint8List.fromList(binary) : null,
       diagnostics = List.unmodifiable(List<ParseDiagnostic>.from(diagnostics));

  /// Normalized activity that was encoded.
  final RawActivity activity;

  /// Target format for the encoded payload.
  final ActivityFileFormat targetFormat;

  /// Encoder options used for the export.
  final EncoderOptions encoderOptions;

  /// Encoder output as a string. FIT payloads are base64 strings.
  final String encoded;

  /// Validation findings emitted during export, if requested.
  final ValidationResult? validation;

  final Uint8List? _binary;

  /// Processing metrics collected during normalization/validation.
  final ActivityProcessingStats processingStats;

  @override
  final List<ParseDiagnostic> diagnostics;

  /// Whether the payload is binary (FIT).
  bool get isBinary => targetFormat == ActivityFileFormat.fit;

  /// Returns the payload as bytes (UTF-8 for text formats).
  Uint8List asBytes({Encoding encoding = utf8}) {
    if (isBinary) {
      return Uint8List.fromList(_binary ?? base64Decode(encoded));
    }
    return Uint8List.fromList(encoding.encode(encoded));
  }

  /// Returns the payload as a string, decoding binary payloads to base64.
  String asString() => encoded;

  /// Clones the export result with overrides.
  ActivityExportResult copyWith({
    RawActivity? activity,
    ActivityFileFormat? targetFormat,
    EncoderOptions? encoderOptions,
    String? encoded,
    Uint8List? binary,
    Iterable<ParseDiagnostic>? diagnostics,
    ValidationResult? validation,
    ActivityProcessingStats? processingStats,
  }) {
    final nextTargetFormat = targetFormat ?? this.targetFormat;
    final encodedProvided = encoded != null;
    final nextEncoded = encoded ?? this.encoded;
    final encodedChanged = encodedProvided && encoded != this.encoded;
    final reuseExistingBinary =
        binary == null &&
        !encodedChanged &&
        nextTargetFormat == this.targetFormat;
    final nextBinary = nextTargetFormat == ActivityFileFormat.fit
        ? (binary ?? (reuseExistingBinary ? _binary : null))
        : null;
    return ActivityExportResult._(
      activity: activity ?? this.activity,
      targetFormat: nextTargetFormat,
      encoderOptions: encoderOptions ?? this.encoderOptions,
      encoded: nextEncoded,
      binary: nextBinary,
      diagnostics: diagnostics ?? this.diagnostics,
      validation: validation ?? this.validation,
      processingStats: processingStats ?? this.processingStats,
    );
  }
}

/// Result of [ActivityFiles.convert].
class ActivityConversionResult extends ActivityExportResult {
  ActivityConversionResult._({
    required this.sourceFormat,
    required super.activity,
    required super.targetFormat,
    required super.encoderOptions,
    required super.encoded,
    super.binary,
    super.diagnostics = const <ParseDiagnostic>[],
    super.validation,
    super.processingStats = const ActivityProcessingStats(),
  }) : super._();

  /// Detected format of the source payload.
  final ActivityFileFormat sourceFormat;

  /// Clones the conversion result with overrides.
  @override
  ActivityConversionResult copyWith({
    RawActivity? activity,
    ActivityFileFormat? sourceFormat,
    ActivityFileFormat? targetFormat,
    EncoderOptions? encoderOptions,
    String? encoded,
    Uint8List? binary,
    Iterable<ParseDiagnostic>? diagnostics,
    ValidationResult? validation,
    ActivityProcessingStats? processingStats,
  }) {
    final nextSourceFormat = sourceFormat ?? this.sourceFormat;
    final nextTargetFormat = targetFormat ?? this.targetFormat;
    final encodedProvided = encoded != null;
    final nextEncoded = encoded ?? this.encoded;
    final encodedChanged = encodedProvided && encoded != this.encoded;
    final reuseExistingBinary =
        binary == null &&
        !encodedChanged &&
        nextTargetFormat == this.targetFormat;
    final nextBinary = nextTargetFormat == ActivityFileFormat.fit
        ? (binary ?? (reuseExistingBinary ? _binary : null))
        : null;
    return ActivityConversionResult._(
      activity: activity ?? this.activity,
      sourceFormat: nextSourceFormat,
      targetFormat: nextTargetFormat,
      encoderOptions: encoderOptions ?? this.encoderOptions,
      encoded: nextEncoded,
      binary: nextBinary,
      diagnostics: diagnostics ?? this.diagnostics,
      validation: validation ?? this.validation,
      processingStats: processingStats ?? this.processingStats,
    );
  }
}

/// Result of [ActivityFiles.importBatch].
class BatchImportResult {
  BatchImportResult({
    required this.successes,
    required this.failures,
    required this.total,
  });

  /// Successfully loaded activities, in input order (skipping failed items).
  final List<ActivityImportResult> successes;

  /// Sources that could not be loaded, in the order failures occurred.
  final List<BatchImportFailure> failures;

  /// Total number of sources that were attempted.
  final int total;

  /// Number of successfully loaded activities.
  int get successCount => successes.length;

  /// Number of sources that failed to load.
  int get failureCount => failures.length;

  /// Whether all sources were loaded without errors.
  bool get allSucceeded => failures.isEmpty;
}

/// A single failure entry from [ActivityFiles.importBatch].
class BatchImportFailure {
  BatchImportFailure({
    required this.source,
    required this.error,
    this.stackTrace,
  });

  /// The source that failed (e.g. a [File] or [Uint8List]).
  final Object source;

  /// The error that was thrown.
  final Object error;

  /// Stack trace from the thrown error, if available.
  final StackTrace? stackTrace;

  @override
  String toString() => 'BatchImportFailure(source: $source, error: $error)';
}
