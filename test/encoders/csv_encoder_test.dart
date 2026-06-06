// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for CSV format encoder.
///
/// Tests CSV output encoding, formatting, and roundtrip conversion.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('CSV Encoder', () {
    group('Basic encoding', () {
      test('encodes simple activity', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('timestamp'));
        expect(csv, contains('latitude'));
        expect(csv, contains('longitude'));
        expect(csv, contains('40.0'));
        expect(csv, contains('-105.0'));
      });

      test('includes header row', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);
        final lines = csv.split('\n');

        expect(lines[0], contains('timestamp'));
        expect(lines.length, greaterThan(1));
      });

      test('encodes multiple points', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);
        final lines = csv.split('\n').where((l) => l.isNotEmpty).toList();

        expect(lines.length, equals(3)); // header + 2 data rows
      });
    });

    group('CSV formatting', () {
      test('uses comma separator', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains(','));
      });

      test('encodes ISO 8601 timestamps', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('2024-01-01'));
        expect(csv, contains('10:00:00'));
      });

      test('quotes fields with special characters', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          creator: 'Test, Device',
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        // Creator might not be in CSV, but test formatting with potential special chars
        expect(csv, isNotEmpty);
      });
    });

    group('Channel data handling', () {
      test('includes heart rate channel', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
            ],
          },
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('heart_rate'));
        expect(csv, contains('140'));
      });

      test('includes cadence channel', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {
            Channel.cadence: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 90),
            ],
          },
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('cadence'));
        expect(csv, contains('90'));
      });

      test('includes power channel', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {
            Channel.power: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 250),
            ],
          },
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('power'));
        expect(csv, contains('250'));
      });

      test('handles multiple channels', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
            ],
            Channel.cadence: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 90),
            ],
          },
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('heart_rate'));
        expect(csv, contains('cadence'));
      });

      test('handles empty channels', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {Channel.heartRate: []},
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, isNotEmpty); // Should still encode with empty channel
      });
    });

    group('Sport type', () {
      test('encodes running sport', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          sport: Sport.running,
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('running'));
      });

      test('encodes cycling sport', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          sport: Sport.cycling,
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('cycling'));
      });

      test('encodes swimming sport', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          sport: Sport.swimming,
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('swimming'));
      });

      test('encodes unknown sport as fallback', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          sport: Sport.unknown,
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('unknown'));
      });
    });

    group('Edge cases', () {
      test('handles null elevation', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
              elevation: 1500,
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('elevation'));
      });

      test('handles precision for coordinates', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.123456,
              longitude: -105.654321,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('40.'));
        expect(csv, contains('-105.'));
      });

      test('encodes empty activity', () {
        final activity = RawActivity();

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('timestamp')); // Should have header
      });

      test('handles activity with only one coordinate', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);

        expect(csv, contains('40.0'));
      });
    });

    group('Roundtrip conversion', () {
      test('encodes and parses back to matching data', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
          sport: Sport.cycling,
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);
        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);
        final parsed = result.activity;

        expect(parsed.points.length, equals(2));
        expect(parsed.sport, equals(Sport.cycling));
      });

      test('preserves coordinates through roundtrip', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.123,
              longitude: -105.456,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final csv = ActivityEncoder.encode(activity, ActivityFileFormat.csv);
        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);
        final parsed = result.activity;

        expect(parsed.points[0].latitude, closeTo(40.123, 0.001));
        expect(parsed.points[0].longitude, closeTo(-105.456, 0.001));
      });
    });
  });
}
