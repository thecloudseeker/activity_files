// SPDX-License-Identifier: BSD-3-Clause
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

/// Legacy FIT record field 8 (`compressed_speed_distance`) packs a 12-bit speed
/// (scale 100, m/s) and a 12-bit distance delta accumulator (scale 16, m) into
/// three bytes. Older ANT+/Garmin devices use it instead of the separate speed
/// (6) and distance (5) fields. The byte sequences and expected values below
/// are ground truth from python-fitparse on a real Garmin file.
void main() {
  const base = 1000000000;

  Uint8List buildFile(List<List<int>> csdRecords) {
    final data = BytesBuilder();
    // Record definition, local 0, global 20: 253 timestamp (uint32),
    // 8 compressed_speed_distance (byte[3]).
    data
      ..add([0x40, 0x00, 0x00])
      ..add(uint16LeBytes(20))
      ..addByte(2)
      ..add([0xFD, 0x04, 0x86])
      ..add([0x08, 0x03, 0x0D]);
    for (var i = 0; i < csdRecords.length; i++) {
      data
        ..addByte(0x00)
        ..add(uint32LeBytes(base + i))
        ..add(csdRecords[i]);
    }
    final full = data.toBytes();
    final crc = fitCrc(full);
    return Uint8List.fromList([
      ...buildFitHeader(full.length),
      ...full,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);
  }

  test(
    'decodes compressed_speed_distance into speed and distance channels',
    () {
      final bytes = buildFile([
        [98, 1, 0], // speed 3.54 m/s, distance 0.00 m
        [99, 65, 14], // speed 3.55 m/s, distance 14.25 m
        [0, 224, 18], // speed 0.00 m/s, distance 18.875 m
      ]);
      final activity = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity;

      final speed = activity
          .channel(Channel.speed)
          .map((s) => s.value)
          .toList();
      final distance = activity
          .channel(Channel.distance)
          .map((s) => s.value)
          .toList();

      expect(speed.length, 3);
      expect(speed[0], closeTo(3.54, 1e-9));
      expect(speed[1], closeTo(3.55, 1e-9));
      expect(speed[2], closeTo(0.0, 1e-9));

      // Distance is the accumulated total, not per-record deltas.
      expect(distance.length, 3);
      expect(distance[0], closeTo(0.0, 1e-9));
      expect(distance[1], closeTo(14.25, 1e-9));
      expect(distance[2], closeTo(18.875, 1e-9));

      // Not surfaced as a raw fit_field_8 channel.
      expect(activity.channel(Channel.custom('fit_field_8')), isEmpty);
    },
  );

  test('invalid (all-0xFF) compressed_speed_distance is skipped', () {
    final bytes = buildFile([
      [0xFF, 0xFF, 0xFF], // invalid → no speed/distance
      [98, 1, 0], // speed 3.54, distance 0.0
    ]);
    final activity = ActivityParser.parseBytes(
      bytes,
      ActivityFileFormat.fit,
    ).activity;

    expect(activity.channel(Channel.speed).map((s) => s.value), [
      closeTo(3.54, 1e-9),
    ]);
    expect(activity.channel(Channel.distance).map((s) => s.value), [
      closeTo(0.0, 1e-9),
    ]);
  });

  test('explicit speed/distance fields take precedence over field 8', () {
    // A record definition with both field 8 and explicit distance (5)/speed (6)
    // must prefer the explicit fields.
    final data = BytesBuilder();
    data
      ..add([0x40, 0x00, 0x00])
      ..add(uint16LeBytes(20))
      ..addByte(4)
      ..add([0xFD, 0x04, 0x86]) // timestamp
      ..add([0x05, 0x04, 0x86]) // distance uint32 (scale 100)
      ..add([0x06, 0x02, 0x84]) // speed uint16 (scale 1000)
      ..add([0x08, 0x03, 0x0D]); // compressed_speed_distance
    data
      ..addByte(0x00)
      ..add(uint32LeBytes(base))
      ..add(uint32LeBytes(500000)) // distance 5000 m
      ..add(uint16LeBytes(4000)) // speed 4.0 m/s
      ..add([98, 1, 0]); // field 8 says 3.54 m/s / 0 m — must be ignored
    final full = data.toBytes();
    final crc = fitCrc(full);
    final bytes = Uint8List.fromList([
      ...buildFitHeader(full.length),
      ...full,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);

    final activity = ActivityParser.parseBytes(
      bytes,
      ActivityFileFormat.fit,
    ).activity;
    expect(activity.channel(Channel.speed).single.value, closeTo(4.0, 1e-9));
    expect(
      activity.channel(Channel.distance).single.value,
      closeTo(5000.0, 0.01),
    );
  });
}
