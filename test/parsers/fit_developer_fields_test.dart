// SPDX-License-Identifier: BSD-3-Clause
/// Tests for FIT developer-field extraction.
library;

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
}
