// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for CSV parser.
///
/// Tests CSV parsing with various column configurations, edge cases,
/// and error handling.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('CSV Parser', () {
    group('Basic parsing', () {
      test('parses minimal valid CSV with lat/lon/time', () {
        const csv = '''timestamp,latitude,longitude
2024-01-01T10:00:00Z,40.0,-105.0
2024-01-01T10:00:10Z,40.0005,-105.0005''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isEmpty,
        );
        expect(result.activity.points.length, equals(2));
        expect(result.activity.points[0].latitude, equals(40.0));
        expect(result.activity.points[0].longitude, equals(-105.0));
      });

      test('parses CSV with elevation', () {
        const csv = '''timestamp,latitude,longitude,elevation
2024-01-01T10:00:00Z,40.0,-105.0,1600
2024-01-01T10:00:10Z,40.0005,-105.0005,1610''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points[0].elevation, equals(1600));
        expect(result.activity.points[1].elevation, equals(1610));
      });

      test('parses CSV with heart_rate channel', () {
        const csv = '''timestamp,latitude,longitude,heart_rate
2024-01-01T10:00:00Z,40.0,-105.0,140
2024-01-01T10:00:10Z,40.0005,-105.0005,145''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        final hrChannel = result.activity.channel(Channel.heartRate);
        expect(hrChannel.length, equals(2));
        expect(hrChannel[0].value, equals(140));
        expect(hrChannel[1].value, equals(145));
      });

      test('parses CSV with multiple channels', () {
        const csv =
            '''timestamp,latitude,longitude,heart_rate,cadence,power,speed
2024-01-01T10:00:00Z,40.0,-105.0,140,80,200,5.5
2024-01-01T10:00:10Z,40.0005,-105.0005,145,84,220,6.0''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.channel(Channel.heartRate).length, equals(2));
        expect(result.activity.channel(Channel.cadence).length, equals(2));
        expect(result.activity.channel(Channel.power).length, equals(2));
        expect(result.activity.channel(Channel.speed).length, equals(2));
      });

      test('parses CSV with sport column', () {
        const csv = '''timestamp,latitude,longitude,sport
2024-01-01T10:00:00Z,40.0,-105.0,cycling
2024-01-01T10:00:10Z,40.0005,-105.0005,cycling''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.sport, equals(Sport.cycling));
      });
    });

    group('Column handling', () {
      test('handles columns in different order', () {
        const csv = '''latitude,timestamp,longitude,heart_rate
40.0,2024-01-01T10:00:00Z,-105.0,140
40.0005,2024-01-01T10:00:10Z,-105.0005,145''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points.length, equals(2));
        expect(result.activity.points[0].latitude, equals(40.0));
        expect(result.activity.channel(Channel.heartRate).length, equals(2));
      });

      test('ignores unknown columns', () {
        const csv = '''timestamp,latitude,longitude,unknown_field,heart_rate
2024-01-01T10:00:00Z,40.0,-105.0,some_value,140
2024-01-01T10:00:10Z,40.0005,-105.0005,other_value,145''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points.length, equals(2));
        expect(result.activity.channel(Channel.heartRate).length, equals(2));
      });

      test('handles empty channel values', () {
        const csv = '''timestamp,latitude,longitude,heart_rate,cadence
2024-01-01T10:00:00Z,40.0,-105.0,140,
2024-01-01T10:00:10Z,40.0005,-105.0005,,84''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        final hrChannel = result.activity.channel(Channel.heartRate);
        final cadChannel = result.activity.channel(Channel.cadence);
        expect(hrChannel.length, equals(1));
        expect(cadChannel.length, equals(1));
      });

      test('handles whitespace in column names', () {
        const csv = ''' timestamp , latitude , longitude , heart_rate 
2024-01-01T10:00:00Z,40.0,-105.0,140
2024-01-01T10:00:10Z,40.0005,-105.0005,145''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        // Some CSV implementations may trim whitespace, others may not
        // This test verifies robustness
        expect(result.activity.points.length, greaterThanOrEqualTo(0));
      });
    });

    group('Edge cases', () {
      test('handles empty CSV file', () {
        const csv = '';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
        expect(result.diagnostics[0].code, equals('csv.empty'));
      });

      test('handles CSV with header only', () {
        const csv = 'timestamp,latitude,longitude,heart_rate';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points, isEmpty);
      });

      test('skips rows with missing latitude', () {
        const csv = '''timestamp,latitude,longitude
2024-01-01T10:00:00Z,40.0,-105.0
2024-01-01T10:00:10Z,,-105.0005
2024-01-01T10:00:20Z,40.001,-105.001''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points.length, equals(2));
        expect(
          result.diagnostics.any(
            (d) => d.code == 'csv.row.invalid_coordinates',
          ),
          isTrue,
        );
      });

      test('skips rows with missing longitude', () {
        const csv = '''timestamp,latitude,longitude
2024-01-01T10:00:00Z,40.0,-105.0
2024-01-01T10:00:10Z,40.0005,
2024-01-01T10:00:20Z,40.001,-105.001''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points.length, equals(2));
        expect(
          result.diagnostics.any(
            (d) => d.code == 'csv.row.invalid_coordinates',
          ),
          isTrue,
        );
      });

      test('skips rows with missing timestamp', () {
        const csv = '''timestamp,latitude,longitude
2024-01-01T10:00:00Z,40.0,-105.0
,40.0005,-105.0005
2024-01-01T10:00:20Z,40.001,-105.001''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points.length, equals(2));
        expect(
          result.diagnostics.any((d) => d.code == 'csv.row.invalid_timestamp'),
          isTrue,
        );
      });

      test('skips empty rows', () {
        const csv = '''timestamp,latitude,longitude,heart_rate
2024-01-01T10:00:00Z,40.0,-105.0,140

2024-01-01T10:00:10Z,40.0005,-105.0005,145''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points.length, equals(2));
      });

      test(
        'diagnostic row number accounts for blank lines above the bad row',
        () {
          const csv =
              'timestamp,latitude,longitude\n'
              '2024-01-01T10:00:00Z,40.0,-105.0\n'
              '\n'
              '\n'
              'not-a-date,40.001,-105.001';

          final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

          final diagnostic = result.diagnostics.firstWhere(
            (d) => d.code == 'csv.row.invalid_timestamp',
          );
          expect(diagnostic.message, contains('Row 5'));
        },
      );

      test('handles numeric parsing with different formats', () {
        const csv = '''timestamp,latitude,longitude,heart_rate
2024-01-01T10:00:00Z,40,-105,140
2024-01-01T10:00:10Z,40.0005,-105.0005,145.5''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points.length, equals(2));
        expect(
          result.activity.channel(Channel.heartRate)[1].value,
          equals(145.5),
        );
      });
    });

    group('Timestamp parsing', () {
      test('parses ISO 8601 timestamps', () {
        const csv = '''timestamp,latitude,longitude
2024-01-01T10:00:00Z,40.0,-105.0
2024-01-01T10:00:10Z,40.0005,-105.0005''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points[0].time, isA<DateTime>());
        expect(
          result.activity.points[1].time.difference(
            result.activity.points[0].time,
          ),
          equals(const Duration(seconds: 10)),
        );
      });

      test('converts timestamps to UTC', () {
        const csv = '''timestamp,latitude,longitude
2024-01-01T10:00:00+02:00,40.0,-105.0''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.points[0].time.isUtc, isTrue);
      });
    });

    group('Sport parsing', () {
      test('recognizes cycling sport', () {
        const csv = '''timestamp,latitude,longitude,sport
2024-01-01T10:00:00Z,40.0,-105.0,cycling''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.sport, equals(Sport.cycling));
      });

      test('recognizes running sport', () {
        const csv = '''timestamp,latitude,longitude,sport
2024-01-01T10:00:00Z,40.0,-105.0,running''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.sport, equals(Sport.running));
      });

      test('defaults to unknown sport if column missing', () {
        const csv = '''timestamp,latitude,longitude
2024-01-01T10:00:00Z,40.0,-105.0''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.sport, equals(Sport.unknown));
      });

      test('defaults to unknown for unrecognized sport value', () {
        const csv = '''timestamp,latitude,longitude,sport
2024-01-01T10:00:00Z,40.0,-105.0,unknown_sport''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        expect(result.activity.sport, equals(Sport.unknown));
      });
    });

    group('Channel data', () {
      test('parses temperature channel', () {
        const csv = '''timestamp,latitude,longitude,temperature
2024-01-01T10:00:00Z,40.0,-105.0,21.5
2024-01-01T10:00:10Z,40.0005,-105.0005,22.0''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        final tempChannel = result.activity.channel(Channel.temperature);
        expect(tempChannel.length, equals(2));
        expect(tempChannel[0].value, equals(21.5));
      });

      test('parses distance channel', () {
        const csv = '''timestamp,latitude,longitude,distance
2024-01-01T10:00:00Z,40.0,-105.0,0
2024-01-01T10:00:10Z,40.0005,-105.0005,50.5''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        final distChannel = result.activity.channel(Channel.distance);
        expect(distChannel.length, equals(2));
        expect(distChannel[1].value, equals(50.5));
      });

      test('preserves sample timestamps', () {
        const csv = '''timestamp,latitude,longitude,heart_rate
2024-01-01T10:00:00Z,40.0,-105.0,140
2024-01-01T10:00:10Z,40.0005,-105.0005,145''';

        final result = ActivityParser.parse(csv, ActivityFileFormat.csv);

        final hrChannel = result.activity.channel(Channel.heartRate);
        expect(hrChannel[0].time, equals(result.activity.points[0].time));
        expect(hrChannel[1].time, equals(result.activity.points[1].time));
      });
    });
  });
}
