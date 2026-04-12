// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for activity normalization.
///
/// Tests the normalizeActivity() function which sorts points, removes duplicates,
/// filters invalid coordinates, and provides optimization short-circuits.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Normalization Short-Circuit Optimization', () {
    test('normalizeActivity skips work on already-normalized data', () {
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
      final normalized = ActivityFiles.normalizeActivity(activity);

      // Should return same structure (optimization applied)
      expect(normalized.points.length, activity.points.length);
      expect(
        normalized.channels[Channel.heartRate]?.length,
        activity.channels[Channel.heartRate]?.length,
      );
    });

    test('normalizeActivity processes unsorted data', () {
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

      final normalized = ActivityFiles.normalizeActivity(activity);

      expect(normalized.points[0].time, DateTime.utc(2024, 1, 1, 10, 0, 0));
      expect(normalized.points[1].time, DateTime.utc(2024, 1, 1, 10, 1, 0));
    });

    test('normalizeActivity removes duplicate timestamps', () {
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

      final normalized = ActivityFiles.normalizeActivity(activity);

      expect(normalized.points.length, 1);
    });

    test('normalizeActivity removes invalid coordinates', () {
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

      final normalized = ActivityFiles.normalizeActivity(
        activity,
        trimInvalid: true,
      );

      expect(normalized.points.length, 2);
      expect(normalized.points.every((p) => p.latitude.abs() <= 90), true);
    });

    test('normalizeActivity with stats tracks optimization', () {
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

    test('normalizeActivity handles edge case with no operations', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
        ],
      );

      final normalized = ActivityFiles.normalizeActivity(
        activity,
        sortAndDedup: false,
        trimInvalid: false,
      );

      expect(normalized.points.length, activity.points.length);
    });
  });
}
