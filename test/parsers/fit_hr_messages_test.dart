// SPDX-License-Identifier: BSD-3-Clause
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

/// Coverage for FIT `hr` messages (global 132), which carry the heart rate a
/// strap stored and forwarded later. Field numbers are taken from the
/// official FIT profile: 253 timestamp, 0 fractional_timestamp (scale
/// 32768), 6 filtered_bpm, 9 event_timestamp (scale 1024), 10
/// event_timestamp_12 (12-bit values, least significant bit first, that
/// accumulate into event_timestamp). The expected heart rates are what the
/// Garmin FIT SDK returns for the same bytes with heart rate merging on.
void main() {
  const start = 1000;

  /// Packs 12-bit values two to every three bytes, least significant first.
  List<int> pack12(List<int> values) => [
    for (var i = 0; i < values.length; i += 2) ...[
      values[i] & 0xFF,
      (values[i] >> 8) | ((values[i + 1] & 0x0F) << 4),
      values[i + 1] >> 4,
    ],
  ];

  /// Six records one second apart, each with heart rate 60, then the hr
  /// messages. The anchor beat (100 bpm) sits on the first record's second;
  /// eight more beats follow every 512/1024 s, 110 to 180 bpm. Their 12-bit
  /// timestamps cross the 4096 boundary, so decoding has to accumulate.
  Uint8List buildFit({bool anchor = true, bool recordHeartRate = true}) {
    const anchorEvent = 10 * 1024;
    final data = BytesBuilder()
      // Record definition, local 0, global 20.
      ..add([0x40, 0x00, 0x00])
      ..add(uint16LeBytes(20))
      ..addByte(recordHeartRate ? 4 : 3)
      ..add([0xFD, 0x04, 0x86]) // timestamp
      ..add([0x00, 0x04, 0x85]) // position_lat
      ..add([0x01, 0x04, 0x85]) // position_long
      ..add(recordHeartRate ? [0x03, 0x01, 0x02] : const <int>[]); // heart_rate
    for (var i = 0; i < 6; i++) {
      data
        ..addByte(0x00)
        ..add(uint32LeBytes(start + i))
        ..add(int32LeBytes(encodeSemicircles(47.0 + i * 0.0001)))
        ..add(int32LeBytes(encodeSemicircles(8.0)))
        ..add(recordHeartRate ? [60] : const <int>[]);
    }
    if (anchor) {
      data
        // Anchor hr definition, local 1, global 132.
        ..add([0x41, 0x00, 0x00])
        ..add(uint16LeBytes(132))
        ..addByte(4)
        ..add([0xFD, 0x04, 0x86]) // timestamp
        ..add([0x00, 0x02, 0x84]) // fractional_timestamp
        ..add([0x06, 0x01, 0x02]) // filtered_bpm
        ..add([0x09, 0x04, 0x86]) // event_timestamp
        ..addByte(0x01)
        ..add(uint32LeBytes(start))
        ..add(uint16LeBytes(0))
        ..addByte(100)
        ..add(uint32LeBytes(anchorEvent));
    }
    data
      // Delta hr definition, local 2, global 132.
      ..add([0x42, 0x00, 0x00])
      ..add(uint16LeBytes(132))
      ..addByte(2)
      ..add([0x06, 0x08, 0x02]) // filtered_bpm[8]
      ..add([0x0A, 0x0C, 0x0D]) // event_timestamp_12[12]
      ..addByte(0x02)
      ..add([110, 120, 130, 140, 150, 160, 170, 180])
      ..add(
        pack12([
          for (var beat = 1; beat <= 8; beat++)
            (anchorEvent + beat * 512) & 0xFFF,
        ]),
      );
    final full = data.toBytes();
    final crc = fitCrc(full);
    return Uint8List.fromList([
      ...buildFitHeader(full.length),
      ...full,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);
  }

  ActivityParseResult parse(Uint8List bytes) =>
      ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

  Iterable<String> codes(ActivityParseResult result) =>
      result.diagnostics.map((d) => d.code);

  List<double> heartRates(ActivityParseResult result) => [
    for (final sample in result.activity.channel(Channel.heartRate))
      sample.value,
  ];

  test('hr messages supply the heart rate of the records they cover', () {
    final result = parse(buildFit());

    // The last two records keep their own value: the beats of an interval
    // count only once a later beat closes it.
    expect(heartRates(result), [100, 110, 130, 150, 60, 60]);
    expect(result.activity.channel(Channel.heartRate).map((s) => s.time), [
      for (var i = 0; i < 6; i++)
        DateTime.utc(1989, 12, 31).add(Duration(seconds: start + i)),
    ]);
  });

  test('records without a heart rate of their own gain one', () {
    final result = parse(buildFit(recordHeartRate: false));

    expect(heartRates(result), [100, 110, 130, 150]);
  });

  test('the merge is reported and hr is not listed as skipped', () {
    final result = parse(buildFit());

    expect(
      result.diagnostics,
      contains(
        isA<ParseDiagnostic>()
            .having((d) => d.code, 'code', 'fit.hr.merged')
            .having((d) => d.severity, 'severity', ParseSeverity.info)
            .having((d) => d.message, 'message', contains('2 hr message(s)'))
            .having((d) => d.message, 'message', contains('4 record(s)')),
      ),
    );
    expect(codes(result), isNot(contains('fit.message.vendor_skipped')));
    expect(codes(result), isNot(contains('fit.hr.skipped')));
  });

  test('beats with no anchor before them are skipped with a warning', () {
    final result = parse(buildFit(anchor: false));

    expect(heartRates(result), [60, 60, 60, 60, 60, 60]);
    expect(
      result.diagnostics,
      contains(
        isA<ParseDiagnostic>()
            .having((d) => d.code, 'code', 'fit.hr.skipped')
            .having((d) => d.severity, 'severity', ParseSeverity.warning)
            .having((d) => d.message, 'message', contains('1 hr message(s)')),
      ),
    );
    expect(codes(result), isNot(contains('fit.hr.merged')));
  });
}
