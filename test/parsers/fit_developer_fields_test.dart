// SPDX-License-Identifier: BSD-3-Clause
/// Tests for FIT developer-field extraction.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

void main() {
  group('FIT developer fields', () {
    test('exposes unknown developer fields as custom channels', () {
      final bytes = buildFitFileWithDeveloperData(
        developerFieldNumber: 1,
        developerIndex: 0,
        developerFieldBytes: const [0x12, 0x34],
      );

      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      final channel = Channel.custom('fit_dev_0_1');
      final samples = result.activity.channel(channel);

      expect(samples, hasLength(1));
      expect(samples.first.value, equals(0x3412));
    });

    test('maps known developer fields to stable semantic channel names', () {
      final bytes = buildFitFileWithDeveloperData(
        developerFieldNumber: 0,
        developerIndex: 0,
        developerFieldBytes: const [0xC8, 0x00], // 200
      );

      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      final runningPower = result.activity.channel(
        Channel.custom('running_power'),
      );

      expect(runningPower, hasLength(1));
      expect(runningPower.first.value, equals(200));
    });
  });

  group('FIT developer fields with field_description', () {
    test('signed values decode via the declared base type', () {
      // sint32 -855; the size-based fallback reads it as uint32 garbage.
      final bytes = _buildFitWithDescribedDeveloperField(
        fieldName: 'calibration',
        fitBaseTypeId: 0x85,
        valueBytes: const [0xA9, 0xFC, 0xFF, 0xFF],
      );

      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      final samples = result.activity.channel(Channel.custom('calibration'));

      expect(samples, hasLength(1));
      expect(samples.single.value, equals(-855.0));
    });

    test('float32 values decode via the declared base type', () {
      // 3.25f = 0x40500000 little-endian.
      final bytes = _buildFitWithDescribedDeveloperField(
        fieldName: 'stance_ratio',
        fitBaseTypeId: 0x88,
        valueBytes: const [0x00, 0x00, 0x50, 0x40],
      );

      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      final samples = result.activity.channel(Channel.custom('stance_ratio'));

      expect(samples, hasLength(1));
      expect(samples.single.value, closeTo(3.25, 1e-9));
    });

    test('field names sanitize into safe channel ids', () {
      final bytes = _buildFitWithDescribedDeveloperField(
        fieldName: 'Leg Spring Stiffness',
        fitBaseTypeId: 0x02,
        valueBytes: const [0x2A],
      );

      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      final samples = result.activity.channel(
        Channel.custom('leg_spring_stiffness'),
      );

      expect(samples, hasLength(1));
      expect(samples.single.value, equals(42.0));
    });

    test('scale and offset from the description are applied', () {
      // uint16 500 with scale 10, offset 5: 500 / 10 - 5 = 45.
      final bytes = _buildFitWithDescribedDeveloperField(
        fieldName: 'charge',
        fitBaseTypeId: 0x84,
        valueBytes: const [0xF4, 0x01],
        scale: 10,
        offset: 5,
      );

      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      final samples = result.activity.channel(Channel.custom('charge'));

      expect(samples, hasLength(1));
      expect(samples.single.value, equals(45.0));
    });
  });
}

/// Builds a FIT file with a field_description (206) message followed by one
/// record carrying the described developer field.
Uint8List _buildFitWithDescribedDeveloperField({
  required String fieldName,
  required int fitBaseTypeId,
  required List<int> valueBytes,
  int? scale,
  int? offset,
}) {
  final nameBytes = utf8.encode(fieldName);
  final withScaling = scale != null || offset != null;
  final data = BytesBuilder();

  // Local 0: field_description (global 206) definition + data.
  data.add([
    0x40,
    0x00,
    0x00,
    ...uint16LeBytes(206),
    withScaling ? 6 : 4,
    0x00, 0x01, 0x02, // developer_data_index (uint8)
    0x01, 0x01, 0x02, // field_definition_number (uint8)
    0x02, 0x01, 0x02, // fit_base_type_id (uint8)
    0x03, nameBytes.length + 1, 0x07, // field_name (string)
    if (withScaling) ...[0x06, 0x01, 0x02], // scale (uint8)
    if (withScaling) ...[0x07, 0x01, 0x01], // offset (sint8)
  ]);
  data.add([
    0x00,
    0x00, // developer_data_index 0
    0x00, // field_definition_number 0
    fitBaseTypeId,
    ...nameBytes,
    0x00,
    if (withScaling) ...[scale ?? 1, offset ?? 0],
  ]);

  // Local 1: record (global 20) with the developer field appended.
  data.add([
    0x61,
    0x00,
    0x00,
    ...uint16LeBytes(20),
    0x03,
    0xFD, 0x04, 0x86, // timestamp
    0x00, 0x04, 0x85, // latitude
    0x01, 0x04, 0x85, // longitude
    0x01, // one developer field
    0x00, valueBytes.length, 0x00, // field 0, size, developer index 0
  ]);
  data.add([
    0x01,
    ...uint32LeBytes(1000),
    ...int32LeBytes(encodeSemicircles(47.0)),
    ...int32LeBytes(encodeSemicircles(11.0)),
    ...valueBytes,
  ]);

  final fullData = data.toBytes();
  final crc = fitCrc(fullData);
  final header = buildFitHeader(fullData.length);
  return Uint8List.fromList([
    ...header,
    ...fullData,
    crc & 0xFF,
    (crc >> 8) & 0xFF,
  ]);
}
