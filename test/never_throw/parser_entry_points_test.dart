// SPDX-License-Identifier: BSD-3-Clause
// ignore_for_file: deprecated_member_use_from_same_package
/// The lower-level parser entry points return an error diagnostic for input
/// they cannot read instead of throwing.
library;

import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void _expectFormatError(ActivityParseResult result) {
  expect(result.activity.points, isEmpty);
  expect(
    result.diagnostics
        .where((d) => d.severity == ParseSeverity.error)
        .map((d) => d.code),
    contains('parser.format_exception'),
  );
}

void main() {
  // 0xC3 starts a two-byte UTF-8 sequence that 0x28 does not continue.
  final invalidUtf8 = Uint8List.fromList([
    ...'<?xml version="1.0"?><gpx><name>'.codeUnits,
    0xC3,
    0x28,
    ...'</name></gpx>'.codeUnits,
  ]);

  for (final format in [
    ActivityFileFormat.gpx,
    ActivityFileFormat.tcx,
    ActivityFileFormat.csv,
    ActivityFileFormat.geojson,
  ]) {
    test('parseBytes reports invalid UTF-8 as ${format.name}', () {
      _expectFormatError(ActivityParser.parseBytes(invalidUtf8, format));
    });
  }

  final damagedFitHeaders = <String, List<int>>{
    'empty': [],
    'shorter than a header': [14, 0x10, 0, 0],
    'header size past the end': [
      40, 0x10, 0, 0, 0, 0, 0, 0, 0x2E, 0x46, 0x49, 0x54, //
    ],
    'not .FIT': [
      14, 0x10, 0, 0, 0, 0, 0, 0, 0x2E, 0x46, 0x4F, 0x4F, 0, 0, //
    ],
  };
  for (final MapEntry(key: label, value: bytes) in damagedFitHeaders.entries) {
    test('a FIT payload that is $label is reported', () {
      _expectFormatError(
        ActivityParser.parseBytes(bytes, ActivityFileFormat.fit),
      );
      _expectFormatError(
        const FitParser().parseBytes(Uint8List.fromList(bytes)),
      );
    });
  }

  test('FIT text that is not base64 is reported', () {
    _expectFormatError(
      ActivityParser.parse('not base64!', ActivityFileFormat.fit),
    );
    _expectFormatError(const FitParser().parse('not base64!'));
  });
}
