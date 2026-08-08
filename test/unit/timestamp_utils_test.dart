// SPDX-License-Identifier: BSD-3-Clause
import 'package:activity_files/src/parse/timestamp_utils.dart';
import 'package:test/test.dart';

void main() {
  group('parseTimestampAssumeUtc', () {
    test('missing offset is treated as UTC', () {
      expect(
        parseTimestampAssumeUtc('2024-01-01T10:00:00'),
        equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
      );
    });

    test('Z suffix is preserved as UTC', () {
      expect(
        parseTimestampAssumeUtc('2024-01-01T10:00:00Z'),
        equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
      );
    });

    test('explicit positive offset converts to the correct UTC instant', () {
      expect(
        parseTimestampAssumeUtc('2024-01-01T10:00:00+02:00'),
        equals(DateTime.utc(2024, 1, 1, 8, 0, 0)),
      );
    });

    test('explicit negative offset converts to the correct UTC instant', () {
      expect(
        parseTimestampAssumeUtc('2024-01-01T10:00:00-05:00'),
        equals(DateTime.utc(2024, 1, 1, 15, 0, 0)),
      );
    });

    test('fractional seconds without an offset are treated as UTC', () {
      expect(
        parseTimestampAssumeUtc('2024-01-01T10:00:00.500'),
        equals(DateTime.utc(2024, 1, 1, 10, 0, 0, 500)),
      );
    });
  });
}
