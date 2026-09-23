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

ActivityEvent _event(DateTime time) =>
    ActivityEvent(time: time, event: 0, eventType: 0);

SwimLength _length(DateTime start, DateTime end) =>
    SwimLength(startTime: start, endTime: end, isActive: true);

void main() {
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

    test('shifts an event strictly after at, and a length after at', () {
      final base = DateTime.utc(2024, 6, 1, 6);
      final at = base.add(const Duration(seconds: 10));
      const pause = Duration(minutes: 1);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        events: [
          _event(at), // exactly at `at`: not shifted (matches point semantics)
          _event(base.add(const Duration(seconds: 15))), // after: shifted
        ],
        lengths: [
          _length(
            base.add(const Duration(seconds: 20)),
            base.add(const Duration(seconds: 30)),
          ),
        ],
      );

      final result = RawEditor(activity).insertPause(at, pause).activity;

      expect(result.events[0].time, isAtSameMomentAs(at));
      expect(
        result.events[1].time,
        isAtSameMomentAs(base.add(const Duration(seconds: 15)).add(pause)),
      );
      expect(
        result.lengths.single.startTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 20)).add(pause)),
      );
      expect(
        result.lengths.single.endTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 30)).add(pause)),
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

    test('drops an event inside the gap and shifts a length starting at '
        'the gap end back by the gap duration', () {
      final base = DateTime.utc(2024, 7, 1, 6);
      final from = base.add(const Duration(seconds: 10));
      final to = base.add(const Duration(seconds: 30));
      final gap = to.difference(from);
      final activity = RawActivity(
        points: [_pt(40.0, -105.0, base)],
        events: [
          _event(base.add(const Duration(seconds: 20))), // inside: dropped
        ],
        lengths: [
          // starts exactly at the gap end: shift back by the gap duration
          _length(to, base.add(const Duration(seconds: 40))),
        ],
      );

      final result = RawEditor(activity).removePause(from, to).activity;

      expect(result.events, isEmpty);
      expect(result.lengths.single.startTime, isAtSameMomentAs(from));
      expect(
        result.lengths.single.endTime,
        isAtSameMomentAs(base.add(const Duration(seconds: 40)).subtract(gap)),
      );
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
