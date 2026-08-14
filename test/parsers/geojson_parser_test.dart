// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for GeoJSON parser.
///
/// Tests GeoJSON Feature and FeatureCollection parsing with various
/// geometry types and property configurations.
library;

import 'dart:convert';
import 'dart:io';

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

      test('parses Feature with MultiLineString geometry', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'MultiLineString',
            'coordinates': [
              [
                [-105.0, 40.0],
                [-105.0005, 40.0005],
              ],
              [
                [-106.0, 41.0],
                [-106.0005, 41.0005],
              ],
            ],
          },
          'properties': {'timestamp': '2024-01-01T10:00:00Z'},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points.length, equals(4));
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

      test('keeps the LineString and reports the dropped Point in a mixed '
          'FeatureCollection', () {
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

        expect(result.activity.points, hasLength(2));
        expect(result.activity.additionalTracks, isEmpty);
        expect(
          result.diagnostics.any(
            (d) => d.code == 'geojson.point_features_dropped',
          ),
          isTrue,
        );
      });

      test('keeps valid track features when another feature in the same '
          'collection has a non-object geometry', () {
        final geojson = {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [
                  [-105.0, 40.0],
                  [-105.001, 40.001],
                ],
              },
              'properties': {},
            },
            {'type': 'Feature', 'geometry': 'not-an-object', 'properties': {}},
          ],
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points, hasLength(2));
        expect(
          result.diagnostics.any(
            (d) => d.code == 'geojson.malformed_feature_dropped',
          ),
          isTrue,
        );
      });

      test('keeps every non-Point feature as additionalTracks instead of '
          'dropping all but the first', () {
        final geojson = {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [
                  [-105.0, 40.0],
                  [-105.001, 40.001],
                ],
              },
              'properties': {},
            },
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [
                  [-106.0, 41.0],
                  [-106.001, 41.001],
                  [-106.002, 41.002],
                ],
              },
              'properties': {},
            },
          ],
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points, hasLength(2));
        expect(result.activity.additionalTracks, hasLength(1));
        expect(result.activity.additionalTracks.first.points, hasLength(3));
      });

      test(
        'reports a warning and skips a malformed point in a Point FeatureCollection',
        () {
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
                  'type': 'Point',
                  'coordinates': [-105.0005], // too short
                },
                'properties': {'timestamp': '2024-01-01T10:00:10Z'},
              },
            ],
          };

          final result = ActivityParser.parse(
            jsonEncode(geojson),
            ActivityFileFormat.geojson,
          );

          expect(result.activity.points, hasLength(1));
          expect(
            result.diagnostics.any(
              (d) => d.code == 'geojson.point.invalid_coordinate',
            ),
            isTrue,
          );
        },
      );

      test('reports a warning and skips a Point feature with no coordinates '
          'in a FeatureCollection', () {
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
              'geometry': {'type': 'Point'}, // no 'coordinates' key
              'properties': {'timestamp': '2024-01-01T10:00:10Z'},
            },
          ],
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points, hasLength(1));
        expect(
          result.diagnostics.any(
            (d) => d.code == 'geojson.point.invalid_coordinate',
          ),
          isTrue,
        );
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

      test('treats a properties.timestamp without a UTC offset as UTC', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [-105.0, 40.0],
          },
          'properties': {'timestamp': '2024-01-01T10:00:00'},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(
          result.activity.points[0].time,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
        );
      });

      test(
        'treats coordinateProperties.times entries without a UTC offset as UTC',
        () {
          final geojson = {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [-105.0, 40.0],
                [-105.001, 40.001],
              ],
            },
            'properties': {
              'coordinateProperties': {
                'times': ['2024-01-01T10:00:00', '2024-01-01T10:00:10'],
              },
            },
          };

          final result = ActivityParser.parse(
            jsonEncode(geojson),
            ActivityFileFormat.geojson,
          );

          expect(
            result.activity.points[0].time,
            equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
          );
          expect(
            result.activity.points[1].time,
            equals(DateTime.utc(2024, 1, 1, 10, 0, 10)),
          );
        },
      );

      test(
        'reads per-point times from properties.coordTimes on a LineString',
        () {
          final geojson = {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [-105.0, 40.0],
                [-105.001, 40.001],
              ],
            },
            'properties': {
              'coordTimes': ['2024-01-01T10:00:00Z', '2024-01-01T10:00:10Z'],
            },
          };

          final result = ActivityParser.parse(
            jsonEncode(geojson),
            ActivityFileFormat.geojson,
          );

          expect(
            result.activity.points[0].time,
            equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
          );
          expect(
            result.activity.points[1].time,
            equals(DateTime.utc(2024, 1, 1, 10, 0, 10)),
          );
        },
      );

      test('reads per-line coordTimes on a MultiLineString', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'MultiLineString',
            'coordinates': [
              [
                [-105.0, 40.0],
                [-105.001, 40.001],
              ],
              [
                [-106.0, 41.0],
                [-106.001, 41.001],
              ],
            ],
          },
          'properties': {
            'coordTimes': [
              ['2024-01-01T10:00:00Z', '2024-01-01T10:00:10Z'],
              ['2024-01-01T11:00:00Z', '2024-01-01T11:00:10Z'],
            ],
          },
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(
          result.activity.points.map((p) => p.time),
          equals([
            DateTime.utc(2024, 1, 1, 10, 0, 0),
            DateTime.utc(2024, 1, 1, 10, 0, 10),
            DateTime.utc(2024, 1, 1, 11, 0, 0),
            DateTime.utc(2024, 1, 1, 11, 0, 10),
          ]),
        );
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

      test('reports one warning, not one per point, for a shared invalid '
          'feature-level timestamp', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (var i = 0; i < 50; i++) [-105.0 - i * 0.001, 40.0],
            ],
          },
          'properties': {'timestamp': 'not-a-date'},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points, hasLength(50));
        expect(
          result.diagnostics
              .where((d) => d.code == 'geojson.point.invalid_timestamp')
              .length,
          equals(1),
        );
      });
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

      test(
        'a scalar feature-level numeric property on a multi-point '
        'LineString becomes metadata, not a channel broadcast at every point',
        () {
          final geojson = {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (var i = 0; i < 5; i++) [-105.0 - i * 0.001, 40.0],
              ],
            },
            'properties': {'elevation_gain': 150},
          };

          final result = ActivityParser.parse(
            jsonEncode(geojson),
            ActivityFileFormat.geojson,
          );

          expect(result.activity.points, hasLength(5));
          expect(
            result.activity.channel(Channel.custom('elevation_gain')),
            isEmpty,
          );
          expect(result.activity.metadata['elevation_gain'], 150);
        },
      );

      test('total_calories and device_manufacturer are captured into '
          'summary/device, not dropped', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [-105.0, 40.0],
              [-105.001, 40.001],
            ],
          },
          'properties': {
            'total_calories': 450,
            'device_manufacturer': 'Garmin',
          },
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.summary?.calories, equals(450.0));
        expect(result.activity.device?.manufacturer, equals('Garmin'));
        expect(result.activity.metadata.containsKey('total_calories'), isFalse);
        expect(
          result.activity.metadata.containsKey('device_manufacturer'),
          isFalse,
        );
      });

      test('total_steps has no structured field to regenerate it from, so '
          'it round-trips via metadata instead of being dropped', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [-105.0, 40.0],
              [-105.001, 40.001],
            ],
          },
          'properties': {'total_steps': 3200},
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.metadata['total_steps'], equals(3200));
        expect(result.activity.channel(Channel.custom('total_steps')), isEmpty);
      });

      test('reads per-line coordinateProperties.channels on a '
          'MultiLineString', () {
        final geojson = {
          'type': 'Feature',
          'geometry': {
            'type': 'MultiLineString',
            'coordinates': [
              [
                [-105.0, 40.0],
                [-105.001, 40.001],
              ],
              [
                [-106.0, 41.0],
                [-106.001, 41.001],
              ],
            ],
          },
          'properties': {
            'coordinateProperties': {
              'channels': {
                'heart_rate': [
                  [140, 142],
                  [150, 151],
                ],
              },
            },
          },
        };

        final result = ActivityParser.parse(
          jsonEncode(geojson),
          ActivityFileFormat.geojson,
        );

        expect(result.activity.points, hasLength(4));
        expect(
          result.activity.channel(Channel.heartRate).map((s) => s.value),
          equals([140, 142, 150, 151]),
        );
      });
    });

    group('Real fixture regression', () {
      test(
        'togeojson_multitrackgpx.geojson keeps all 3 tracks and real times',
        () {
          // Ground truth cross-checked against geojson_vi and turf/geotypes
          // (two independent GeoJSON readers) and against the .gpx sibling
          // of this same fixture, read by four independent GPX tools.
          final bytes = File(
            'test/fixtures/real_world/togeojson_multitrackgpx.geojson',
          ).readAsBytesSync();
          final result = ActivityParser.parseBytes(
            bytes,
            ActivityFileFormat.geojson,
          );

          final totalPoints =
              result.activity.points.length +
              result.activity.additionalTracks.fold<int>(
                0,
                (sum, t) => sum + t.points.length,
              );

          expect(result.activity.additionalTracks, hasLength(2));
          expect(totalPoints, equals(5235));
          expect(
            result.activity.points.first.time,
            equals(DateTime.utc(2008, 7, 12, 9, 58, 23)),
          );
          expect(
            result.activity.additionalTracks.last.points.last.time,
            equals(DateTime.utc(2008, 7, 14, 12, 46, 2)),
          );
        },
      );
    });
  });
}
