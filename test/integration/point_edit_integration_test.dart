// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for chained RawEditor point-editing operations.
///
/// These tests verify that multiple edit operations compose correctly and that
/// the full round-trip behaviour is correct when building activities inline.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/matchers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

GeoPoint _pt(double lat, double lon, DateTime time, {double? elevation}) =>
    GeoPoint(latitude: lat, longitude: lon, elevation: elevation, time: time);

Sample _sample(DateTime time, double value) => Sample(time: time, value: value);

Lap _lap(DateTime start, DateTime end) => Lap(startTime: start, endTime: end);

WorkoutSet _set(DateTime start, DateTime end, {bool isRest = false}) =>
    WorkoutSet(startTime: start, endTime: end, isRest: isRest);

/// Returns a simple activity with [count] points at 10-second intervals
/// starting at [base], each shifted 0.001 degrees per step.
RawActivity _buildActivity(
  DateTime base,
  int count, {
  bool withHr = false,
  List<Lap>? laps,
  List<WorkoutSet>? sets,
}) {
  final points = List.generate(
    count,
    (i) => _pt(
      40.0 + i * 0.001,
      -105.0 + i * 0.001,
      base.add(Duration(seconds: i * 10)),
      elevation: 1600.0 + i,
    ),
  );
  final channels = <Channel, List<Sample>>{};
  if (withHr) {
    channels[Channel.heartRate] = List.generate(
      count,
      (i) => _sample(base.add(Duration(seconds: i * 10)), 140.0 + i),
    );
  }
  return RawActivity(
    points: points,
    channels: channels,
    laps: laps ?? [],
    sets: sets ?? [],
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('insertPause + shiftTime compose correctly', () {
    test('total offset equals sum of both', () {
      final base = DateTime.utc(2024, 8, 1, 6);
      final activity = _buildActivity(base, 3);
      // Point at index 2 is at base + 20 s
      const pause = Duration(minutes: 5);
      const shift = Duration(hours: 1);
      final at = base.add(const Duration(seconds: 10));

      final result = RawEditor(
        activity,
      ).insertPause(at, pause).shiftTime(shift).activity;

      // Original point at +20s was shifted forward by pause (since >at),
      // then by shift.
      final expected = base
          .add(const Duration(seconds: 20))
          .add(pause)
          .add(shift);
      expect(result.points[2].time, isAtSameMomentAs(expected));
    });
  });

  group(
    'deleteRange + recomputeDistanceAndSpeed produces shorter distance',
    () {
      test('distance is shorter after removing middle points', () {
        final base = DateTime.utc(2024, 8, 2, 6);
        // 5 points at 10-second intervals moving north ~111 m per 0.001 deg
        final activity = _buildActivity(base, 5);
        final fullDistance = RawEditor(
          activity,
        ).recomputeDistanceAndSpeed().activity;
        final distanceFull = fullDistance.channel(Channel.distance).last.value;

        // Delete the two middle points
        final from = base.add(const Duration(seconds: 10));
        final to = base.add(const Duration(seconds: 30));
        final edited = RawEditor(
          activity,
        ).deleteRange(from, to).recomputeDistanceAndSpeed().activity;
        final distanceEdited = edited.channel(Channel.distance).last.value;

        expect(distanceEdited, lessThan(distanceFull));
      });
    },
  );

  group('removePause closes a gap visible in timestamps', () {
    test('gap is no longer visible after removePause', () {
      final base = DateTime.utc(2024, 8, 3, 6);
      // Construct activity with an artificial 5-minute gap between point 1 and 2
      final p0 = _pt(40.0, -105.0, base);
      final p1 = _pt(40.001, -105.001, base.add(const Duration(seconds: 10)));
      // 5 minute gap
      final p2 = _pt(
        40.002,
        -105.002,
        base.add(const Duration(seconds: 10, minutes: 5)),
      );
      final p3 = _pt(
        40.003,
        -105.003,
        base.add(const Duration(seconds: 20, minutes: 5)),
      );
      final activity = RawActivity(points: [p0, p1, p2, p3]);

      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 10, minutes: 5));

      final result = RawEditor(activity).removePause(from, to).activity;

      // p2 should now be at from (shifted back by gap)
      expect(result.points[2].time, isAtSameMomentAs(from));
      // p3 should be 10 s after p2
      expect(
        result.points[3].time,
        isAtSameMomentAs(from.add(const Duration(seconds: 10))),
      );
    });
  });

  group('Full edit chain produces valid activity', () {
    test('chain of 6 operations leaves activity in valid shape', () {
      final base = DateTime.utc(2024, 8, 4, 6);
      final initial = _buildActivity(
        base,
        6,
        withHr: true,
        laps: [_lap(base, base.add(const Duration(seconds: 50)))],
      );

      // Insert an extra point between index 2 and 3
      final insertTime = base.add(const Duration(seconds: 25));
      final extraPoint = _pt(40.0025, -105.0025, insertTime);

      // Delete the point we just inserted (after insertion it will be at index 3)
      // Then delete a range, insert a pause, remove the same pause, sort+dedup, recompute

      final result = RawEditor(initial)
          .insertPoint(extraPoint) // now 7 points
          .deletePointAt(3) // back to 6 points (removes inserted)
          .deleteRange(
            base.add(const Duration(seconds: 10)),
            base.add(const Duration(seconds: 20)),
          ) // removes 2 points → 4 remain
          .insertPause(
            base.add(const Duration(seconds: 10)),
            const Duration(seconds: 5),
          ) // shifts points after +10s
          .removePause(
            base.add(const Duration(seconds: 10)),
            base.add(const Duration(seconds: 15)),
          ) // closes the 5-second gap
          .sortAndDedup()
          .recomputeDistanceAndSpeed()
          .activity;

      expect(result.points, isNotEmpty);
      expect(result.channel(Channel.distance), isNotEmpty);
      expect(result.channel(Channel.distance).last.value, greaterThan(0));
      // Timestamps are strictly increasing after sortAndDedup + recompute
      for (var i = 1; i < result.points.length; i++) {
        expect(
          result.points[i].time.isAfter(result.points[i - 1].time),
          isTrue,
          reason: 'points[$i] time should be after points[${i - 1}] time',
        );
      }
    });
  });

  group('insertPause then removePause is near-identity', () {
    test('points/channels/laps return to original timings', () {
      final base = DateTime.utc(2024, 8, 5, 6);
      final at = base.add(const Duration(seconds: 10));
      const pause = Duration(minutes: 2);
      final initial = _buildActivity(
        base,
        4,
        withHr: true,
        laps: [_lap(base, base.add(const Duration(seconds: 30)))],
      );

      final after = RawEditor(
        initial,
      ).insertPause(at, pause).removePause(at, at.add(pause)).activity;

      // Points should match original timings
      for (var i = 0; i < initial.points.length; i++) {
        expect(
          after.points[i].time,
          isAtSameMomentAs(initial.points[i].time),
          reason: 'Point $i time should match original',
        );
      }

      // HR channel
      final originalHr = initial.channel(Channel.heartRate);
      final afterHr = after.channel(Channel.heartRate);
      for (var i = 0; i < originalHr.length; i++) {
        expect(
          afterHr[i].time,
          isAtSameMomentAs(originalHr[i].time),
          reason: 'HR sample $i time should match original',
        );
      }

      // Laps
      expect(
        after.laps.single.startTime,
        isAtSameMomentAs(initial.laps.single.startTime),
      );
      expect(
        after.laps.single.endTime,
        isAtSameMomentAs(initial.laps.single.endTime),
      );
    });
  });

  group('shiftTime regression: sets are shifted (fix verification)', () {
    test('sets are shifted after shiftTime is called', () {
      final base = DateTime.utc(2024, 8, 6, 6);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        sets: [
          _set(base, base.add(const Duration(minutes: 5))),
          _set(
            base.add(const Duration(minutes: 6)),
            base.add(const Duration(minutes: 10)),
            isRest: true,
          ),
        ],
      );
      const delta = Duration(hours: 2);

      final result = RawEditor(activity).shiftTime(delta).activity;

      expect(result.sets, hasLength(2));
      expect(result.sets[0].startTime, isAtSameMomentAs(base.add(delta)));
      expect(
        result.sets[0].endTime,
        isAtSameMomentAs(base.add(const Duration(minutes: 5)).add(delta)),
      );
      expect(
        result.sets[1].startTime,
        isAtSameMomentAs(base.add(const Duration(minutes: 6)).add(delta)),
      );
      expect(result.sets[0].isRest, isFalse);
      expect(result.sets[1].isRest, isTrue);
    });

    test('isRest and other set fields are preserved through shiftTime', () {
      final base = DateTime.utc(2024, 8, 6, 8);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        sets: [
          WorkoutSet(
            startTime: base,
            endTime: base.add(const Duration(minutes: 3)),
            isRest: false,
            exerciseCategory: 'Squat',
            repetitions: 10,
            weightKg: 80.0,
          ),
        ],
      );

      final result = RawEditor(
        activity,
      ).shiftTime(const Duration(hours: 1)).activity;

      expect(result.sets.single.exerciseCategory, equals('Squat'));
      expect(result.sets.single.repetitions, equals(10));
      expect(result.sets.single.weightKg, equals(80.0));
      expect(result.sets.single.isRest, isFalse);
    });
  });
}
