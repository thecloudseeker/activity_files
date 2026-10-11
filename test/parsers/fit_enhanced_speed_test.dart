// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

/// Coverage for the uint32 `enhanced_*` speed fields, which newer devices
/// write in place of the uint16 ones. Field numbers are taken from the
/// official FIT profile: record 6 speed / 73 enhanced_speed; session 14
/// avg_speed / 15 max_speed / 124 enhanced_avg_speed / 125
/// enhanced_max_speed; lap 13 avg_speed / 14 max_speed / 110
/// enhanced_avg_speed / 111 enhanced_max_speed. All are m/s with scale 1000.
void main() {
  const start = 1000;

  /// One record, one session and one lap. [legacy] and [enhanced] are raw
  /// (scale 1000) speeds written to the uint16 and uint32 field families;
  /// a null leaves that family out of the definitions entirely.
  Uint8List buildFit({int? legacy, int? enhanced}) {
    List<int> speedFieldDefs(int legacyNumber, int enhancedNumber) => [
      if (legacy != null) ...[legacyNumber, 0x02, 0x84],
      if (enhanced != null) ...[enhancedNumber, 0x04, 0x86],
    ];
    List<int> speedValues(int offset) => [
      if (legacy != null) ...uint16LeBytes(legacy + offset),
      if (enhanced != null) ...uint32LeBytes(enhanced + offset),
    ];
    final speedFieldCount =
        (legacy != null ? 1 : 0) + (enhanced != null ? 1 : 0);

    final data = BytesBuilder()
      // Record definition, local 0, global 20.
      ..add([0x40, 0x00, 0x00])
      ..add(uint16LeBytes(20))
      ..addByte(3 + speedFieldCount)
      ..add([0xFD, 0x04, 0x86]) // timestamp
      ..add([0x00, 0x04, 0x85]) // position_lat
      ..add([0x01, 0x04, 0x85]) // position_long
      ..add(speedFieldDefs(6, 73))
      ..addByte(0x00)
      ..add(uint32LeBytes(start))
      ..add(int32LeBytes(encodeSemicircles(47.0)))
      ..add(int32LeBytes(encodeSemicircles(8.0)))
      ..add(speedValues(0))
      // Session definition, local 1, global 18.
      ..add([0x41, 0x00, 0x00])
      ..add(uint16LeBytes(18))
      ..addByte(3 + 2 * speedFieldCount)
      ..add([0xFD, 0x04, 0x86]) // timestamp
      ..add([0x02, 0x04, 0x86]) // start_time
      ..add([0x07, 0x04, 0x86]) // total_elapsed_time
      ..add(speedFieldDefs(14, 124))
      ..add(speedFieldDefs(15, 125))
      ..addByte(0x01)
      ..add(uint32LeBytes(start + 60))
      ..add(uint32LeBytes(start))
      ..add(uint32LeBytes(60000))
      ..add(speedValues(0))
      ..add(speedValues(500))
      // Lap definition, local 2, global 19.
      ..add([0x42, 0x00, 0x00])
      ..add(uint16LeBytes(19))
      ..addByte(3 + 2 * speedFieldCount)
      ..add([0xFD, 0x04, 0x86]) // timestamp
      ..add([0x02, 0x04, 0x86]) // start_time
      ..add([0x07, 0x04, 0x86]) // total_elapsed_time
      ..add(speedFieldDefs(13, 110))
      ..add(speedFieldDefs(14, 111))
      ..addByte(0x02)
      ..add(uint32LeBytes(start + 60))
      ..add(uint32LeBytes(start))
      ..add(uint32LeBytes(60000))
      ..add(speedValues(0))
      ..add(speedValues(500));
    final full = data.toBytes();
    final crc = fitCrc(full);
    return Uint8List.fromList([
      ...buildFitHeader(full.length),
      ...full,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);
  }

  RawActivity parse(Uint8List bytes) =>
      ActivityParser.parseBytes(bytes, ActivityFileFormat.fit).activity;

  void expectSpeeds(RawActivity activity, double speed) {
    expect(activity.channel(Channel.speed).map((s) => s.value), [
      closeTo(speed, 1e-9),
    ]);
    expect(activity.summary!.avgSpeed, closeTo(speed, 1e-9));
    expect(activity.summary!.maxSpeed, closeTo(speed + 0.5, 1e-9));
    expect(activity.laps.single.avgSpeed, closeTo(speed, 1e-9));
    expect(activity.laps.single.maxSpeed, closeTo(speed + 0.5, 1e-9));
  }

  test('enhanced speed fields alone populate speed on the record, session '
      'and lap', () {
    final activity = parse(buildFit(enhanced: 2750));

    expectSpeeds(activity, 2.75);
  });

  test('enhanced speed fields are not also kept as raw extras', () {
    final activity = parse(buildFit(enhanced: 2750));

    expect(
      activity.channels.keys.map((c) => c.id),
      isNot(contains('fit_field_73')),
    );
    expect(activity.summary!.extraFitFields.keys, isNot(contains(124)));
    expect(activity.summary!.extraFitFields.keys, isNot(contains(125)));
    expect(activity.laps.single.extraFitFields.keys, isNot(contains(110)));
    expect(activity.laps.single.extraFitFields.keys, isNot(contains(111)));
  });

  test('enhanced speed fields win over the uint16 ones when both are '
      'present', () {
    final activity = parse(buildFit(legacy: 1000, enhanced: 2750));

    expectSpeeds(activity, 2.75);
  });

  test('the uint16 speed fields are still read when no enhanced field '
      'exists', () {
    final activity = parse(buildFit(legacy: 1000));

    expectSpeeds(activity, 1.0);
  });

  test('speed read from enhanced fields survives a FIT round-trip', () {
    final activity = parse(buildFit(enhanced: 2750));

    final reparsed = parse(
      base64Decode(ActivityEncoder.encode(activity, ActivityFileFormat.fit)),
    );

    expectSpeeds(reparsed, 2.75);
  });
}
