// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for activity validation.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Validation', () {
    test('flags duplicates and coordinate issues', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final invalid = RawActivity(
        points: [
          GeoPoint(latitude: 95, longitude: 0, time: time),
          GeoPoint(latitude: 40, longitude: 200, time: time),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: time, value: 140),
            Sample(time: time, value: 141),
          ],
        },
      );

      final result = validateRawActivity(
        invalid,
        gapWarningThreshold: Duration.zero,
      );
      expect(result.errors.length, greaterThanOrEqualTo(3));
    });

    test('reports large gaps as warnings', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40, longitude: -105, time: time),
          GeoPoint(
            latitude: 40.01,
            longitude: -105.01,
            time: time.add(const Duration(minutes: 10)),
          ),
        ],
      );

      final result = validateRawActivity(
        activity,
        gapWarningThreshold: const Duration(seconds: 60),
      );
      expect(result.errors, isEmpty);
      expect(result.warnings, isNotEmpty);
    });
  });
}
