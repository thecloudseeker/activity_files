// SPDX-License-Identifier: BSD-3-Clause
/// Tests for precise, machine-readable FIT parser diagnostics.
library;

import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('FIT precise diagnostics', () {
    group('fit.no_usable_data', () {
      test(
        'emitted with node and suggestedFix when file has data but no activity data',
        () {
          // Build a minimal valid FIT file with a definition and a data record
          // for a non-activity message (file_id only), so no track points or
          // channels are produced.
          final bytes = buildMinimalFitWithNoActivityData();
          final parser = FitParser();
          final result = parser.parseBytes(bytes);
          // The file should either parse with no points/channels or emit the diagnostic.
          // Because buildMinimalFitWithNoActivityData produces a file_id message only
          // (no record messages), sawDataMessage will be true but no usable output
          // results — expect the diagnostic.
          final noDataDiag = result.diagnostics
              .where((d) => d.code == 'fit.no_usable_data')
              .toList();
          expect(
            noDataDiag,
            isNotEmpty,
            reason:
                'Should emit fit.no_usable_data when no activity data extracted',
          );
          final diag = noDataDiag.first;
          expect(diag.severity, ParseSeverity.error);
          expect(diag.node, isNotNull);
          expect(diag.node!.path, 'fit.file');
          expect(diag.suggestedFix, isNotNull);
          expect(diag.priority, 0);
        },
      );
    });

    group('fit.data.unknown_definition', () {
      test(
        'emitted with node and suggestedFix for corrupt local-type reference',
        () {
          final bytes = buildFitWithUnknownDefinition();
          final parser = FitParser();
          final result = parser.parseBytes(bytes);
          final unknownDiag = result.diagnostics
              .where((d) => d.code == 'fit.data.unknown_definition')
              .toList();
          expect(
            unknownDiag,
            isNotEmpty,
            reason: 'Should emit fit.data.unknown_definition',
          );
          final diag = unknownDiag.first;
          expect(diag.node, isNotNull);
          expect(diag.node!.path, 'fit.message');
          expect(diag.node!.description, contains('localType='));
          expect(diag.suggestedFix, isNotNull);
        },
      );
    });

    group('fit.trailer.crc_mismatch', () {
      test('emitted with node and suggestedFix when trailer CRC is wrong', () {
        final bytes = buildFitWithBadTrailerCrc();
        final parser = FitParser();
        final result = parser.parseBytes(bytes);
        final crcDiag = result.diagnostics
            .where((d) => d.code == 'fit.trailer.crc_mismatch')
            .toList();
        expect(
          crcDiag,
          isNotEmpty,
          reason: 'Should emit fit.trailer.crc_mismatch',
        );
        final diag = crcDiag.first;
        expect(diag.severity, ParseSeverity.error);
        expect(diag.node, isNotNull);
        expect(diag.node!.path, 'fit.trailer');
        expect(diag.suggestedFix, isNotNull);
      });
    });

    group('fit.trailer.truncated', () {
      test('emitted with node and suggestedFix when file has no trailer', () {
        final bytes = buildFitWithTruncatedTrailer();
        final parser = FitParser();
        final result = parser.parseBytes(bytes);
        final truncDiag = result.diagnostics
            .where((d) => d.code == 'fit.trailer.truncated')
            .toList();
        expect(
          truncDiag,
          isNotEmpty,
          reason: 'Should emit fit.trailer.truncated',
        );
        final diag = truncDiag.first;
        expect(diag.severity, ParseSeverity.error);
        expect(diag.node!.path, 'fit.trailer');
        expect(diag.suggestedFix, isNotNull);
        expect(diag.priority, 0);
      });
    });

    group('CRC verification header variants', () {
      // The trailer CRC covers header + data. Files whose 14-byte header
      // carries a valid header CRC also pass a data-only computation (the
      // CRC state returns to zero after a block ending with its own CRC),
      // which masked a wrong data-only implementation until legacy files
      // exposed it. These pin the two real-world variants.
      test('12-byte legacy header validates without CRC diagnostics', () {
        final bytes = buildFitWithLegacy12ByteHeader();
        final result = FitParser().parseBytes(bytes);
        expect(
          result.diagnostics.where((d) => d.code.contains('crc_mismatch')),
          isEmpty,
          reason: 'valid legacy-header file must not be flagged',
        );
      });

      test('header CRC 0x0000 means "not computed" and is not verified', () {
        final bytes = buildFitWithZeroHeaderCrc();
        final result = FitParser().parseBytes(bytes);
        expect(
          result.diagnostics.where((d) => d.code.contains('crc_mismatch')),
          isEmpty,
          reason: 'zero header CRC must be skipped, not compared',
        );
      });
    });

    group('diagnostic codes follow prefix convention', () {
      test('all FIT diagnostic codes start with "fit."', () {
        // Parse a file that triggers multiple diagnostics and check code prefixes.
        final bytes = buildFitWithUnknownDefinition();
        final result = FitParser().parseBytes(bytes);
        for (final d in result.diagnostics) {
          expect(
            d.code.startsWith('fit.'),
            isTrue,
            reason: 'Diagnostic code "${d.code}" should start with "fit."',
          );
        }
      });
    });

    group('suggestedFix present for all emitted diagnostics', () {
      test('every diagnostic from a corrupt file has a suggestedFix', () {
        // A file that triggers multiple diagnostics.
        final bytes = buildFitWithBadTrailerCrc();
        final result = FitParser().parseBytes(bytes);
        for (final d in result.diagnostics) {
          expect(
            d.suggestedFix,
            isNotNull,
            reason:
                'Diagnostic "${d.code}" should carry a suggestedFix for actionable guidance',
          );
        }
      });
    });
  });
}

// ---------------------------------------------------------------------------
// FIT byte-level builders for diagnostic test scenarios
// ---------------------------------------------------------------------------

/// Returns a minimal valid FIT file containing only a file_id definition +
/// data record (global ID 0) but no record messages (global ID 20).
/// This makes sawDataMessage = true but produces no activity output.
Uint8List buildMinimalFitWithNoActivityData() {
  final data = BytesBuilder();

  // Definition message for file_id (global ID 0), local type 0
  // Header: 0x40 | local_type(0) = 0x40
  data.addByte(0x40); // definition record header
  data.addByte(0x00); // reserved
  data.addByte(0x00); // little-endian
  data.addByte(0x00); // global message number LSB (file_id = 0)
  data.addByte(0x00); // global message number MSB
  data.addByte(0x01); // field count = 1
  // Field: field_def_num=0, size=1, base_type=uint8 (0x02)
  data.addByte(0x00);
  data.addByte(0x01);
  data.addByte(0x02);

  // Data message for file_id, local type 0
  data.addByte(0x00); // data record header, local type 0
  data.addByte(0x04); // field value: type = activity (4)

  return _wrapInFitFile(data.toBytes());
}

/// Returns a FIT file that starts with a valid definition, then has a data
/// record with a local type that was never defined (local type 3).
Uint8List buildFitWithUnknownDefinition() {
  final data = BytesBuilder();

  // Definition for local type 0 (file_id)
  data.addByte(0x40);
  data.addByte(0x00);
  data.addByte(0x00);
  data.addByte(0x00);
  data.addByte(0x00);
  data.addByte(0x01);
  data.addByte(0x00);
  data.addByte(0x01);
  data.addByte(0x02);

  // Valid data message for local type 0
  data.addByte(0x00);
  data.addByte(0x04);

  // Data message for undefined local type 3 — triggers unknown_definition
  data.addByte(0x03);
  data.addByte(0xFF);

  return _wrapInFitFile(data.toBytes());
}

/// Returns a FIT file whose trailer CRC byte is deliberately wrong.
Uint8List buildFitWithBadTrailerCrc() {
  final validBytes = buildMinimalFitWithNoActivityData();
  final modified = Uint8List.fromList(validBytes);
  // Corrupt the last two bytes (trailer CRC).
  modified[modified.length - 1] = 0xAB;
  modified[modified.length - 2] = 0xCD;
  return modified;
}

/// Returns a FIT file whose payload is truncated — no trailer bytes.
Uint8List buildFitWithTruncatedTrailer() {
  final validBytes = buildMinimalFitWithNoActivityData();
  // Drop the last 2 bytes (trailer CRC).
  return Uint8List.sublistView(validBytes, 0, validBytes.length - 2);
}

/// The file_id definition + data section shared by the header-variant
/// builders below.
Uint8List _fileIdDataSection() {
  final data = BytesBuilder();
  data.add([0x40, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x02]);
  data.add([0x00, 0x04]); // file_id data: type = activity
  return data.toBytes();
}

/// Returns a valid FIT file with a legacy 12-byte header (no header CRC
/// field); the trailer CRC covers header + data per the spec.
Uint8List buildFitWithLegacy12ByteHeader() {
  final dataBytes = _fileIdDataSection();
  final header = Uint8List(12);
  header[0] = 12; // header size
  header[1] = 0x10; // protocol version
  header[4] = dataBytes.length & 0xFF;
  header[5] = (dataBytes.length >> 8) & 0xFF;
  header.setRange(8, 12, '.FIT'.codeUnits);
  final whole = Uint8List.fromList([...header, ...dataBytes]);
  final crc = _computeCrc(whole, 0, whole.length);
  return Uint8List.fromList([...whole, crc & 0xFF, (crc >> 8) & 0xFF]);
}

/// Returns a valid FIT file whose 14-byte header stores CRC 0x0000
/// ("not computed" per the spec, common on Edge 810-era files); the trailer
/// CRC covers header + data.
Uint8List buildFitWithZeroHeaderCrc() {
  final dataBytes = _fileIdDataSection();
  final header = Uint8List(14);
  header[0] = 14; // header size
  header[1] = 0x10; // protocol version
  header[4] = dataBytes.length & 0xFF;
  header[5] = (dataBytes.length >> 8) & 0xFF;
  header.setRange(8, 12, '.FIT'.codeUnits);
  // Bytes 12-13 stay 0x0000: header CRC deliberately not computed.
  final whole = Uint8List.fromList([...header, ...dataBytes]);
  final crc = _computeCrc(whole, 0, whole.length);
  return Uint8List.fromList([...whole, crc & 0xFF, (crc >> 8) & 0xFF]);
}

/// Wraps raw data bytes in a standard FIT file envelope (14-byte header + CRC trailer).
Uint8List _wrapInFitFile(Uint8List dataBytes) {
  final headerSize = 14;
  final dataSize = dataBytes.length;
  final totalSize = headerSize + dataSize + 2; // +2 for trailer CRC
  final buf = Uint8List(totalSize);

  // Header
  buf[0] = headerSize; // header size
  buf[1] = 0x10; // protocol version
  buf[2] = 0x08; // profile version LSB (2056 = 0x0808)
  buf[3] = 0x08; // profile version MSB
  buf[4] = dataSize & 0xFF;
  buf[5] = (dataSize >> 8) & 0xFF;
  buf[6] = (dataSize >> 16) & 0xFF;
  buf[7] = (dataSize >> 24) & 0xFF;
  buf[8] = 0x2E; // '.'
  buf[9] = 0x46; // 'F'
  buf[10] = 0x49; // 'I'
  buf[11] = 0x54; // 'T'

  // Header CRC (bytes 0-11, stored at bytes 12-13)
  final headerCrc = _computeCrc(buf, 0, 12);
  buf[12] = headerCrc & 0xFF;
  buf[13] = (headerCrc >> 8) & 0xFF;

  // Data
  for (var i = 0; i < dataSize; i++) {
    buf[headerSize + i] = dataBytes[i];
  }

  // Trailer CRC over data bytes
  final trailerCrc = _computeCrc(buf, headerSize, dataSize);
  buf[headerSize + dataSize] = trailerCrc & 0xFF;
  buf[headerSize + dataSize + 1] = (trailerCrc >> 8) & 0xFF;

  return buf;
}

int _computeCrc(Uint8List data, int offset, int length) {
  const crcTable = [
    0x0000,
    0xCC01,
    0xD801,
    0x1400,
    0xF001,
    0x3C00,
    0x2800,
    0xE401,
    0xA001,
    0x6C00,
    0x7800,
    0xB401,
    0x5000,
    0x9C01,
    0x8801,
    0x4400,
  ];
  var crc = 0;
  for (var i = 0; i < length; i++) {
    final byte = data[offset + i];
    var tmp = crcTable[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc = crc ^ tmp ^ crcTable[byte & 0xF];
    tmp = crcTable[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc = crc ^ tmp ^ crcTable[(byte >> 4) & 0xF];
  }
  return crc;
}
