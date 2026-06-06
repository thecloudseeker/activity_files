// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';

/// Demo: Smart Integrity Handling for Damaged Activity Files
///
/// This example shows how the new IntegrityMode system allows flexible
/// handling of corrupted or partially damaged activity files.
Future<void> main() async {
  await _demoReportMode();
  await _demoSilentMode();
  await _demoIntegrityStats();
}

/// Report Mode: Log issues, continue parsing (default for user uploads)
Future<void> _demoReportMode() async {
  print('═══ REPORT MODE: Collect Diagnostics ═══');
  print('');

  // Parse with diagnostic collection enabled
  final fitParser = FitParser();

  // Simulated corrupted file for demo
  final corruptedBytes = _buildCorruptedSample();

  final result = fitParser.parseBytesWithIntegrity(
    corruptedBytes,
    integrityConfig: const IntegrityConfig.report(collectStats: true),
  );

  // Always check diagnostics in report mode
  if (result.diagnostics.isNotEmpty) {
    print('⚠ File has integrity issues:');
    for (final diag in result.diagnostics) {
      if (diag.severity == ParseSeverity.error) {
        print('  • ${diag.code}: ${diag.message}');
      }
    }
    print('');
  }

  // But we got data despite the issues
  print('✓ Partial data recovered:');
  print('  Points: ${result.activity.points.length}');
  print('  Channels: ${result.activity.channels.length}');
  print('');

  // New: Integrity statistics
  if (result.integrityStats != null) {
    print('Integrity Statistics:');
    print('  ${result.integrityStats!.summary()}');
  }
  print('');
}

/// Silent Mode: Best-effort recovery, ignore all issues
Future<void> _demoSilentMode() async {
  print('═══ SILENT MODE: Best-Effort Recovery ═══');
  print('');

  // For heavily damaged files where any data is valuable
  final fitParser = FitParser();
  final corruptedBytes = _buildCorruptedSample();

  final result = fitParser.parseBytesWithIntegrity(
    corruptedBytes,
    integrityConfig: const IntegrityConfig.silent(),
  );

  print('✓ Recovered data in silent mode:');
  print('  Points: ${result.activity.points.length}');
  print('  Mode: ${result.integrityMode.name}');
  print('  No diagnostics logged');
  print('');
}

/// Full Statistics Tracking
Future<void> _demoIntegrityStats() async {
  print('═══ INTEGRITY STATISTICS ═══');
  print('');

  // Create sample stats showing what can be tracked
  final stats = IntegrityStats(
    crcMismatches: 3,
    headerCrcMismatches: 1,
    trailerCrcMismatches: 1,
    truncatedSections: 2,
    invalidMessages: 5,
    recoveryAttempts: 8,
    formatSpecificIssues: {
      'fit.developer_fields_skipped': 2,
      'fit.unknown_message_types': 3,
    },
  );

  print('Tracked Issues:');
  print('  CRC Mismatches: ${stats.crcMismatches}');
  print('    - Header: ${stats.headerCrcMismatches}');
  print('    - Trailer: ${stats.trailerCrcMismatches}');
  print('  Truncated sections: ${stats.truncatedSections}');
  print('  Invalid messages: ${stats.invalidMessages}');
  print('  Recovery attempts: ${stats.recoveryAttempts}');
  print('');

  print('Formatted Summary:');
  print(stats.summary());
  print('');
}

/// Helper: Build corrupted FIT sample for testing
Uint8List _buildCorruptedSample() {
  // Minimal valid FIT header with corrupted CRC
  final header = Uint8List(14);
  final bd = ByteData.view(header.buffer);
  header[0] = 14;
  header[1] = 0x10;
  bd.setUint16(2, 0, Endian.little);
  bd.setUint32(4, 4, Endian.little);
  header.setRange(8, 12, '.FIT'.codeUnits);
  // Corrupt CRC
  header[12] = 0xFF;
  header[13] = 0xFF;

  // Minimal data
  final data = Uint8List.fromList([0x40, 0x00, 0x00, 0x14, 0x00, 0x00]);

  return Uint8List.fromList([...header, ...data, 0x00, 0x00]);
}
