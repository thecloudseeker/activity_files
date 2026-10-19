// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for activity normalization: sorting, removing duplicates,
/// filtering invalid coordinates, and the short-circuit for data that is
/// already normalized.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// Normalizes [activity] the way `export` and `convert` do by default.
RawActivity _normalized(RawActivity activity) => ActivityFiles.export(
  activity: activity,
  to: ActivityFileFormat.gpx,
).activity;

void main() {
  group('Normalization Short-Circuit Optimization', () {
    test('normalization skips work on already-normalized data', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
          GeoPoint(
            latitude: 40.001,
            longitude: -105.001,
            time: DateTime.utc(2024, 1, 1, 10, 1, 0),
          ),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
            Sample(time: DateTime.utc(2024, 1, 1, 10, 1, 0), value: 142),
          ],
        },
        laps: [
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            name: 'Lap 1',
          ),
        ],
      );

      // Data is already sorted and valid
      final normalized = _normalized(activity);

      // Should return same structure (optimization applied)
      expect(normalized.points.length, activity.points.length);
      expect(
        normalized.channels[Channel.heartRate]?.length,
        activity.channels[Channel.heartRate]?.length,
      );
    });

    test('normalization processes unsorted data', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.001,
            longitude: -105.001,
            time: DateTime.utc(2024, 1, 1, 10, 1, 0),
          ),
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
        ],
      );

      final normalized = _normalized(activity);

      expect(normalized.points[0].time, DateTime.utc(2024, 1, 1, 10, 0, 0));
      expect(normalized.points[1].time, DateTime.utc(2024, 1, 1, 10, 1, 0));
    });

    test('normalization removes duplicate timestamps', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
        ],
      );

      final normalized = _normalized(activity);

      expect(normalized.points.length, 1);
    });

    test('normalization removes invalid coordinates', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
          GeoPoint(
            latitude: 200.0, // Invalid
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 1, 0),
          ),
          GeoPoint(
            latitude: 40.001,
            longitude: -105.001,
            time: DateTime.utc(2024, 1, 1, 10, 2, 0),
          ),
        ],
      );

      final normalized = _normalized(activity);

      expect(normalized.points.length, 2);
      expect(normalized.points.every((p) => p.latitude.abs() <= 90), true);
    });

    test('normalization with stats tracks optimization', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
        ],
      );

      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.gpx,
        normalize: true,
      );

      expect(result.processingStats.normalization, isNotNull);
      expect(result.processingStats.normalization!.applied, true);
      expect(
        result.processingStats.normalization!.pointsBefore,
        result.processingStats.normalization!.pointsAfter,
      );
    });

    test(
      'normalization removes a Null Island point even on time-sorted input',
      () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 0.0,
              longitude: 0.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final normalized = _normalized(activity);

        expect(normalized.points, hasLength(1));
        expect(normalized.points.single.latitude, equals(40.0));

        final exported = ActivityFiles.export(
          activity: activity,
          to: ActivityFileFormat.csv,
          normalize: true,
        );
        expect(
          exported.diagnostics.any(
            (d) => d.code == 'repaired.sentinel_coords_removed',
          ),
          isTrue,
        );
      },
    );

    test(
      'normalization clears a sentinel elevation even on time-sorted input',
      () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              elevation: -500.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.001,
              longitude: -105.001,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final normalized = _normalized(activity);

        expect(normalized.points, hasLength(2));
        expect(normalized.points.first.elevation, isNull);
      },
    );

    test('normalization clips a lap extending past the point range even on '
        'time-sorted, coordinate-valid input', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
          GeoPoint(
            latitude: 40.001,
            longitude: -105.001,
            time: DateTime.utc(2024, 1, 1, 10, 0, 10),
          ),
        ],
        laps: [
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 5, 0),
          ),
        ],
      );

      final normalized = _normalized(activity);

      expect(
        normalized.laps.single.endTime,
        equals(DateTime.utc(2024, 1, 1, 10, 0, 10)),
      );
    });
  });
}
