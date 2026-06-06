// SPDX-License-Identifier: BSD-3-Clause

/// Integrity validation strategy for parsing activity files.
///
/// Defines how parsers should handle integrity issues (CRC mismatches,
/// truncated files, invalid structure) across all formats.
enum IntegrityMode {
  /// Fail-fast mode: throws FormatException on ANY integrity issue.
  /// Use for trusted/production data where 100% compliance is mandatory.
  strict,

  /// Diagnostic mode (default): logs issues but continues parsing.
  /// Use for user uploads or potentially damaged files.
  /// Returns best-effort data with detailed diagnostics.
  report,

  /// Silent mode: ignores all integrity issues.
  /// Use for best-effort recovery from heavily damaged files.
  /// Note: May produce incorrect/incomplete data.
  silent,
}

/// Integrity validation configuration for parsers.
class IntegrityConfig {
  const IntegrityConfig({
    this.mode = IntegrityMode.report,
    this.collectStats = true,
  });

  /// Strategy for handling integrity issues.
  final IntegrityMode mode;

  /// Whether to collect and expose integrity statistics.
  ///
  /// When true, parsers will track:
  /// - CRC mismatches (count, hex values)
  /// - Truncated sections
  /// - Invalid message counts
  /// - Recovery attempts
  final bool collectStats;

  /// Creates a strict integrity config (fail-fast).
  const IntegrityConfig.strict()
    : mode = IntegrityMode.strict,
      collectStats = false;

  /// Creates a reporting integrity config (log issues).
  const IntegrityConfig.report({this.collectStats = true})
    : mode = IntegrityMode.report;

  /// Creates a silent integrity config (best-effort).
  const IntegrityConfig.silent()
    : mode = IntegrityMode.silent,
      collectStats = false;
}

/// Statistics about integrity issues encountered during parsing.
class IntegrityStats {
  IntegrityStats({
    this.crcMismatches = 0,
    this.truncatedSections = 0,
    this.invalidMessages = 0,
    this.recoveryAttempts = 0,
    this.headerCrcMismatches = 0,
    this.trailerCrcMismatches = 0,
    Map<String, int>? formatSpecificIssues,
  }) : formatSpecificIssues = formatSpecificIssues ?? {};

  /// Total CRC mismatches detected.
  int crcMismatches;

  /// Count of header-specific CRC mismatches (FIT).
  int headerCrcMismatches;

  /// Count of trailer-specific CRC mismatches (FIT).
  int trailerCrcMismatches;

  /// Sections that were truncated or incomplete.
  int truncatedSections;

  /// Messages/records that couldn't be parsed.
  int invalidMessages;

  /// Attempted recoveries from errors.
  int recoveryAttempts;

  /// Format-specific issues (e.g., "fit.developer_fields_skipped").
  final Map<String, int> formatSpecificIssues;

  /// Whether any integrity issues were detected.
  bool get hasIssues =>
      crcMismatches > 0 ||
      truncatedSections > 0 ||
      invalidMessages > 0 ||
      recoveryAttempts > 0 ||
      formatSpecificIssues.isNotEmpty;

  /// Friendly summary of issues.
  String summary() {
    final parts = <String>[];
    if (crcMismatches > 0) {
      parts.add('$crcMismatches CRC mismatches');
      if (headerCrcMismatches > 0 || trailerCrcMismatches > 0) {
        final details = <String>[];
        if (headerCrcMismatches > 0) details.add('$headerCrcMismatches header');
        if (trailerCrcMismatches > 0) {
          details.add('$trailerCrcMismatches trailer');
        }
        parts.add('(${details.join(', ')})');
      }
    }
    if (truncatedSections > 0) {
      parts.add('$truncatedSections truncated sections');
    }
    if (invalidMessages > 0) parts.add('$invalidMessages invalid messages');
    if (recoveryAttempts > 0) parts.add('$recoveryAttempts recovery attempts');

    for (final entry in formatSpecificIssues.entries) {
      parts.add('${entry.value} ${entry.key}');
    }

    return parts.isEmpty ? 'No issues detected' : parts.join('; ');
  }
}
