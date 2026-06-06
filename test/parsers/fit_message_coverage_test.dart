// SPDX-License-Identifier: BSD-3-Clause
/// Tests for extended FIT message coverage (device/activity/file_creator).
library;

import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

void main() {
  group('FIT message coverage', () {
    test('parses device_info, activity, and file_creator messages', () {
      final bytes = _buildFitWithDeviceActivityAndCreator();
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      expect(result.activity.points, hasLength(1));

      final device = result.activity.device;
      expect(device, isNotNull);
      expect(device!.fitManufacturerId, equals(1));
      expect(device.fitProductId, equals(1000));
      expect(device.serialNumber, equals('12345'));
      expect(device.softwareVersion, equals('2.05'));

      final summary = result.activity.summary;
      expect(summary, isNotNull);
      expect(summary!.timerTime, equals(const Duration(seconds: 3600)));
      // elapsedTime comes from session message (18), not activity message (34); null here.
      expect(summary.elapsedTime, isNull);

      expect(result.activity.creator, contains('FIT FileCreator'));
      expect(result.activity.creator, contains('sw2.05'));
      expect(result.activity.creator, contains('hw7'));
    });
  });
}

Uint8List _buildFitWithDeviceActivityAndCreator() {
  final data = BytesBuilder();

  // Local 0: record (global 20) with timestamp/lat/lon
  data.add([
    0x40,
    0x00,
    0x00,
    0x14,
    0x00,
    0x03,
    0xFD,
    0x04,
    0x86,
    0x00,
    0x04,
    0x85,
    0x01,
    0x04,
    0x85,
  ]);
  data.add([
    0x00,
    ...uint32LeBytes(1000),
    ...int32LeBytes(encodeSemicircles(51.5)),
    ...int32LeBytes(encodeSemicircles(-0.12)),
  ]);

  // Local 1: device_info (global 23)
  data.add([
    0x41,
    0x00,
    0x00,
    0x17,
    0x00,
    0x04,
    0x03,
    0x02,
    0x84, // manufacturer (uint16)
    0x04,
    0x04,
    0x8C, // serial_number (uint32z)
    0x05,
    0x02,
    0x84, // product (uint16)
    0x06,
    0x02,
    0x84, // software_version (uint16, /100)
  ]);
  data.add([
    0x01,
    ...uint16LeBytes(1),
    ...uint32LeBytes(12345),
    ...uint16LeBytes(1000),
    ...uint16LeBytes(205),
  ]);

  // Local 2: activity (global 34)
  data.add([
    0x42,
    0x00,
    0x00,
    0x22,
    0x00,
    0x01,
    0x00,
    0x04,
    0x86, // total_timer_time (uint32)
  ]);
  data.add([0x02, ...uint32LeBytes(3600)]);

  // Local 3: file_creator (global 49)
  data.add([
    0x43,
    0x00,
    0x00,
    0x31,
    0x00,
    0x02,
    0x00,
    0x02,
    0x84, // software_version (uint16, /100)
    0x01,
    0x01,
    0x02, // hardware_version (uint8)
  ]);
  data.add([0x03, ...uint16LeBytes(205), 0x07]);

  final payload = data.toBytes();
  final header = buildFitHeader(payload.length);
  final crc = fitCrc(payload);

  return Uint8List.fromList([
    ...header,
    ...payload,
    crc & 0xFF,
    (crc >> 8) & 0xFF,
  ]);
}
