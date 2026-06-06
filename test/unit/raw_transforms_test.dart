// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for RawTransforms static utilities and RawEditor transformations.
///
/// Tests resampling, distance computation, and editing operations.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('RawTransforms', () {
    group('computeCumulativeDistance', () {
      test('computes zero distance for single point', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final result = RawTransforms.computeCumulativeDistance(activity);

        expect(result.totalDistance, equals(0.0));
        final distChannel = result.activity.channel(Channel.distance);
        expect(distChannel.length, equals(1));
        expect(distChannel[0].value, equals(0.0));
      });

      test('computes distance between two points', () {
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

        final result = RawTransforms.computeCumulativeDistance(activity);

        expect(result.totalDistance, greaterThan(0));
        expect(result.activity.channel(Channel.distance).length, equals(2));
      });

      test('computes cumulative distance', () {
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
              time: DateTime.utc(2024, 1, 1, 10, 0, 5),
            ),
            GeoPoint(
              latitude: 40.001,
              longitude: -105.001,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final result = RawTransforms.computeCumulativeDistance(activity);

        final distChannel = result.activity.channel(Channel.distance);
        expect(distChannel[0].value, equals(0.0));
        expect(distChannel[1].value, greaterThan(0));
        expect(distChannel[2].value, greaterThan(distChannel[1].value));
        expect(result.totalDistance, equals(distChannel[2].value));
      });

      test('handles empty activity', () {
        final activity = RawActivity();

        final result = RawTransforms.computeCumulativeDistance(activity);

        expect(result.totalDistance, equals(0.0));
      });

      test('adds distance channel to activity without existing distance', () {
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
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
            ],
          },
        );

        final result = RawTransforms.computeCumulativeDistance(activity);

        expect(result.activity.channel(Channel.distance).isNotEmpty, isTrue);
        expect(result.activity.channel(Channel.heartRate).isNotEmpty, isTrue);
      });

      test('uses haversine formula for distance', () {
        // Denver, CO to Boulder, CO (approximate 45 km apart)
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 39.7392,
              longitude: -104.9903,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0150,
              longitude: -105.2705,
              time: DateTime.utc(2024, 1, 1, 10, 30, 0),
            ),
          ],
        );

        final result = RawTransforms.computeCumulativeDistance(activity);

        // Haversine formula should give approximately 45 km
        expect(result.totalDistance, greaterThan(35000)); // at least 35 km
        expect(result.totalDistance, lessThan(42000)); // less than 42 km
      });
    });

    group('resample', () {
      test('resamples activity to fixed time step', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0010,
              longitude: -105.0010,
              time: DateTime.utc(2024, 1, 1, 10, 1, 0),
            ),
          ],
        );

        final resampled = RawTransforms.resample(
          activity,
          step: const Duration(seconds: 10),
        );

        // Should have more points than original
        expect(resampled.points.length, greaterThan(2));
      });

      test('requires positive step duration', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        expect(
          () => RawTransforms.resample(activity, step: Duration.zero),
          throwsArgumentError,
        );
      });

      test('preserves endpoints', () {
        final startTime = DateTime.utc(2024, 1, 1, 10, 0, 0);
        final endTime = DateTime.utc(2024, 1, 1, 10, 1, 0);
        final activity = RawActivity(
          points: [
            GeoPoint(latitude: 40.0, longitude: -105.0, time: startTime),
            GeoPoint(latitude: 40.0010, longitude: -105.0010, time: endTime),
          ],
        );

        final resampled = RawTransforms.resample(
          activity,
          step: const Duration(seconds: 10),
        );

        expect(resampled.points.first.time, equals(startTime));
        expect(resampled.points.last.time, equals(endTime));
      });

      test('handles single-point activity', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final resampled = RawTransforms.resample(
          activity,
          step: const Duration(seconds: 10),
        );

        expect(resampled.points.length, equals(1));
      });

      test('interpolates coordinates linearly', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0010,
              longitude: -105.0010,
              time: DateTime.utc(2024, 1, 1, 10, 0, 20),
            ),
          ],
        );

        final resampled = RawTransforms.resample(
          activity,
          step: const Duration(seconds: 10),
        );

        // At t=10s, should have interpolated point
        final midpoint = resampled.points.firstWhere(
          (p) => p.time == DateTime.utc(2024, 1, 1, 10, 0, 10),
          orElse: () => GeoPoint(
            latitude: 0,
            longitude: 0,
            time: DateTime.utc(2024, 1, 1),
          ),
        );

        expect(midpoint.latitude, closeTo(40.0005, 0.0001));
        expect(midpoint.longitude, closeTo(-105.0005, 0.0001));
      });

      test('uses nearest neighbor for heart rate', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0010,
              longitude: -105.0010,
              time: DateTime.utc(2024, 1, 1, 10, 0, 20),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 20), value: 150),
            ],
          },
        );

        final resampled = RawTransforms.resample(
          activity,
          step: const Duration(seconds: 5),
        );

        final hrChannel = resampled.channel(Channel.heartRate);
        expect(hrChannel.isNotEmpty, isTrue);
        // Values should be one of 140 or 150 (nearest neighbor)
        for (final sample in hrChannel) {
          expect([140, 150], contains(sample.value));
        }
      });

      test('preserves empty channels', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0010,
              longitude: -105.0010,
              time: DateTime.utc(2024, 1, 1, 10, 0, 20),
            ),
          ],
          channels: {Channel.heartRate: []},
        );

        final resampled = RawTransforms.resample(
          activity,
          step: const Duration(seconds: 5),
        );

        expect(resampled.channel(Channel.heartRate), isEmpty);
      });
    });
  });

  group('RawEditor', () {
    group('sortAndDedup', () {
      test('sorts points by time', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.001,
              longitude: -105.001,
              time: DateTime.utc(2024, 1, 1, 10, 0, 20),
            ),
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

        final sorted = RawEditor(activity).sortAndDedup().activity;

        expect(
          sorted.points[0].time,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
        );
        expect(
          sorted.points[1].time,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 10)),
        );
        expect(
          sorted.points[2].time,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 20)),
        );
      });

      test('removes duplicate points with same timestamp', () {
        final time = DateTime.utc(2024, 1, 1, 10, 0, 0);
        final activity = RawActivity(
          points: [
            GeoPoint(latitude: 40.0, longitude: -105.0, time: time),
            GeoPoint(latitude: 40.0, longitude: -105.0, time: time),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final deduped = RawEditor(activity).sortAndDedup().activity;

        expect(deduped.points.length, equals(2));
      });

      test('sorts channel samples by time', () {
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
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 20), value: 150),
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 10), value: 145),
            ],
          },
        );

        final sorted = RawEditor(activity).sortAndDedup().activity;
        final hrChannel = sorted.channel(Channel.heartRate);

        expect(hrChannel[0].time, equals(DateTime.utc(2024, 1, 1, 10, 0, 0)));
        expect(hrChannel[1].time, equals(DateTime.utc(2024, 1, 1, 10, 0, 10)));
        expect(hrChannel[2].time, equals(DateTime.utc(2024, 1, 1, 10, 0, 20)));
      });

      test('removes duplicate samples with same timestamp', () {
        final time = DateTime.utc(2024, 1, 1, 10, 0, 0);
        final activity = RawActivity(
          points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: time)],
          channels: {
            Channel.heartRate: [
              Sample(time: time, value: 140),
              Sample(time: time, value: 141),
            ],
          },
        );

        final deduped = RawEditor(activity).sortAndDedup().activity;
        final hrChannel = deduped.channel(Channel.heartRate);

        expect(hrChannel.length, equals(1));
      });

      test('sorts laps by start time', () {
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
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 20),
              endTime: DateTime.utc(2024, 1, 1, 10, 0, 30),
            ),
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
              endTime: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final sorted = RawEditor(activity).sortAndDedup().activity;

        expect(
          sorted.laps[0].startTime,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
        );
        expect(
          sorted.laps[1].startTime,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 20)),
        );
      });
    });

    group('trimInvalid', () {
      test('removes points with invalid latitude', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 91.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              time: DateTime.utc(2024, 1, 1, 10, 0, 20),
            ),
          ],
        );

        final trimmed = RawEditor(activity).trimInvalid().activity;

        expect(trimmed.points.length, equals(2));
      });

      test('removes points with invalid longitude', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -181.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
            GeoPoint(
              latitude: 40.001,
              longitude: -105.001,
              time: DateTime.utc(2024, 1, 1, 10, 0, 20),
            ),
          ],
        );

        final trimmed = RawEditor(activity).trimInvalid().activity;

        expect(trimmed.points.length, equals(2));
      });

      test('accepts boundary latitude values', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: -90.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 90.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final trimmed = RawEditor(activity).trimInvalid().activity;

        expect(trimmed.points.length, equals(2));
      });

      test('accepts boundary longitude values', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -180.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0,
              longitude: 180.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final trimmed = RawEditor(activity).trimInvalid().activity;

        expect(trimmed.points.length, equals(2));
      });
    });

    group('Chaining operations', () {
      test('chains sortAndDedup with trimInvalid', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.001,
              longitude: -105.001,
              time: DateTime.utc(2024, 1, 1, 10, 0, 20),
            ),
            GeoPoint(
              latitude: 91.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final result = RawEditor(
          activity,
        ).sortAndDedup().trimInvalid().activity;

        expect(result.points.length, equals(2));
        expect(
          result.points[0].time,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
        );
      });
    });

    group('Edge cases', () {
      test('handles empty activity', () {
        final activity = RawActivity();

        final sorted = RawEditor(activity).sortAndDedup().activity;

        expect(sorted.points, isEmpty);
      });

      test('preserves sport type through operations', () {
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

        final result = RawEditor(
          activity,
        ).sortAndDedup().trimInvalid().activity;

        expect(result.sport, equals(Sport.cycling));
      });
    });
  });
}
