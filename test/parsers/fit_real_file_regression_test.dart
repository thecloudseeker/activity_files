// SPDX-License-Identifier: BSD-3-Clause
/// Regression tests that pin FIT session/lap field mappings against values
/// cross-checked with the python-fitparse reference implementation of the
/// official FIT profile.
///
/// Session field numbering must exactly match the profile (e.g. avg_speed is
/// field 16, not avg_heart_rate) and durations must decode with the
/// scale-1000 factor applied. These tests exist so field renumbering can
/// never silently regress.
library;

import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  test(
    'committed real-world sample.fit decodes lap durations at scale 1000',
    () {
      // Ground truth via python-fitparse: 1 session (sport running), 2 laps,
      // lap[0].total_elapsed_time == 20.0 s.
      final bytes = File(
        'test/fixtures/real_world/sample.fit',
      ).readAsBytesSync();
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      expect(result.activity.sport, equals(Sport.running));
      expect(result.activity.laps, hasLength(2));
      expect(
        result.activity.laps.first.elapsed,
        equals(const Duration(seconds: 20)),
      );
    },
  );

  test('local device fixture matches python-fitparse ground truth', () {
    // dev/fixtures holds private real-device files and is gitignored, so this
    // test is skipped when the file is absent (e.g. in CI). Ground truth was
    // extracted with python-fitparse from the same file.
    final file = File('dev/fixtures/own_data/fit/4142889450.fit');
    if (!file.existsSync()) return; // CI-safe

    final result = ActivityParser.parseBytes(
      file.readAsBytesSync(),
      ActivityFileFormat.fit,
    );
    final summary = result.activity.summary;

    expect(summary, isNotNull);
    expect(summary!.elapsedTime, equals(const Duration(seconds: 956)));
    expect(summary.timerTime, equals(const Duration(seconds: 956)));
    expect(summary.totalDistanceMeters, closeTo(4225.18, 0.01));
    expect(summary.calories, closeTo(135.0, 0.01));
    expect(summary.avgSpeed, closeTo(4.419, 0.001));
    expect(summary.maxSpeed, closeTo(11.025, 0.001));
    expect(summary.maxHeartRate, closeTo(145.0, 0.01));

    expect(result.activity.laps, isNotEmpty);
    final lap = result.activity.laps.first;
    expect(lap.distanceMeters, closeTo(4225.18, 0.01));
    expect(lap.calories, closeTo(135.0, 0.01));
    expect(lap.avgSpeed, closeTo(4.419, 0.001));
    expect(lap.avgHeartRate, closeTo(119.0, 0.01));
  });
}
