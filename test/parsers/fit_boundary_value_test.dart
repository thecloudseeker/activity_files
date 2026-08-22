// SPDX-License-Identifier: BSD-3-Clause
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

/// Coverage for FIT decode bugs where a legitimate value collided with an
/// invalid-value sentinel meant for a narrower type, and for the
/// compressed-timestamp header's reference-resolution rules.
void main() {
  final fitEpoch = DateTime.utc(1989, 12, 31);

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

  test('session calories/avg_power of 255 (the uint8 sentinel) are not nulled '
      'as if they were the uint16 sentinel', () {
    final data = BytesBuilder()
      // Session definition, local 0, global 18: 11 total_calories (uint16),
      // 20 avg_power (uint16).
      ..add([0x40, 0x00, 0x00])
      ..add(uint16LeBytes(18))
      ..addByte(2)
      ..add([11, 2, 0x84])
      ..add([20, 2, 0x84])
      ..addByte(0x00)
      ..add(uint16LeBytes(255))
      ..add(uint16LeBytes(255));

    final bytes = finish(data);
    final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

    expect(result.activity.summary?.calories, equals(255.0));
    expect(result.activity.summary?.avgPower, equals(255.0));
  });

  test('a 1-byte-wide developer field array is not truncated to its first '
      'element, and the reader stays aligned for fields after it', () {
    final data = BytesBuilder()
      // field_description (206), local 0: developer_data_index,
      // field_definition_number, fit_base_type_id, field_name.
      ..add([
        0x40, 0x00, 0x00,
        ...uint16LeBytes(206),
        4,
        0x00, 1, 0x02, // developer_data_index
        0x01, 1, 0x02, // field_definition_number
        0x02, 1, 0x02, // fit_base_type_id
        0x03, 5, 0x07, // field_name (string, 4 chars + terminator)
      ])
      ..add([0x00, 0x00, 0x00, 0x02, ...'legs'.codeUnits, 0x00])
      // Record (20), local 1: timestamp, lat, lon, then a developer field
      // declared uint8 (0x02) with size 2 (an array), then a normal uint8
      // native field (temperature, 13) that must land at the right offset.
      ..add([
        0x61, 0x00, 0x00,
        ...uint16LeBytes(20),
        4,
        0xFD, 4, 0x86, // timestamp
        0x00, 4, 0x85, // latitude
        0x01, 4, 0x85, // longitude
        13, 1, 0x02, // temperature (uint8 scalar, follows the dev field)
        1, // one developer field
        0x00, 2, 0x00, // field 0, size 2, developer index 0
      ])
      ..add([
        0x01,
        ...uint32LeBytes(1000),
        ...int32LeBytes(encodeSemicircles(47.0)),
        ...int32LeBytes(encodeSemicircles(11.0)),
        20, // temperature = 20 C, must decode correctly if alignment held
        42, 55, // the 2-element uint8 developer array (after native fields)
      ]);

    final bytes = finish(data);
    final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

    expect(
      result.activity.channel(Channel.custom('legs_0')).single.value,
      equals(42.0),
    );
    expect(
      result.activity.channel(Channel.custom('legs_1')).single.value,
      equals(55.0),
    );
    expect(result.activity.points.single.time, isNotNull);
    expect(
      result.activity.channel(Channel.temperature).single.value,
      equals(20.0),
    );
  });

  test('a compressed-timestamp offset equal to the reference low 5 bits is '
      'zero elapsed time, not a spurious +32s rollover', () {
    final recordDef = BytesBuilder()
      ..add([0x40, 0x00, 0x00])
      ..add(uint16LeBytes(20))
      ..addByte(3)
      ..add([0xFD, 4, 0x86])
      ..add([0x00, 4, 0x85])
      ..add([0x01, 4, 0x85]);
    final normalPoint = BytesBuilder()
      ..addByte(0x00)
      ..add(uint32LeBytes(1000)) // 1000 & 0x1F == 8
      ..add(int32LeBytes(encodeSemicircles(40.0)))
      ..add(int32LeBytes(encodeSemicircles(-105.0)));
    // Compressed header: local type 0, offset 8 (== 1000 & 0x1F).
    final compressedPoint = BytesBuilder()
      ..addByte(0x88)
      ..add(int32LeBytes(encodeSemicircles(40.001)))
      ..add(int32LeBytes(encodeSemicircles(-105.001)));

    final data = BytesBuilder()
      ..add(recordDef.toBytes())
      ..add(normalPoint.toBytes())
      ..add(compressedPoint.toBytes());

    final bytes = finish(data);
    final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

    expect(result.activity.points, hasLength(2));
    expect(
      result.activity.points[1].time,
      equals(fitEpoch.add(const Duration(seconds: 1000))),
    );
  });

  test('a compressed-timestamp message on a local type that has never itself '
      'carried a timestamp resolves against the global last-known timestamp, '
      'not the raw 0-31 offset', () {
    final data = BytesBuilder()
      // Local 0: record, timestamp=1000, one point.
      ..add([
        0x40,
        0x00,
        0x00,
        ...uint16LeBytes(20),
        3,
        0xFD,
        4,
        0x86,
        0x00,
        4,
        0x85,
        0x01,
        4,
        0x85,
      ])
      ..add([
        0x00,
        ...uint32LeBytes(1000),
        ...int32LeBytes(encodeSemicircles(40.0)),
        ...int32LeBytes(encodeSemicircles(-105.0)),
      ])
      // Local 1: also record, same shape, registered but never yet given
      // a normal-header timestamp of its own.
      ..add([
        0x41,
        0x00,
        0x00,
        ...uint16LeBytes(20),
        3,
        0xFD,
        4,
        0x86,
        0x00,
        4,
        0x85,
        0x01,
        4,
        0x85,
      ])
      // Compressed header: local type 1, offset 11. 1000 & 0x1F == 8, so
      // spec-correct result is 1000 + ((11 - 8) & 0x1F) == 1003.
      ..add([
        0xAB,
        ...int32LeBytes(encodeSemicircles(41.0)),
        ...int32LeBytes(encodeSemicircles(-106.0)),
      ]);

    final bytes = finish(data);
    final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

    expect(result.activity.points, hasLength(2));
    expect(
      result.activity.points[1].time,
      equals(fitEpoch.add(const Duration(seconds: 1003))),
    );
  });
}
