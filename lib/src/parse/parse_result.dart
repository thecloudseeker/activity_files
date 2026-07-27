// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';
import 'integrity_mode.dart';

/// Severity associated with a parsing diagnostic.
enum ParseSeverity { info, warning, error }

/// Canonical category names used in diagnostic codes.
///
/// Two code shapes exist:
///
/// - **Parser diagnostics** are structured `<format>.<area>.<detail>`, where
///   `<area>` names the part of the file that triggered the issue (e.g.
///   `fit.header.crc_mismatch`, `fit.trailer.truncated`,
///   `gpx.parse.malformed`). The `<area>` segment is format-specific and is
///   not drawn from these constants.
/// - **Validation and pipeline diagnostics** lead with a category from this
///   class: `validation.laps.overlap`, `repaired.sentinel_coords_removed`,
///   `lossy.multi_track_flattened`.
///
/// To route diagnostics, match on the leading segment for validation and
/// pipeline codes, and on the `<format>` prefix (plus specific full codes
/// where needed) for parser diagnostics. Codes are stable strings, so
/// matching on full codes is always safe.
abstract class DiagnosticCategory {
  /// Structural parse failures (malformed syntax, missing required elements).
  static const String parse = 'parse';

  /// Data loss caused by conversion or normalization (e.g. multi-track
  /// structure flattened for a single-track target format).
  static const String lossy = 'lossy';

  /// Automatic repairs applied to recover usable data
  /// (e.g. `repaired.sentinel_coords_removed`).
  static const String repaired = 'repaired';

  /// Semantic validation findings produced by `validateRawActivity` and
  /// related checks (e.g. `validation.laps.overlap`).
  static const String validation = 'validation';
}

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
    this.suggestedFix,
    this.priority,
  });

  /// Severity for filtering or highlighting issues.
  final ParseSeverity severity;

  /// Stable identifier for the diagnostic (e.g. `gpx.missing_coordinates`).
  final String code;

  /// Human-readable explanation of the issue.
  final String message;

  /// Optional node reference providing additional context.
  final ParseNodeReference? node;

  /// Human-readable suggestion for how to resolve this issue.
  ///
  /// When present, UIs can display this as a "one-click fix" label or
  /// next-step guidance.  Null when no actionable recovery is known.
  final String? suggestedFix;

  /// Relative priority among diagnostics of the same severity (lower = more
  /// important).  Null when relative ordering is not applicable.
  final int? priority;
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
    bool includeSuggestedFix = false,
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
      if (includeSuggestedFix && diagnostic.suggestedFix != null) {
        buffer.write(' → ${diagnostic.suggestedFix}');
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
    this.integrityStats,
    this.integrityMode = IntegrityMode.report,
  }) : diagnostics = List.unmodifiable(
         _mergeDiagnostics(diagnostics, warnings),
       ),
       _warningMessages = List.unmodifiable(
         _collectWarningMessages(diagnostics, warnings),
       );

  /// The reconstructed activity.
  final RawActivity activity;

  /// Integrity issues encountered during parsing (if stats collection was enabled).
  ///
  /// This is only populated when [IntegrityConfig.collectStats] is true.
  /// Use this to understand what kind of data issues were found and how many
  /// recovery attempts were made.
  final IntegrityStats? integrityStats;

  /// The integrity validation mode that was used for parsing.
  ///
  /// * [IntegrityMode.strict]: Parsing would have failed on first error
  /// * [IntegrityMode.report]: Issues logged but parsing continued (default)
  /// * [IntegrityMode.silent]: All issues silently ignored
  final IntegrityMode integrityMode;

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
