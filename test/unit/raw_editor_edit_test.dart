// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for the new RawEditor edit methods: insertPoint, deletePointAt,
/// updatePoint, deleteRange, insertPause, removePause, and the shiftTime fix.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/matchers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

GeoPoint _pt(double lat, double lon, DateTime time) =>
    GeoPoint(latitude: lat, longitude: lon, time: time);

Sample _sample(DateTime time, double value) => Sample(time: time, value: value);

Lap _lap(DateTime start, DateTime end) => Lap(startTime: start, endTime: end);

WorkoutSet _set(DateTime start, DateTime end, {bool isRest = false}) =>
    WorkoutSet(startTime: start, endTime: end, isRest: isRest);

// ---------------------------------------------------------------------------
// shiftTime fix: sets are now shifted
// ---------------------------------------------------------------------------

void main() {
  group('RawEditor.shiftTime (sets fix)', () {
    test('shifts sets alongside points, channels, and laps', () {
      final base = DateTime.utc(2024, 1, 1, 6);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        sets: [_set(base, base.add(const Duration(minutes: 5)))],
      );
      const delta = Duration(hours: 1);

      final result = RawEditor(activity).shiftTime(delta).activity;

      expect(result.sets, hasLength(1));
      expect(result.sets.first.startTime, isAtSameMomentAs(base.add(delta)));
      expect(
        result.sets.first.endTime,
        isAtSameMomentAs(base.add(const Duration(minutes: 5)).add(delta)),
      );
    });

    test('negative delta shifts sets backwards', () {
      final base = DateTime.utc(2024, 1, 1, 10);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        sets: [_set(base, base.add(const Duration(minutes: 10)))],
      );
      const delta = Duration(hours: -2);

      final result = RawEditor(activity).shiftTime(delta).activity;

      expect(result.sets.first.startTime, isAtSameMomentAs(base.add(delta)));
    });

    test('does not touch sets when activity has none', () {
      final base = DateTime.utc(2024, 1, 1, 6);
      final activity = RawActivity(points: [_pt(40.0, -105.0, base)]);

      final result = RawEditor(
        activity,
      ).shiftTime(const Duration(seconds: 30)).activity;

      expect(result.sets, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // insertPoint
  // ---------------------------------------------------------------------------

  group('RawEditor.insertPoint', () {
    test('appends point when it is after all existing points', () {
      final base = DateTime.utc(2024, 2, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
        ],
      );
      final newPt = _pt(
        40.002,
        -105.002,
        base.add(const Duration(seconds: 20)),
      );

      final result = RawEditor(activity).insertPoint(newPt).activity;

      expect(result.points, hasLength(3));
      expect(result.points.last.latitude, equals(40.002));
    });

    test('inserts point before the first later point', () {
      final base = DateTime.utc(2024, 2, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.002, -105.002, base.add(const Duration(seconds: 20))),
        ],
      );
      final newPt = _pt(
        40.001,
        -105.001,
        base.add(const Duration(seconds: 10)),
      );

      final result = RawEditor(activity).insertPoint(newPt).activity;

      expect(result.points, hasLength(3));
      expect(result.points[1].latitude, equals(40.001));
    });

    test('inserts at front when point is before all existing points', () {
      final base = DateTime.utc(2024, 2, 1, 6);
      final activity = RawActivity(
        points: [_pt(40.001, -105.001, base.add(const Duration(seconds: 10)))],
      );
      final newPt = _pt(40.0, -105.0, base);

      final result = RawEditor(activity).insertPoint(newPt).activity;

      expect(result.points.first.latitude, equals(40.0));
    });

    test('normalises incoming time to UTC', () {
      final base = DateTime.utc(2024, 2, 1, 6);
      final activity = RawActivity(points: [_pt(40.0, -105.0, base)]);
      // Pass a non-UTC time
      final nonUtc = DateTime(2024, 2, 1, 7, 0, 0); // local time
      final newPt = GeoPoint(
        latitude: 40.001,
        longitude: -105.001,
        time: nonUtc,
      );

      final result = RawEditor(activity).insertPoint(newPt).activity;

      for (final p in result.points) {
        expect(p.time.isUtc, isTrue);
      }
    });

    test('does not change channels', () {
      final base = DateTime.utc(2024, 2, 1, 6);
      final hr = [_sample(base, 140.0)];
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        channels: {Channel.heartRate: hr},
      );
      final newPt = _pt(
        40.001,
        -105.001,
        base.add(const Duration(seconds: 10)),
      );

      final result = RawEditor(activity).insertPoint(newPt).activity;

      expect(result.channel(Channel.heartRate), hasLength(1));
    });

    test('works on empty activity', () {
      final activity = RawActivity();
      final newPt = _pt(40.0, -105.0, DateTime.utc(2024, 2, 1, 6));

      final result = RawEditor(activity).insertPoint(newPt).activity;

      expect(result.points, hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // deletePointAt
  // ---------------------------------------------------------------------------

  group('RawEditor.deletePointAt', () {
    test('removes the point at the given index', () {
      final base = DateTime.utc(2024, 3, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
          _pt(40.002, -105.002, base.add(const Duration(seconds: 20))),
        ],
      );

      final result = RawEditor(activity).deletePointAt(1).activity;

      expect(result.points, hasLength(2));
      expect(result.points[0].latitude, equals(40.0));
      expect(result.points[1].latitude, equals(40.002));
    });

    test('removes the first point (index 0)', () {
      final base = DateTime.utc(2024, 3, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
        ],
      );

      final result = RawEditor(activity).deletePointAt(0).activity;

      expect(result.points.single.latitude, equals(40.001));
    });

    test('removes the last point', () {
      final base = DateTime.utc(2024, 3, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
        ],
      );

      final result = RawEditor(activity).deletePointAt(1).activity;

      expect(result.points.single.latitude, equals(40.0));
    });

    test('throws RangeError for negative index', () {
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, DateTime.utc(2024, 3, 1))],
      );

      expect(
        () => RawEditor(activity).deletePointAt(-1),
        throwsA(isA<RangeError>()),
      );
    });

    test('throws RangeError when index equals points.length', () {
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, DateTime.utc(2024, 3, 1))],
      );

      expect(
        () => RawEditor(activity).deletePointAt(1),
        throwsA(isA<RangeError>()),
      );
    });

    test('throws RangeError on empty activity', () {
      final activity = RawActivity();

      expect(
        () => RawEditor(activity).deletePointAt(0),
        throwsA(isA<RangeError>()),
      );
    });

    test('does not change channels', () {
      final base = DateTime.utc(2024, 3, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
        ],
        channels: {
          Channel.heartRate: [
            _sample(base, 140),
            _sample(base.add(const Duration(seconds: 10)), 145),
          ],
        },
      );

      final result = RawEditor(activity).deletePointAt(0).activity;

      expect(result.channel(Channel.heartRate), hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // updatePoint
  // ---------------------------------------------------------------------------

  group('RawEditor.updatePoint', () {
    test('updates latitude and longitude in place', () {
      final base = DateTime.utc(2024, 4, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
        ],
      );

      final result = RawEditor(
        activity,
      ).updatePoint(0, latitude: 41.0, longitude: -106.0).activity;

      expect(result.points[0].latitude, equals(41.0));
      expect(result.points[0].longitude, equals(-106.0));
      expect(result.points[0].time, isAtSameMomentAs(base));
    });

    test('updates elevation without changing time or coordinates', () {
      final base = DateTime.utc(2024, 4, 1, 6);
      final activity = RawActivity(points: [_pt(40.0, -105.0, base)]);

      final result = RawEditor(
        activity,
      ).updatePoint(0, elevation: 2000.0).activity;

      expect(result.points.single.elevation, equals(2000.0));
      expect(result.points.single.latitude, equals(40.0));
    });

    test('re-sorts points when time is updated', () {
      final base = DateTime.utc(2024, 4, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
          _pt(40.002, -105.002, base.add(const Duration(seconds: 20))),
        ],
      );
      // Move the last point to before the second
      final newTime = base.add(const Duration(seconds: 5));

      final result = RawEditor(activity).updatePoint(2, time: newTime).activity;

      // After re-sort the point at index 1 should be the one with lat 40.002
      expect(result.points[1].latitude, equals(40.002));
    });

    test('does not re-sort when time is not updated', () {
      final base = DateTime.utc(2024, 4, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
        ],
      );

      final result = RawEditor(
        activity,
      ).updatePoint(0, latitude: 41.0).activity;

      // Order unchanged
      expect(result.points[0].latitude, equals(41.0));
      expect(result.points[1].latitude, equals(40.001));
    });

    test('throws RangeError for out-of-bounds index', () {
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, DateTime.utc(2024, 4, 1))],
      );

      expect(
        () => RawEditor(activity).updatePoint(5, latitude: 41.0),
        throwsA(isA<RangeError>()),
      );
    });

    test('throws RangeError on negative index', () {
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, DateTime.utc(2024, 4, 1))],
      );

      expect(
        () => RawEditor(activity).updatePoint(-1, latitude: 41.0),
        throwsA(isA<RangeError>()),
      );
    });

    test('does not change channels', () {
      final base = DateTime.utc(2024, 4, 1, 6);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        channels: {
          Channel.heartRate: [_sample(base, 140)],
        },
      );

      final result = RawEditor(
        activity,
      ).updatePoint(0, latitude: 41.0).activity;

      expect(result.channel(Channel.heartRate), hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // deleteRange
  // ---------------------------------------------------------------------------

  group('RawEditor.deleteRange', () {
    test('removes points inside range (inclusive)', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
          _pt(40.002, -105.002, base.add(const Duration(seconds: 20))),
          _pt(40.003, -105.003, base.add(const Duration(seconds: 30))),
        ],
      );
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 20));

      final result = RawEditor(activity).deleteRange(from, to).activity;

      expect(result.points, hasLength(2));
      expect(result.points.first.latitude, equals(40.0));
      expect(result.points.last.latitude, equals(40.003));
    });

    test('removes channel samples inside range', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
          _pt(40.002, -105.002, base.add(const Duration(seconds: 20))),
        ],
        channels: {
          Channel.heartRate: [
            _sample(base, 140),
            _sample(base.add(const Duration(seconds: 10)), 145),
            _sample(base.add(const Duration(seconds: 20)), 150),
          ],
        },
      );

      final result = RawEditor(activity)
          .deleteRange(
            base.add(const Duration(seconds: 10)),
            base.add(const Duration(seconds: 20)),
          )
          .activity;

      expect(result.channel(Channel.heartRate), hasLength(1));
      expect(result.channel(Channel.heartRate).single.value, equals(140));
    });

    test('preserves points outside range', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base), // before range: keep
          _pt(
            40.001,
            -105.001,
            base.add(const Duration(seconds: 5)),
          ), // before range: keep
          _pt(
            40.002,
            -105.002,
            base.add(const Duration(seconds: 15)),
          ), // inside range: remove
          _pt(
            40.003,
            -105.003,
            base.add(const Duration(seconds: 25)),
          ), // after range: keep
        ],
      );

      final result = RawEditor(activity)
          .deleteRange(
            base.add(const Duration(seconds: 8)),
            base.add(const Duration(seconds: 20)),
          )
          .activity;

      expect(result.points, hasLength(3));
      expect(result.points[0].latitude, equals(40.0));
      expect(result.points[1].latitude, equals(40.001));
      expect(result.points[2].latitude, equals(40.003));
    });

    test('keeps lap fully before range unchanged', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [_lap(base, base.add(const Duration(seconds: 5)))],
      );

      final result = RawEditor(activity)
          .deleteRange(
            base.add(const Duration(seconds: 10)),
            base.add(const Duration(seconds: 20)),
          )
          .activity;

      expect(result.laps, hasLength(1));
      expect(result.laps.single.startTime, isAtSameMomentAs(base));
    });

    test('keeps lap fully after range unchanged', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [
          _lap(
            base.add(const Duration(seconds: 25)),
            base.add(const Duration(seconds: 35)),
          ),
        ],
      );

      final result = RawEditor(activity)
          .deleteRange(
            base.add(const Duration(seconds: 10)),
            base.add(const Duration(seconds: 20)),
          )
          .activity;

      expect(result.laps, hasLength(1));
    });

    test('removes lap fully inside range', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [
          _lap(
            base.add(const Duration(seconds: 12)),
            base.add(const Duration(seconds: 18)),
          ),
        ],
      );

      final result = RawEditor(activity)
          .deleteRange(
            base.add(const Duration(seconds: 10)),
            base.add(const Duration(seconds: 20)),
          )
          .activity;

      expect(result.laps, isEmpty);
    });

    test('clips endTime of lap that straddles range start', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 20));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [_lap(base, base.add(const Duration(seconds: 15)))],
      );

      final result = RawEditor(activity).deleteRange(from, to).activity;

      expect(result.laps, hasLength(1));
      expect(result.laps.single.startTime, isAtSameMomentAs(base));
      expect(result.laps.single.endTime, isAtSameMomentAs(from));
    });

    test('clips startTime of lap that straddles range end', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 20));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [
          _lap(
            base.add(const Duration(seconds: 15)),
            base.add(const Duration(seconds: 30)),
          ),
        ],
      );

      final result = RawEditor(activity).deleteRange(from, to).activity;

      expect(result.laps, hasLength(1));
      expect(result.laps.single.startTime, isAtSameMomentAs(to));
    });

    test('keeps original bounds for lap straddling whole range', () {
      // deleteRange leaves the timeline gap in place, so a lap spanning the
      // entire deleted range still covers the surviving points after [to];
      // clipping it would orphan them from any lap.
      final base = DateTime.utc(2024, 5, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 20));
      final lapEnd = base.add(const Duration(seconds: 30));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [_lap(base, lapEnd)],
      );

      final result = RawEditor(activity).deleteRange(from, to).activity;

      expect(result.laps, hasLength(1));
      expect(result.laps.single.startTime, isAtSameMomentAs(base));
      expect(result.laps.single.endTime, isAtSameMomentAs(lapEnd));
    });

    test('empty range (from == to) removes exactly the boundary items', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final t = base.add(const Duration(seconds: 10));
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, t),
          _pt(40.002, -105.002, base.add(const Duration(seconds: 20))),
        ],
      );

      final result = RawEditor(activity).deleteRange(t, t).activity;

      expect(result.points, hasLength(2));
      expect(result.points.first.latitude, equals(40.0));
      expect(result.points.last.latitude, equals(40.002));
    });

    test('throws ArgumentError when to is before from', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final activity = RawActivity(points: [_pt(40.0, -105.0, base)]);

      expect(
        () => RawEditor(
          activity,
        ).deleteRange(base.add(const Duration(seconds: 20)), base),
        throwsArgumentError,
      );
    });

    test('applies same logic to sets as laps', () {
      final base = DateTime.utc(2024, 5, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 20));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        sets: [
          // fully before: keep
          _set(base, base.add(const Duration(seconds: 8))),
          // fully inside: remove
          _set(
            base.add(const Duration(seconds: 12)),
            base.add(const Duration(seconds: 18)),
          ),
          // fully after: keep
          _set(
            base.add(const Duration(seconds: 25)),
            base.add(const Duration(seconds: 30)),
          ),
        ],
      );

      final result = RawEditor(activity).deleteRange(from, to).activity;

      expect(result.sets, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // insertPause
  // ---------------------------------------------------------------------------

  group('RawEditor.insertPause', () {
    test('shifts points strictly after at forward by duration', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
          _pt(40.002, -105.002, base.add(const Duration(seconds: 20))),
        ],
      );
      final at = base.add(const Duration(seconds: 10));
      const pause = Duration(minutes: 5);

      final result = RawEditor(activity).insertPause(at, pause).activity;

      // Point at exactly 'at' is NOT shifted (strictly after)
      expect(
        result.points[1].time,
        isAtSameMomentAs(base.add(const Duration(seconds: 10))),
      );
      // Point after 'at' IS shifted
      expect(
        result.points[2].time,
        isAtSameMomentAs(base.add(const Duration(seconds: 20)).add(pause)),
      );
    });

    test('does not shift points at or before at', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 5))),
        ],
      );
      final at = base.add(const Duration(seconds: 10));
      const pause = Duration(minutes: 1);

      final result = RawEditor(activity).insertPause(at, pause).activity;

      expect(result.points[0].time, isAtSameMomentAs(base));
      expect(
        result.points[1].time,
        isAtSameMomentAs(base.add(const Duration(seconds: 5))),
      );
    });

    test('shifts channel samples strictly after at', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        channels: {
          Channel.heartRate: [
            _sample(base, 140),
            _sample(base.add(const Duration(seconds: 10)), 145),
            _sample(base.add(const Duration(seconds: 20)), 150),
          ],
        },
      );
      final at = base.add(const Duration(seconds: 10));
      const pause = Duration(seconds: 30);

      final result = RawEditor(activity).insertPause(at, pause).activity;
      final hr = result.channel(Channel.heartRate);

      expect(hr[0].time, isAtSameMomentAs(base));
      expect(
        hr[1].time,
        isAtSameMomentAs(base.add(const Duration(seconds: 10))),
      );
      expect(
        hr[2].time,
        isAtSameMomentAs(base.add(const Duration(seconds: 20)).add(pause)),
      );
    });

    test('lap fully after at gets both times shifted', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final at = base.add(const Duration(seconds: 10));
      const pause = Duration(minutes: 2);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [
          _lap(
            base.add(const Duration(seconds: 15)),
            base.add(const Duration(seconds: 25)),
          ),
        ],
      );

      final result = RawEditor(activity).insertPause(at, pause).activity;

      expect(
        result.laps.single.startTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 15)).add(pause)),
      );
      expect(
        result.laps.single.endTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 25)).add(pause)),
      );
    });

    test('lap straddling at has only endTime extended', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final at = base.add(const Duration(seconds: 15));
      const pause = Duration(minutes: 3);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [
          _lap(
            base.add(const Duration(seconds: 5)),
            base.add(const Duration(seconds: 25)),
          ),
        ],
      );

      final result = RawEditor(activity).insertPause(at, pause).activity;

      expect(
        result.laps.single.startTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 5))),
      );
      expect(
        result.laps.single.endTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 25)).add(pause)),
      );
    });

    test('lap fully before at is unchanged', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final at = base.add(const Duration(seconds: 30));
      const pause = Duration(minutes: 1);
      final lapEnd = base.add(const Duration(seconds: 20));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [_lap(base, lapEnd)],
      );

      final result = RawEditor(activity).insertPause(at, pause).activity;

      expect(result.laps.single.startTime, isAtSameMomentAs(base));
      expect(result.laps.single.endTime, isAtSameMomentAs(lapEnd));
    });

    test('zero duration returns this immediately (no-op)', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.001, -105.001, base.add(const Duration(seconds: 10))),
        ],
      );

      final result = RawEditor(
        activity,
      ).insertPause(base, Duration.zero).activity;

      expect(
        result.points[1].time,
        isAtSameMomentAs(base.add(const Duration(seconds: 10))),
      );
    });

    test('throws ArgumentError for negative duration', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final activity = RawActivity(points: [_pt(40.0, -105.0, base)]);

      expect(
        () =>
            RawEditor(activity).insertPause(base, const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    test('applies same logic to sets as laps', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final at = base.add(const Duration(seconds: 10));
      const pause = Duration(minutes: 1);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        sets: [
          // fully after at
          _set(
            base.add(const Duration(seconds: 15)),
            base.add(const Duration(seconds: 25)),
          ),
        ],
      );

      final result = RawEditor(activity).insertPause(at, pause).activity;

      expect(
        result.sets.single.startTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 15)).add(pause)),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // removePause
  // ---------------------------------------------------------------------------

  group('RawEditor.removePause', () {
    test('removes points strictly inside gap', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(
            40.001,
            -105.001,
            base.add(const Duration(seconds: 10)),
          ), // at from: keep unchanged
          _pt(
            40.002,
            -105.002,
            base.add(const Duration(seconds: 20)),
          ), // strictly inside: remove
          _pt(
            40.003,
            -105.003,
            base.add(const Duration(seconds: 30)),
          ), // at to (>= to): shift back
          _pt(
            40.004,
            -105.004,
            base.add(const Duration(seconds: 40)),
          ), // after to: shift back
        ],
      );

      final result = RawEditor(activity).removePause(from, to).activity;

      // 4 points remain: base, from, shifted-to, shifted-after
      // (only the point at base+20s is strictly inside [from, to) exclusive both boundaries)
      expect(result.points, hasLength(4));
      expect(result.points[0].time, isAtSameMomentAs(base));
      expect(result.points[1].time, isAtSameMomentAs(from));
    });

    test('point at from is kept unchanged', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base), _pt(40.001, -105.001, from)],
      );

      final result = RawEditor(activity).removePause(from, to).activity;

      expect(result.points[1].time, isAtSameMomentAs(from));
    });

    test('points at and after to are shifted back by gap', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final gap = to.difference(from); // 20 s
      final activity = RawActivity(
        points: [
          _pt(40.0, -105.0, base),
          _pt(40.003, -105.003, to),
          _pt(40.004, -105.004, base.add(const Duration(seconds: 40))),
        ],
      );

      final result = RawEditor(activity).removePause(from, to).activity;

      expect(result.points[1].time, isAtSameMomentAs(to.subtract(gap)));
      expect(
        result.points[2].time,
        isAtSameMomentAs(base.add(const Duration(seconds: 40)).subtract(gap)),
      );
    });

    test('lap straddling whole gap has endTime shifted back', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final gap = to.difference(from);
      final lapEnd = base.add(const Duration(seconds: 50));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [_lap(base, lapEnd)],
      );

      final result = RawEditor(activity).removePause(from, to).activity;

      expect(result.laps.single.startTime, isAtSameMomentAs(base));
      expect(
        result.laps.single.endTime,
        isAtSameMomentAs(lapEnd.subtract(gap)),
      );
    });

    test('lap collapsed to zero duration by clipping is dropped', () {
      // A lap that starts exactly at [from] and ends inside the gap would be
      // clipped to [from, from]; zero-duration laps fail lap-boundary
      // validation, so removePause drops them instead.
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        laps: [_lap(from, base.add(const Duration(seconds: 20)))],
      );

      final result = RawEditor(activity).removePause(from, to).activity;

      expect(result.laps, isEmpty);
    });

    test('set collapsed to zero duration by clipping is dropped', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        sets: [_set(from, base.add(const Duration(seconds: 20)))],
      );

      final result = RawEditor(activity).removePause(from, to).activity;

      expect(result.sets, isEmpty);
    });

    test('zero gap (from == to) is a no-op', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final t = base.add(const Duration(seconds: 10));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base), _pt(40.001, -105.001, t)],
      );

      final result = RawEditor(activity).removePause(t, t).activity;

      expect(result.points[1].time, isAtSameMomentAs(t));
    });

    test('throws ArgumentError when to is before from', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final activity = RawActivity(points: [_pt(40.0, -105.0, base)]);

      expect(
        () => RawEditor(
          activity,
        ).removePause(base.add(const Duration(seconds: 20)), base),
        throwsArgumentError,
      );
    });

    test('channel samples strictly inside gap are removed', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        channels: {
          Channel.heartRate: [
            _sample(base, 140),
            _sample(base.add(const Duration(seconds: 20)), 145), // inside gap
            _sample(to, 150), // at to: shift
          ],
        },
      );

      final result = RawEditor(activity).removePause(from, to).activity;
      final hr = result.channel(Channel.heartRate);

      expect(hr, hasLength(2));
      expect(hr[0].time, isAtSameMomentAs(base));
    });

    test('applies same logic to sets as laps', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final gap = to.difference(from);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        sets: [
          // fully after to: shift both
          _set(
            base.add(const Duration(seconds: 35)),
            base.add(const Duration(seconds: 45)),
          ),
        ],
      );

      final result = RawEditor(activity).removePause(from, to).activity;

      expect(
        result.sets.single.startTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 35)).subtract(gap)),
      );
      expect(
        result.sets.single.endTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 45)).subtract(gap)),
      );
    });
  });
}
