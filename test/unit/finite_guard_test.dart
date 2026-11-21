// SPDX-License-Identifier: BSD-3-Clause
library;

import 'package:activity_files/activity_files.dart';
import 'package:activity_files/src/encode/finite_guard.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2024, 1, 1, 10);

void main() {
  test('an activity without non-finite values comes back unchanged', () {
    final activity = RawActivity(
      points: [GeoPoint(latitude: 46, longitude: 13, time: _t0)],
      laps: [Lap(startTime: _t0, endTime: _t0, calories: 10)],
      summary: const ActivitySummary(calories: 10),
    );
    final report = NonFiniteReport();
    expect(identical(dropNonFinite(activity, report), activity), isTrue);
    expect(report.isEmpty, isTrue);
  });

  test('only the non-finite lap value is cleared', () {
    final lap = Lap(
      startTime: _t0,
      endTime: _t0.add(const Duration(minutes: 5)),
      distanceMeters: 1000,
      name: 'lap 1',
      sport: Sport.running,
      calories: double.nan,
      avgHeartRate: 140,
      swimStroke: SwimStroke.freestyle,
      tcxIntensity: 'Active',
      extraFitFields: {200: 1.5, 201: double.infinity},
      extraFitArrays: {
        202: [1, double.nan, 3],
      },
    );
    final report = NonFiniteReport();
    final cleaned = dropNonFinite(RawActivity(laps: [lap]), report).laps.single;

    expect(cleaned.calories, isNull);
    expect(cleaned.distanceMeters, 1000);
    expect(cleaned.name, 'lap 1');
    expect(cleaned.sport, Sport.running);
    expect(cleaned.avgHeartRate, 140);
    expect(cleaned.swimStroke, SwimStroke.freestyle);
    expect(cleaned.tcxIntensity, 'Active');
    expect(cleaned.extraFitFields, {200: 1.5});
    expect(cleaned.extraFitArrays, {
      202: [1.0, 3.0],
    });
    expect(cleaned.startTime, lap.startTime);
    expect(cleaned.endTime, lap.endTime);
    expect(report.counts, {'lap values': 3});
  });

  test('points, elevations and samples are reported by kind', () {
    final activity = RawActivity(
      points: [
        GeoPoint(latitude: 46, longitude: 13, time: _t0),
        GeoPoint(
          latitude: double.nan,
          longitude: 13,
          time: _t0.add(const Duration(seconds: 1)),
        ),
        GeoPoint(
          latitude: 46,
          longitude: 13,
          elevation: double.infinity,
          time: _t0.add(const Duration(seconds: 2)),
        ),
      ],
      channels: {
        Channel.heartRate: [
          Sample(time: _t0, value: 140),
          Sample(time: _t0.add(const Duration(seconds: 1)), value: double.nan),
        ],
      },
      summary: const ActivitySummary(calories: double.nan, avgPower: 200),
    );
    final report = NonFiniteReport();
    final cleaned = dropNonFinite(activity, report);

    expect(cleaned.points, hasLength(2));
    expect(cleaned.points.last.elevation, isNull);
    expect(cleaned.channel(Channel.heartRate), hasLength(1));
    expect(cleaned.summary!.calories, isNull);
    expect(cleaned.summary!.avgPower, 200);
    expect(report.counts, {
      'points': 1,
      'elevations': 1,
      'heart_rate samples': 1,
      'summary values': 1,
    });
  });
}
