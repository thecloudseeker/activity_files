// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';

/// Severity associated with a parsing diagnostic.
enum ParseSeverity { info, warning, error }

/// Identifies the node or logical entity that triggered a diagnostic.
class ParseNodeReference {
  const ParseNodeReference({required this.path, this.index, this.description});

  /// Hierarchical path such as `gpx.trk.trkseg.trkpt`.
  final String path;

  /// Optional zero-based positional index among siblings.
  final int? index;

  /// Human-friendly context (e.g. timestamp or attribute excerpt).
  final String? description;

  /// Generates a compact identifier for logging/debugging.
  String format() {
    final buffer = StringBuffer(path);
    if (index != null) {
      buffer.write('[$index]');
    }
    if (description != null && description!.isNotEmpty) {
      buffer.write(' ($description)');
    }
    return buffer.toString();
  }
}

/// Structured diagnostic emitted while parsing an activity file.
class ParseDiagnostic {
  const ParseDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.node,
  });

  /// Severity for filtering or highlighting issues.
  final ParseSeverity severity;

  /// Stable identifier for the diagnostic (e.g. `gpx.missing_coordinates`).
  final String code;

  /// Human-readable explanation of the issue.
  final String message;

  /// Optional node reference providing additional context.
  final ParseNodeReference? node;
}

/// Utility for formatting and aggregating diagnostics.
class DiagnosticsFormatter {
  DiagnosticsFormatter(Iterable<ParseDiagnostic> diagnostics)
    : diagnostics = diagnostics.toList(growable: false);

  /// Diagnostics being formatted.
  final List<ParseDiagnostic> diagnostics;

  /// Whether any diagnostics were recorded.
  bool get hasDiagnostics => diagnostics.isNotEmpty;

  /// Number of diagnostics with [ParseSeverity.info].
  int get infoCount => count(ParseSeverity.info);

  /// Number of diagnostics with [ParseSeverity.warning].
  int get warningCount => count(ParseSeverity.warning);

  /// Number of diagnostics with [ParseSeverity.error].
  int get errorCount => count(ParseSeverity.error);

  /// Whether any warning-level diagnostics were recorded.
  bool get hasWarnings => warningCount > 0;

  /// Whether any error-level diagnostics were recorded.
  bool get hasErrors => errorCount > 0;

  /// Counts diagnostics that match [severity].
  int count(ParseSeverity severity) {
    var total = 0;
    for (final diagnostic in diagnostics) {
      if (diagnostic.severity == severity) {
        total++;
      }
    }
    return total;
  }

  /// Returns a filtered iterable containing only diagnostics of [severity].
  Iterable<ParseDiagnostic> whereSeverity(ParseSeverity severity) sync* {
    for (final diagnostic in diagnostics) {
      if (diagnostic.severity == severity) {
        yield diagnostic;
      }
    }
  }

  /// Formats diagnostics into a readable string for logging or UI badges.
  String summary({
    ParseSeverity minSeverity = ParseSeverity.warning,
    bool includeSeverity = true,
    bool includeCodes = true,
    bool includeNode = false,
    String separator = '\n',
  }) {
    final buffer = StringBuffer();
    var first = true;
    for (final diagnostic in diagnostics) {
      if (diagnostic.severity.index < minSeverity.index) {
        continue;
      }
      if (!first) {
        buffer.write(separator);
      }
      first = false;
      if (includeSeverity) {
        buffer.write('${diagnostic.severity.name.toUpperCase()}: ');
      }
      if (includeCodes && diagnostic.code.isNotEmpty) {
        buffer.write('[${diagnostic.code}] ');
      }
      buffer.write(diagnostic.message);
      if (includeNode && diagnostic.node != null) {
        buffer.write(' (${diagnostic.node!.format()})');
      }
    }
    return buffer.toString();
  }
}

const String _legacyWarningCode = 'legacy.warning';

/// Result of parsing an activity file, including structured diagnostics.
class ActivityParseResult {
  ActivityParseResult({
    required this.activity,
    Iterable<ParseDiagnostic>? diagnostics,
    @Deprecated('Use diagnostics instead.') Iterable<String>? warnings,
  }) : diagnostics = List.unmodifiable(
         _mergeDiagnostics(diagnostics, warnings),
       ),
       _warningMessages = List.unmodifiable(
         _collectWarningMessages(diagnostics, warnings),
       );

  /// The reconstructed activity.
  final RawActivity activity;

  /// Diagnostics encountered during parsing. Errors are still non-fatal.
  final List<ParseDiagnostic> diagnostics;

  final List<String> _warningMessages;

  /// Legacy view exposing warning messages only. Prefer [diagnostics].
  @Deprecated('Use diagnostics for structured parser output.')
  List<String> get warnings => _warningMessages;

  /// Convenience view of warning-level diagnostics.
  Iterable<ParseDiagnostic> get warningDiagnostics sync* {
    for (final diagnostic in diagnostics) {
      if (diagnostic.severity == ParseSeverity.warning) {
        yield diagnostic;
      }
    }
  }
}

List<ParseDiagnostic> _mergeDiagnostics(
  Iterable<ParseDiagnostic>? diagnostics,
  Iterable<String>? warnings,
) {
  final merged = <ParseDiagnostic>[];
  if (diagnostics != null) {
    merged.addAll(diagnostics);
  }
  if (warnings != null) {
    merged.addAll(
      warnings.map(
        (message) => ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: _legacyWarningCode,
          message: message,
        ),
      ),
    );
  }
  return merged;
}

List<String> _collectWarningMessages(
  Iterable<ParseDiagnostic>? diagnostics,
  Iterable<String>? warnings,
) {
  final messages = <String>[];
  if (diagnostics != null) {
    for (final diagnostic in diagnostics) {
      if (diagnostic.severity == ParseSeverity.warning) {
        messages.add(diagnostic.message);
      }
    }
  }
  if (warnings != null) {
    messages.addAll(warnings);
  }
  return messages;
}
