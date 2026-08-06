// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for GeoJSON parser.
///
/// Tests GeoJSON Feature and FeatureCollection parsing with various
/// geometry types and property configurations.
library;

import 'dart:convert';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('GeoJSON Parser', () {
    group('Feature parsing', () {
      test('parses Point Feature with coordinates', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {'timestamp': '2024-01-01T10:00:00Z'},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isEmpty,
        );
        expect(result.activity.points.length, equals(1));
        expect(result.activity.points[0].latitude, equals(40.0));
        expect(result.activity.points[0].longitude, equals(-105.0));
      });

      test('parses Point Feature with elevation in coordinates', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0, 1600.0],
          },
          'properties': {'timestamp': '2024-01-01T10:00:00Z'},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points[0].elevation, equals(1600.0));
      });

      test('parses Feature with LineString geometry', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [-105.0, 40.0],
              [-105.0005, 40.0005],
              [-105.001, 40.001],
            ],
          },
          'properties': {'timestamp': '2024-01-01T10:00:00Z'},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points.length, equals(3));
      });

      test('parses Feature properties as channel data', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {
            'timestamp': '2024-01-01T10:00:00Z',
            'heart_rate': 140,
            'cadence': 82,
            'power': 200,
          },
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.channel(Channel.heartRate).length, equals(1));
        expect(result.activity.channel(Channel.cadence).length, equals(1));
        expect(result.activity.channel(Channel.power).length, equals(1));
      });

      test('parses Feature with activity_type property', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {
            'timestamp': '2024-01-01T10:00:00Z',
            'activity_type': 'cycling',
          },
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.sport, equals(Sport.cycling));
      });

      test('defaults to unknown sport if missing', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {'timestamp': '2024-01-01T10:00:00Z'},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.sport, equals(Sport.unknown));
      });
    });

    group('FeatureCollection parsing', () {
      test('parses FeatureCollection with Point features', () {
        final geojson = {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [-105.0, 40.0],
              },
              'properties': {
                'timestamp': '2024-01-01T10:00:00Z',
                'heart_rate': 140,
              },
            },
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [-105.0005, 40.0005],
              },
              'properties': {
                'timestamp': '2024-01-01T10:00:10Z',
                'heart_rate': 145,
              },
            },
          ],
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points.length, equals(2));
        expect(result.activity.channel(Channel.heartRate).length, equals(2));
      });

      test('FeatureCollection with single feature is parsed as Feature', () {
        final geojson = {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [-105.0, 40.0],
              },
              'properties': {'timestamp': '2024-01-01T10:00:00Z'},
            },
          ],
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points.length, equals(1));
      });

      test('handles FeatureCollection with mixed geometry types', () {
        final geojson = {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [-105.0, 40.0],
              },
              'properties': {'timestamp': '2024-01-01T10:00:00Z'},
            },
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [
                  [-105.0005, 40.0005],
                  [-105.001, 40.001],
                ],
              },
              'properties': {'timestamp': '2024-01-01T10:00:10Z'},
            },
          ],
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        // Should fall back to parsing first feature
        expect(result.activity.points, isNotEmpty);
      });
    });

    group('Error handling', () {
      test('reports error for empty GeoJSON', () {
        final result = ActivityParser.parse('{}', ActivityFileFormat.geojson);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test('reports error for invalid JSON', () {
        final result = ActivityParser.parse(
          'not valid json',
          ActivityFileFormat.geojson,
        );

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
        expect(result.diagnostics[0].code, equals('geojson.parse_error'));
      });

      test('reports error for non-object GeoJSON', () {
        final result = ActivityParser.parse('[]', ActivityFileFormat.geojson);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test('reports error for unsupported type', () {
        final geojson = {'type': 'Polygon'};

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test('reports error for Feature without geometry', () {
        final geojson = {'type': 'Feature', 'properties': {}};

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test('reports error for geometry without coordinates', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {'type': 'Point'},
          'properties': {},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test('reports error for empty FeatureCollection', () {
        final geojson = {'type': 'FeatureCollection', 'features': []};

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test(
        'reports a warning and skips a coordinate with non-numeric lon/lat',
        () {
          final geojson = {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [-105.0, 40.0],
                ['bad', 'coord'],
                [-105.1, 40.1],
              ],
            },
            'properties': {},
          };

          final result = ActivityParser.parse(
            jsonEncode(geojson),
            ActivityFileFormat.geojson,
          );

          expect(
            result.diagnostics.any(
              (d) => d.code == 'geojson.point.invalid_coordinate',
            ),
            isTrue,
          );
          expect(result.activity.points, hasLength(2));
        },
      );
    });

    group('Timestamp handling', () {
      test('parses ISO 8601 timestamps from properties', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {'timestamp': '2024-01-01T10:00:00Z'},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points[0].time.isUtc, isTrue);
      });

      test('uses fallback timestamp if not provided', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points[0].time, isA<DateTime>());
      });

      test(
        'reports a warning and falls back to epoch for an unparseable timestamp',
        () {
          final geojson = {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [-105.0, 40.0],
            },
            'properties': {'timestamp': 'not-a-date'},
          };

          final result = ActivityParser.parse(
            jsonEncode(geojson),
            ActivityFileFormat.geojson,
          );

          expect(
            result.diagnostics.any(
              (d) => d.code == 'geojson.point.invalid_timestamp',
            ),
            isTrue,
          );
          expect(
            result.activity.points[0].time,
            equals(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)),
          );
        },
      );
    });

    group('Channel property parsing', () {
      test('parses all channel types from properties', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {
            'timestamp': '2024-01-01T10:00:00Z',
            'heart_rate': 140,
            'cadence': 82,
            'power': 200,
            'temperature': 21.5,
            'speed': 5.5,
            'distance': 100,
          },
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.channel(Channel.heartRate).length, equals(1));
        expect(result.activity.channel(Channel.cadence).length, equals(1));
        expect(result.activity.channel(Channel.power).length, equals(1));
        expect(result.activity.channel(Channel.temperature).length, equals(1));
        expect(result.activity.channel(Channel.speed).length, equals(1));
        expect(result.activity.channel(Channel.distance).length, equals(1));
      });

      test('ignores unknown properties', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {
            'timestamp': '2024-01-01T10:00:00Z',
            'heart_rate': 140,
            'unknown_property': 'ignored',
          },
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.channel(Channel.heartRate).length, equals(1));
        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isEmpty,
        );
      });
    });
  });
}
