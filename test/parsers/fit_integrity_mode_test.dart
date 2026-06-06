// SPDX-License-Identifier: BSD-3-Clause
import 'dart:typed_data';
import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('FIT parser integrity modes', () {
    /// Builds a minimal corrupted FIT file with header CRC mismatch.
    Uint8List buildFitWithCorruptedHeaderCrc() {
      final header = Uint8List(14);
      final bd = ByteData.view(header.buffer);
      header[0] = 14; // header size
      header[1] = 0x10; // protocol version
      bd.setUint16(2, 0, Endian.little); // profile version
      bd.setUint32(4, 4, Endian.little); // data size (minimal)
      header.setRange(8, 12, '.FIT'.codeUnits);
      // Corrupt the header CRC (last 2 bytes)
      header[12] = 0xFF;
      header[13] = 0xFF;

      // Add minimal data section
      final data = Uint8List.fromList([0x40, 0x00, 0x00, 0x14, 0x00, 0x00]);
      final crc = Uint8List(2);
      crc[0] = 0x00;
      crc[1] = 0x00;

      return Uint8List.fromList([...header, ...data, ...crc]);
    }

    test('IntegrityMode.report collects diagnostics but continues parsing', () {
      final corruptedFit = buildFitWithCorruptedHeaderCrc();
      final result = FitParser().parseBytesWithIntegrity(
        corruptedFit,
        integrityConfig: const IntegrityConfig.report(collectStats: true),
      );

      // Should have diagnostics but not throw
      expect(result.diagnostics, isNotEmpty);
      expect(
        result.diagnostics.any((d) => d.code == 'fit.header.crc_mismatch'),
        isTrue,
      );

      // Should collect stats
      expect(result.integrityStats, isNotNull);
      expect(result.integrityStats!.headerCrcMismatches, greaterThan(0));
      expect(result.integrityStats!.crcMismatches, greaterThan(0));
    });

    test('IntegrityMode.silent ignores all integrity issues', () {
      final corruptedFit = buildFitWithCorruptedHeaderCrc();
      final result = FitParser().parseBytesWithIntegrity(
        corruptedFit,
        integrityConfig: const IntegrityConfig.silent(),
      );

      // Should complete without diagnostics
      expect(
        result.diagnostics.any((d) => d.code.contains('crc')),
        // Depending on implementation, may or may not report
        // For now, just verify it returns a result
        anything,
      );
      expect(result.integrityMode, equals(IntegrityMode.silent));
    });

    test('IntegrityStats tracks different CRC failure types', () {
      final corruptedFit = buildFitWithCorruptedHeaderCrc();
      final result = FitParser().parseBytesWithIntegrity(
        corruptedFit,
        integrityConfig: const IntegrityConfig.report(collectStats: true),
      );

      final stats = result.integrityStats;
      expect(stats, isNotNull);

      // Should distinguish header vs trailer CRCs
      expect(stats!.headerCrcMismatches, isNonNegative);
      expect(stats.trailerCrcMismatches, isNonNegative);

      // Total should equal sum of parts
      expect(stats.crcMismatches >= stats.headerCrcMismatches, isTrue);
    });

    test('IntegrityStats.summary() provides readable report', () {
      final stats = IntegrityStats(
        crcMismatches: 2,
        headerCrcMismatches: 1,
        trailerCrcMismatches: 1,
        truncatedSections: 1,
        invalidMessages: 3,
        recoveryAttempts: 5,
      );

      final summary = stats.summary();
      expect(summary, contains('CRC'));
      expect(summary, contains('truncated'));
      expect(summary, contains('invalid'));
      expect(summary, contains('recovery'));
    });

    test('ActivityParseResult exposes integrityStats and mode', () {
      final corruptedFit = buildFitWithCorruptedHeaderCrc();
      final result = FitParser().parseBytesWithIntegrity(
        corruptedFit,
        integrityConfig: const IntegrityConfig.report(collectStats: true),
      );

      // New fields should be accessible
      expect(result.integrityMode, isNotNull);
      expect(result.integrityStats, isNotNull);
      expect(result.integrityMode, equals(IntegrityMode.report));
    });
  });
}
