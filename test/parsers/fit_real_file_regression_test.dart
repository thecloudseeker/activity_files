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
    const path = 'dev/fixtures/own_data/fit/4142889450.fit';
    final file = File(path);
    if (!file.existsSync()) {
      markTestSkipped('Local-only fixture $path is absent.');
      return;
    }

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

  test('local device fixture with only enhanced speed fields matches '
      'garmin-fit-sdk ground truth', () {
    // The session and lap of this file carry enhanced_avg_speed and
    // enhanced_max_speed only, and its records enhanced_speed only. Ground
    // truth was extracted with garmin-fit-sdk from the same file.
    const path = 'dev/fixtures/user_data/21485067005_ACTIVITY.fit';
    final file = File(path);
    if (!file.existsSync()) {
      markTestSkipped('Local-only fixture $path is absent.');
      return;
    }

    final activity = ActivityParser.parseBytes(
      file.readAsBytesSync(),
      ActivityFileFormat.fit,
    ).activity;

    expect(activity.summary!.avgSpeed, closeTo(1.098, 0.0005));
    expect(activity.summary!.maxSpeed, closeTo(2.239, 0.0005));
    expect(activity.laps.first.avgSpeed, closeTo(1.098, 0.0005));
    expect(activity.laps.first.maxSpeed, closeTo(2.239, 0.0005));
    expect(activity.channel(Channel.speed), isNotEmpty);
  });

  test('garmin-fenix-5-bike.fit matches garmin-fit-sdk ground truth', () {
    // Cross-checked against Garmin's official garmin-fit-sdk. Fixture
    // source: https://github.com/dtcooper/python-fitparse (tests/files/),
    // MIT.
    //
    // This file's vendor-specific messages (global IDs 79 and 141) are not
    // GPS records; their fields must not be read as lat/lon/altitude/
    // heart-rate.
    final bytes = File(
      'test/fixtures/real_world/garmin-fenix-5-bike.fit',
    ).readAsBytesSync();
    final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
    final activity = result.activity;

    expect(activity.points, hasLength(19));

    final first = activity.points.first;
    expect(first.latitude, closeTo(37.41116, 0.0001));
    expect(first.longitude, closeTo(-122.069067, 0.0001));

    final last = activity.points.last;
    expect(last.latitude, closeTo(37.415271, 0.0001));
    expect(last.longitude, closeTo(-122.06886, 0.0001));

    final heartRate = activity.channel(Channel.heartRate);
    expect(heartRate, hasLength(19));
    expect(
      heartRate.map((s) => s.value),
      everyElement(inClosedOpenRange(77, 115)),
    );

    expect(activity.laps, hasLength(1));
    expect(
      result.diagnostics,
      contains(
        isA<ParseDiagnostic>()
            .having((d) => d.code, 'code', 'fit.message.vendor_skipped')
            .having((d) => d.message, 'message', contains('79'))
            .having((d) => d.message, 'message', contains('141')),
      ),
    );
  });

  // Strap heart rate stored in hr messages inside chained segments. Ground
  // truth was extracted with garmin-fit-sdk (heart rate merging on) from the
  // same files: the number of records with a heart rate, their mean, and the
  // first and last values.
  for (final (name, count, mean, first, last) in [
    (
      'event_timestamp.fit',
      4376,
      138.2856,
      [95, 92, 91, 90, 91, 92],
      [139, 137, 136, 134],
    ),
    (
      'sample_mulitple_header.fit',
      1773,
      171.6627,
      [138, 138, 139, 143, 148, 156],
      [185, 186, 186, 186],
    ),
  ]) {
    test('local fixture $name merges hr messages like garmin-fit-sdk', () {
      final path = 'dev/fixtures/third_party/fit/$name';
      final file = File(path);
      if (!file.existsSync()) {
        markTestSkipped('Local-only fixture $path is absent.');
        return;
      }

      final result = ActivityParser.parseBytes(
        file.readAsBytesSync(),
        ActivityFileFormat.fit,
      );
      final heartRate = [
        for (final sample in result.activity.channel(Channel.heartRate))
          sample.value,
      ];

      expect(heartRate, hasLength(count));
      expect(
        heartRate.reduce((a, b) => a + b) / heartRate.length,
        closeTo(mean, 0.00005),
      );
      expect(heartRate.take(6), first);
      expect(heartRate.skip(heartRate.length - 4), last);
      expect(result.diagnostics.map((d) => d.code), contains('fit.hr.merged'));
    });
  }
}
