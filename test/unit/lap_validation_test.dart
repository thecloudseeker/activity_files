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

  group('LapValidationResult.diagnostics (0.7.0)', () {
    test('diagnostics is empty for valid laps', () {
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
        laps: [
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
          ),
        ],
      );

      final result = RawEditor(activity).validateLapBoundaries();

      expect(result.diagnostics, isEmpty);
      expect(result.isValid, isTrue);
      expect(result.hasIssues, isFalse);
    });

    test('diagnostics contains error entries for overlapping laps', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
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
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 30),
          ),
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 2, 0),
          ),
        ],
      );

      final result = RawEditor(activity).validateLapBoundaries();

      expect(result.diagnostics, isNotEmpty);
      expect(result.diagnostics.any((d) => d.isError), isTrue);
      expect(result.isValid, isFalse);
    });

    test('diagnostics entries have stable codes and messages', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
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
            endTime: DateTime.utc(2024, 1, 1, 10, 1, 30),
          ),
          Lap(
            startTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
            endTime: DateTime.utc(2024, 1, 1, 10, 2, 0),
          ),
        ],
      );

      final result = RawEditor(activity).validateLapBoundaries();

      for (final d in result.diagnostics) {
        expect(d.code, isNotEmpty);
        expect(d.message, isNotEmpty);
        expect(d.severity, isA<ValidationSeverity>());
      }
    });

    test(
      'diagnostics contains warning entries for laps outside point range',
      () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 5, 0),
            ),
            GeoPoint(
              latitude: 40.001,
              longitude: -105.001,
              time: DateTime.utc(2024, 1, 1, 10, 10, 0),
            ),
          ],
          laps: [
            // Lap starts before the first point
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
              endTime: DateTime.utc(2024, 1, 1, 10, 10, 0),
            ),
          ],
        );

        final result = RawEditor(activity).validateLapBoundaries();

        expect(result.hasIssues, isTrue);
        expect(result.diagnostics, isNotEmpty);
      },
    );

    test(
      'errorDiagnostics and warningDiagnostics filter correctly via ValidationResult shape',
      () {
        // LapValidationResult mirrors ValidationResult — verify filtered views work
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
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
              endTime: DateTime.utc(2024, 1, 1, 10, 1, 30),
            ),
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 1, 0),
              endTime: DateTime.utc(2024, 1, 1, 10, 2, 0),
            ),
          ],
        );

        final result = RawEditor(activity).validateLapBoundaries();

        // All error diagnostics must be errors
        for (final d in result.diagnostics.where((d) => d.isError)) {
          expect(d.severity, equals(ValidationSeverity.error));
        }
        // All warning diagnostics must be warnings
        for (final d in result.diagnostics.where((d) => !d.isError)) {
          expect(d.severity, equals(ValidationSeverity.warning));
        }
      },
    );
  });
}
