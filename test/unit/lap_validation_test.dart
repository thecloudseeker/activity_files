// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for lap boundary validation.
///
/// Tests the validateLapBoundaries() method which detects overlapping laps,
/// inverted times, laps extending beyond points, and other lap boundary issues.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Lap Boundary Validation', () {
    test('validateLapBoundaries detects valid laps', () {
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
          GeoPoint(
            latitude: 40.002,
            longitude: -105.002,
            time: DateTime.utc(2024, 1, 1, 10, 2, 0),
          ),
        ],
        laps: [
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            name: 'Lap 1',
          ),
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 2, 0),
            name: 'Lap 2',
          ),
        ],
      );

      final editor = ActivityFiles.edit(activity);
      final validation = editor.validateLapBoundaries();

      expect(validation.isValid, true);
      expect(validation.hasIssues, false);
      expect(validation.errors, isEmpty);
      expect(validation.warnings, isEmpty);
    });

    test('validateLapBoundaries detects overlapping laps', () {
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
            time: DateTime.utc(2024, 1, 1, 10, 2, 0),
          ),
        ],
        laps: [
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 30),
            name: 'Lap 1',
          ),
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 2, 0),
            name: 'Lap 2',
          ),
        ],
      );

      final editor = ActivityFiles.edit(activity);
      final validation = editor.validateLapBoundaries();

      expect(validation.isValid, false);
      expect(validation.hasIssues, true);
      expect(validation.errors.length, greaterThan(0));
      expect(
        validation.errors.first,
        contains('before the previous lap ended'),
      );
    });

    test('validateLapBoundaries detects inverted lap times', () {
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
            startTime: DateTime.utc(2024, 1, 1, 10, 2, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            name: 'Invalid Lap',
          ),
        ],
      );

      final editor = ActivityFiles.edit(activity);
      final validation = editor.validateLapBoundaries();

      expect(validation.isValid, false);
      expect(validation.errors.first, contains('is not after its start'));
    });

    test('validateLapBoundaries warns about laps extending beyond points', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 1, 0),
          ),
          GeoPoint(
            latitude: 40.001,
            longitude: -105.001,
            time: DateTime.utc(2024, 1, 1, 10, 2, 0),
          ),
        ],
        laps: [
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 3, 0),
            name: 'Extended Lap',
          ),
        ],
      );

      final editor = ActivityFiles.edit(activity);
      final validation = editor.validateLapBoundaries();

      expect(validation.warnings.length, 2);
      expect(validation.warnings[0], contains('before the first point'));
      expect(validation.warnings[1], contains('after the last point'));
    });

    test('validateLapBoundaries handles empty points', () {
      final activity = RawActivity(
        laps: [
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            name: 'Orphan Lap',
          ),
        ],
      );

      final editor = ActivityFiles.edit(activity);
      final validation = editor.validateLapBoundaries();

      expect(validation.warnings.length, 1);
      expect(validation.warnings.first, contains('no GPS points'));
    });

    test('validateLapBoundaries detects non-chronological laps', () {
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
            startTime: DateTime.utc(2024, 1, 1, 10, 2, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 3, 0),
            name: 'Lap 2',
          ),
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            name: 'Lap 1',
          ),
        ],
      );

      final editor = ActivityFiles.edit(activity);
      final validation = editor.validateLapBoundaries();

      expect(validation.isValid, false);
      expect(
        validation.errors.first,
        contains('starts before the previous lap'),
      );
    });

    test('validateLapBoundaries handles no laps', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
        ],
      );

      final editor = ActivityFiles.edit(activity);
      final validation = editor.validateLapBoundaries();

      expect(validation.isValid, true);
      expect(validation.hasIssues, false);
    });

    test('validateLapBoundaries works with sport-specific laps', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 47.55,
            longitude: -122.28,
            time: DateTime.utc(2024, 7, 21, 6, 0),
          ),
          GeoPoint(
            latitude: 47.58,
            longitude: -122.31,
            time: DateTime.utc(2024, 7, 21, 8, 0),
          ),
        ],
        laps: [
          Lap(
            startTime: DateTime.utc(2024, 7, 21, 6, 0),
            endTime: DateTime.utc(2024, 7, 21, 6, 20),
            sport: Sport.swimming,
          ),
          Lap(
            startTime: DateTime.utc(2024, 7, 21, 7, 30),
            endTime: DateTime.utc(2024, 7, 21, 8, 0),
            sport: Sport.running,
          ),
        ],
        sport: Sport.swimming,
      );

      final editor = RawEditor(activity);
      final result = editor.validateLapBoundaries();
      expect(result.isValid, isTrue);
    });
  });
}
