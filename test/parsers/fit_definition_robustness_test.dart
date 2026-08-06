// SPDX-License-Identifier: BSD-3-Clause
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

/// Coverage for two FIT definition-parsing requirements that real Garmin
/// files depend on:
///
/// 1. Definitions with more than 96 fields must be accepted. Modern Garmin
///    session/lap messages routinely carry 130+ fields; rejecting the
///    definition orphans its data message, trips stream resync, and
///    cascades into garbage, collapsing a 1.4 MB ride to ~5 points.
/// 2. 16/32-bit array fields (e.g. session `time_in_hr_zone`) must advance
///    the reader by the field size, not the base-type width, or every field
///    after them in the same message misaligns.
void main() {
  const base = 1000000000; // FIT seconds → a 2021 timestamp, passes validation.

  void addRecordDef(BytesBuilder data, int localId) {
    data
      ..add([0x40 | localId, 0x00, 0x00])
      ..add(uint16LeBytes(20)) // global 20 (record)
      ..addByte(3)
      ..add([0xFD, 0x04, 0x86]) // 253 timestamp uint32
      ..add([0x00, 0x04, 0x85]) // 0 latitude sint32
      ..add([0x01, 0x04, 0x85]); // 1 longitude sint32
  }

  void addRecord(BytesBuilder data, int localId, int ts) {
    data
      ..addByte(localId)
      ..add(uint32LeBytes(ts))
      ..add(int32LeBytes(encodeSemicircles(47.0)))
      ..add(int32LeBytes(encodeSemicircles(11.0)));
  }

  Uint8List finish(BytesBuilder data) {
    final full = data.toBytes();
    final crc = fitCrc(full);
    return Uint8List.fromList([
      ...buildFitHeader(full.length),
      ...full,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);
  }

  group('FIT definition robustness', () {
    test('session with 100 fields does not derail the record stream', () {
      final data = BytesBuilder();
      addRecordDef(data, 0);
      addRecord(data, 0, base);
      addRecord(data, 0, base + 1);
      addRecord(data, 0, base + 2);

      // Session definition, local 1, global 18, 100 fields (> the old cap):
      // 253 timestamp, 9 total_distance, 14 avg_speed, then 97 dummy uint8.
      data
        ..add([0x40 | 1, 0x00, 0x00])
        ..add(uint16LeBytes(18))
        ..addByte(100)
        ..add([253, 4, 0x86])
        ..add([9, 4, 0x86])
        ..add([14, 2, 0x84]);
      for (var f = 100; f <= 196; f++) {
        data.add([f, 1, 0x02]); // uint8
      }
      // Session data.
      data
        ..addByte(0x01)
        ..add(uint32LeBytes(base))
        ..add(uint32LeBytes(500000)) // 5000 m (scale 100)
        ..add(uint16LeBytes(3000)); // 3.0 m/s (scale 1000)
      for (var f = 100; f <= 196; f++) {
        data.addByte(f == 150 ? 42 : 0xFF); // one real value, rest invalid
      }

      // Records that come AFTER the large definition must still parse.
      addRecord(data, 0, base + 3);
      addRecord(data, 0, base + 4);
      addRecord(data, 0, base + 5);

      final activity = ActivityParser.parseBytes(
        finish(data),
        ActivityFileFormat.fit,
      ).activity;

      expect(
        activity.points,
        hasLength(6),
        reason: 'records before and after a 100-field session must survive',
      );
      expect(activity.summary?.totalDistanceMeters, closeTo(5000.0, 0.01));
      expect(activity.summary?.avgSpeed, closeTo(3.0, 0.001));
      expect(
        activity.summary?.extraFitFields[150],
        42,
        reason: 'unknown fields in a large session are still captured',
      );
    });

    test('16-bit array field does not misalign the fields after it', () {
      final data = BytesBuilder();
      addRecordDef(data, 0);
      addRecord(data, 0, base);

      // Session, local 1, global 18: an array field (120, uint16, size 4 = two
      // elements) placed BEFORE avg_speed (14) and total_distance (9). If the
      // array under-consumes, 14 and 9 read garbage.
      data
        ..add([0x40 | 1, 0x00, 0x00])
        ..add(uint16LeBytes(18))
        ..addByte(4)
        ..add([253, 4, 0x86]) // timestamp
        ..add([120, 4, 0x84]) // uint16 array (2 elements)
        ..add([14, 2, 0x84]) // avg_speed
        ..add([9, 4, 0x86]); // total_distance
      data
        ..addByte(0x01)
        ..add(uint32LeBytes(base))
        ..add(uint16LeBytes(100)) // array[0]
        ..add(uint16LeBytes(200)) // array[1]
        ..add(uint16LeBytes(3000)) // avg_speed 3.0 m/s
        ..add(uint32LeBytes(500000)); // distance 5000 m

      final activity = ActivityParser.parseBytes(
        finish(data),
        ActivityFileFormat.fit,
      ).activity;

      expect(
        activity.summary?.avgSpeed,
        closeTo(3.0, 0.001),
        reason: 'avg_speed after a uint16 array must not be misaligned',
      );
      expect(activity.summary?.totalDistanceMeters, closeTo(5000.0, 0.01));
    });
  });
}
