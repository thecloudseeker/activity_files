// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';

/// Demo: reading a damaged FIT file.
///
/// By default `ActivityFiles.import` keeps whatever it can read from a damaged
/// file and reports each problem as a diagnostic. `strictFitIntegrity: true`
/// refuses the file instead.
Future<void> main() async {
  final damaged = _buildCorruptedSample();
  await _demoDefault(damaged);
  await _demoStrict(damaged);
}

/// Default: keep what can be read, report every problem.
Future<void> _demoDefault(Uint8List bytes) async {
  print('=== Default: keep what can be read, report the problems ===');
  final result = await ActivityFiles.import(
    bytes,
    format: ActivityFileFormat.fit,
    useIsolate: false,
  );
  for (final diagnostic in result.diagnostics) {
    if (diagnostic.severity == ParseSeverity.error) {
      print('  ${diagnostic.code}: ${diagnostic.message}');
    }
  }
  print('  Points recovered: ${result.activity.points.length}');
  print('');
}

/// Strict: refuse a file with integrity errors.
Future<void> _demoStrict(Uint8List bytes) async {
  print('=== strictFitIntegrity: refuse a damaged file ===');
  try {
    await ActivityFiles.import(
      bytes,
      format: ActivityFileFormat.fit,
      strictFitIntegrity: true,
      useIsolate: false,
    );
    print('  Accepted');
  } on FormatException catch (error) {
    print('  Refused: ${error.message}');
  }
  print('');
}

/// A minimal FIT file whose header CRC is wrong.
Uint8List _buildCorruptedSample() {
  final header = Uint8List(14);
  final bd = ByteData.view(header.buffer);
  header[0] = 14;
  header[1] = 0x10;
  bd.setUint16(2, 0, Endian.little);
  bd.setUint32(4, 4, Endian.little);
  header.setRange(8, 12, '.FIT'.codeUnits);
  header[12] = 0xFF;
  header[13] = 0xFF;

  final data = Uint8List.fromList([0x40, 0x00, 0x00, 0x14, 0x00, 0x00]);

  return Uint8List.fromList([...header, ...data, 0x00, 0x00]);
}
