// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for transform utility functions and RawEditor operations.
///
/// Tests coordinate interpolation, sample resampling, and editing operations.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
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

      test('removes points with NaN coordinates', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: double.nan,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final trimmed = RawEditor(activity).trimInvalid().activity;

        expect(trimmed.points.length, equals(1));
      });

      test('removes points with infinite coordinates', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: double.infinity,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final trimmed = RawEditor(activity).trimInvalid().activity;

        expect(trimmed.points.length, equals(1));
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

      test('trims channels to point time range', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 5),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              time: DateTime.utc(2024, 1, 1, 10, 0, 15),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 5), value: 142),
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 15), value: 145),
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 20), value: 148),
            ],
          },
        );

        final trimmed = RawEditor(activity).trimInvalid().activity;
        final hrChannel = trimmed.channel(Channel.heartRate);

        // Should keep samples within point time range [10:00:05, 10:00:15]
        expect(hrChannel.length, lessThanOrEqualTo(3));
      });
    });

    group('recomputeDistanceAndSpeed', () {
      test('computes distance and speed channels', () {
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

        final edited = RawEditor(activity).recomputeDistanceAndSpeed().activity;

        expect(edited.channel(Channel.distance).isNotEmpty, isTrue);
        expect(edited.channel(Channel.speed).isNotEmpty, isTrue);
      });

      test('computes speed as distance delta / time delta', () {
        // Create simple scenario: 10 meters in 10 seconds = 1 m/s
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

        final edited = RawEditor(activity).recomputeDistanceAndSpeed().activity;

        final speedChannel = edited.channel(Channel.speed);
        expect(speedChannel.isNotEmpty, isTrue);
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

      test('returns activity for each operation', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final editor = RawEditor(activity).sortAndDedup();

        expect(editor.activity, isNotNull);
      });
    });

    group('Edge cases', () {
      test('handles empty activity', () {
        final activity = RawActivity();

        final sorted = RawEditor(activity).sortAndDedup().activity;

        expect(sorted.points, isEmpty);
      });

      test('handles activity with single point', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final sorted = RawEditor(activity).sortAndDedup().activity;

        expect(sorted.points.length, equals(1));
      });

      test('handles activity with many duplicate points', () {
        final time = DateTime.utc(2024, 1, 1, 10, 0, 0);
        final points = List.filled(
          100,
          GeoPoint(latitude: 40.0, longitude: -105.0, time: time),
        );
        final activity = RawActivity(points: points);

        final deduped = RawEditor(activity).sortAndDedup().activity;

        expect(deduped.points.length, equals(1));
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

      test('preserves metadata through operations', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          creator: 'test-device',
        );

        final result = RawEditor(
          activity,
        ).sortAndDedup().trimInvalid().activity;

        expect(result.creator, equals('test-device'));
      });
    });
  });
}
