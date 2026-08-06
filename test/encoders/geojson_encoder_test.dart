// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for GeoJSON encoder.
///
/// Tests GeoJSON output with various feature types, properties,
/// and channel data.
library;

import 'dart:convert';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('GeoJSON Encoder', () {
    group('Basic encoding', () {
      test('encodes activity as FeatureCollection', () {
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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        expect(decoded['type'], equals('FeatureCollection'));
        expect(decoded['features'], isList);
        expect(decoded['features'].length, equals(1));
      });

      test('encodes activity as LineString Feature', () {
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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final feature = decoded['features'][0];

        expect(feature['type'], equals('Feature'));
        expect(feature['geometry']['type'], equals('LineString'));
      });

      test('encodes coordinates in correct order (lon, lat)', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final coordinates = decoded['features'][0]['geometry']['coordinates'];

        expect(coordinates[0][0], equals(-105.0)); // longitude first
        expect(coordinates[0][1], equals(40.0)); // latitude second
      });

      test('encodes empty activity', () {
        final activity = RawActivity();

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        expect(decoded['type'], equals('FeatureCollection'));
        expect(decoded['features'].length, equals(1));
        expect(decoded['features'][0]['geometry']['coordinates'], isEmpty);
      });
    });

    group('Properties', () {
      test('includes activity_type property', () {
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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final properties = decoded['features'][0]['properties'];

        expect(properties['activity_type'], equals('cycling'));
      });

      test('includes start_time property', () {
        final startTime = DateTime.utc(2024, 1, 1, 10, 0, 0);
        final activity = RawActivity(
          points: [
            GeoPoint(latitude: 40.0, longitude: -105.0, time: startTime),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final properties = decoded['features'][0]['properties'];

        expect(properties['start_time'], isNotEmpty);
        expect(properties['start_time'], contains('2024-01-01'));
      });

      test('calculates duration property', () {
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
              time: DateTime.utc(2024, 1, 1, 10, 0, 30),
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final properties = decoded['features'][0]['properties'];

        expect(properties['duration'], equals(30.0));
      });

      test('includes lap information', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
              endTime: DateTime.utc(2024, 1, 1, 10, 0, 30),
              avgHeartRate: 140,
              maxHeartRate: 150,
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final properties = decoded['features'][0]['properties'];

        expect(properties['num_laps'], equals(1));
        expect(properties['avg_heart_rate'], equals(140));
        expect(properties['max_heart_rate'], equals(150));
      });

      test('includes device manufacturer if available', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          device: ActivityDeviceMetadata(
            manufacturer: 'Garmin',
            product: 'Fenix 6',
            serialNumber: '12345',
          ),
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final properties = decoded['features'][0]['properties'];

        expect(properties['device_manufacturer'], equals('Garmin'));
      });

      test('handles multiple laps with heart rate averaging', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
              endTime: DateTime.utc(2024, 1, 1, 10, 0, 10),
              avgHeartRate: 140,
              maxHeartRate: 150,
            ),
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 10),
              endTime: DateTime.utc(2024, 1, 1, 10, 0, 20),
              avgHeartRate: 145,
              maxHeartRate: 155,
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final properties = decoded['features'][0]['properties'];

        expect(properties['num_laps'], equals(2));
        expect(properties['avg_heart_rate'], equals(142.5)); // (140 + 145) / 2
        expect(properties['max_heart_rate'], equals(155));
      });

      test('omits total_calories when the activity has no summary', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final properties = decoded['features'][0]['properties'];

        expect(properties, isNot(contains('total_calories')));
        expect(properties, isNot(contains('total_steps')));
      });

      test('total_calories reflects the actual activity summary', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          summary: const ActivitySummary(calories: 512),
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final properties = decoded['features'][0]['properties'];

        expect(properties['total_calories'], equals(512));
      });
    });

    group('Sport types', () {
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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        expect(
          decoded['features'][0]['properties']['activity_type'],
          equals('cycling'),
        );
      });

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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        expect(
          decoded['features'][0]['properties']['activity_type'],
          equals('running'),
        );
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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        expect(
          decoded['features'][0]['properties']['activity_type'],
          equals('swimming'),
        );
      });

      test('encodes unknown sport as unknown', () {
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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        expect(
          decoded['features'][0]['properties']['activity_type'],
          equals('unknown'),
        );
      });
    });

    group('Geometry handling', () {
      test('encodes single point as LineString with single coordinate', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final coordinates = decoded['features'][0]['geometry']['coordinates'];

        expect(coordinates.length, equals(1));
      });

      test('encodes multiple points as LineString', () {
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
            GeoPoint(
              latitude: 40.001,
              longitude: -105.001,
              time: DateTime.utc(2024, 1, 1, 10, 0, 20),
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final coordinates = decoded['features'][0]['geometry']['coordinates'];

        expect(coordinates.length, equals(3));
      });

      test('preserves coordinate precision', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.123456,
              longitude: -105.654321,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);
        final coordinates =
            decoded['features'][0]['geometry']['coordinates'][0];

        expect(coordinates[0], closeTo(-105.654321, 1e-6));
        expect(coordinates[1], closeTo(40.123456, 1e-6));
      });
    });

    group('Valid GeoJSON output', () {
      test('produces valid GeoJSON FeatureCollection', () {
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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        // Should not throw
        expect(decoded['type'], equals('FeatureCollection'));
        expect(decoded['features'].isNotEmpty, isTrue);
      });

      test('produces parseable GeoJSON', () {
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

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final parsed = ActivityParser.parse(
          geojson,
          ActivityFileFormat.geojson,
        );

        expect(parsed.activity.points.length, equals(1));
        expect(parsed.activity.sport, equals(Sport.cycling));
      });
    });

    group('Edge cases', () {
      test('handles activity with null elevation', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              elevation: null,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );

        expect(geojson, isNotEmpty);
      });

      test('handles activity with special characters in creator', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          creator: 'Device "A" & Device <B>',
        );

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        expect(decoded, isNotNull);
      });

      test('handles very large activity', () {
        final points = List.generate(
          1000,
          (i) => GeoPoint(
            latitude: 40.0 + i * 0.0001,
            longitude: -105.0 + i * 0.0001,
            time: DateTime.utc(2024, 1, 1, 10, 0, i),
          ),
        );
        final activity = RawActivity(points: points);

        final geojson = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final decoded = jsonDecode(geojson);

        expect(
          decoded['features'][0]['geometry']['coordinates'].length,
          equals(1000),
        );
      });
    });
  });
}
