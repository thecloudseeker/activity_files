// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// FIT → FIT round-trip coverage for the full 0.7.0 data model:
/// session summary (incl. swim metrics, sub-sport, total cycles), per-lap
/// metrics, and strength-training set messages (global 225).
void main() {
  final t0 = DateTime.utc(2024, 3, 1, 8, 0, 0);

  RawActivity roundTrip(RawActivity activity) {
    final encoded = ActivityEncoder.encode(activity, ActivityFileFormat.fit);
    final result = ActivityParser.parseBytes(
      base64Decode(encoded),
      ActivityFileFormat.fit,
    );
    expect(
      result.diagnostics.where((d) => d.severity == ParseSeverity.error),
      isEmpty,
      reason: 'encoded FIT must parse without errors',
    );
    return result.activity;
  }

  List<GeoPoint> pointsAt(DateTime start, int count) => [
    for (var i = 0; i < count; i++)
      GeoPoint(
        latitude: 47.0 + i * 0.0001,
        longitude: 11.0 + i * 0.0001,
        elevation: 500.0 + i,
        time: start.add(Duration(seconds: i * 10)),
      ),
  ];

  group('FIT round-trip', () {
    test('session summary survives including swim metrics', () {
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        sport: Sport.swimming,
        summary: ActivitySummary(
          elapsedTime: const Duration(minutes: 30, seconds: 15),
          timerTime: const Duration(minutes: 28),
          totalDistanceMeters: 1500.0,
          calories: 400.0,
          avgSpeed: 0.833,
          maxSpeed: 1.2,
          avgHeartRate: 121.0,
          maxHeartRate: 155.0,
          avgCadence: 30.0,
          maxCadence: 42.0,
          avgPower: 200.0,
          maxPower: 350.0,
          poolLengthMeters: 25.0,
          numActiveLengths: 60,
          swimStroke: SwimStroke.freestyle,
          avgStrokeCount: 18.5,
          subSport: 17,
          totalCycles: 555,
        ),
      );

      final summary = roundTrip(activity).summary;
      expect(summary, isNotNull);
      expect(summary!.elapsedTime, const Duration(minutes: 30, seconds: 15));
      expect(summary.timerTime, const Duration(minutes: 28));
      expect(summary.totalDistanceMeters, closeTo(1500.0, 0.01));
      expect(summary.calories, 400.0);
      expect(summary.avgSpeed, closeTo(0.833, 0.001));
      expect(summary.maxSpeed, closeTo(1.2, 0.001));
      expect(summary.avgHeartRate, 121.0);
      expect(summary.maxHeartRate, 155.0);
      expect(summary.avgCadence, 30.0);
      expect(summary.maxCadence, 42.0);
      expect(summary.avgPower, 200.0);
      expect(summary.maxPower, 350.0);
      expect(summary.poolLengthMeters, closeTo(25.0, 0.01));
      expect(summary.numActiveLengths, 60);
      expect(summary.swimStroke, SwimStroke.freestyle);
      expect(summary.avgStrokeCount, closeTo(18.5, 0.1));
      expect(summary.subSport, 17);
      expect(summary.totalCycles, 555);
    });

    test('absent summary fields stay null (invalid sentinels)', () {
      final activity = RawActivity(
        points: pointsAt(t0, 3),
        sport: Sport.running,
      );

      final summary = roundTrip(activity).summary;
      expect(summary, isNotNull);
      expect(summary!.elapsedTime, isNull);
      expect(summary.totalDistanceMeters, isNull);
      expect(summary.calories, isNull);
      expect(summary.avgHeartRate, isNull);
      expect(summary.maxPower, isNull);
      expect(summary.poolLengthMeters, isNull);
      expect(summary.swimStroke, isNull);
      expect(summary.subSport, isNull);
      expect(summary.totalCycles, isNull);
    });

    test('lap metrics and swim fields survive', () {
      final lap = Lap(
        startTime: t0,
        endTime: t0.add(const Duration(minutes: 5)),
        distanceMeters: 250.0,
        calories: 55.0,
        avgSpeed: 0.9,
        maxSpeed: 1.1,
        avgHeartRate: 130.0,
        maxHeartRate: 148.0,
        avgCadence: 28.0,
        maxCadence: 33.0,
        avgPower: 180.0,
        maxPower: 240.0,
        event: 9,
        eventType: 1,
        numActiveLengths: 10,
        swimStroke: SwimStroke.breaststroke,
      );
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        laps: [lap],
        sport: Sport.swimming,
      );

      final laps = roundTrip(activity).laps;
      expect(laps, hasLength(1));
      final parsed = laps.single;
      expect(parsed.startTime, lap.startTime);
      expect(parsed.endTime, lap.endTime);
      expect(parsed.distanceMeters, closeTo(250.0, 0.01));
      expect(parsed.calories, 55.0);
      expect(parsed.avgSpeed, closeTo(0.9, 0.001));
      expect(parsed.maxSpeed, closeTo(1.1, 0.001));
      expect(parsed.avgHeartRate, 130.0);
      expect(parsed.maxHeartRate, 148.0);
      expect(parsed.avgCadence, 28.0);
      expect(parsed.maxCadence, 33.0);
      expect(parsed.avgPower, 180.0);
      expect(parsed.maxPower, 240.0);
      expect(parsed.event, 9);
      expect(parsed.eventType, 1);
      expect(parsed.numActiveLengths, 10);
      expect(parsed.swimStroke, SwimStroke.breaststroke);
    });

    test('lap without optional metrics round-trips as nulls', () {
      final activity = RawActivity(
        points: pointsAt(t0, 3),
        laps: [Lap(startTime: t0, endTime: t0.add(const Duration(minutes: 2)))],
        sport: Sport.running,
      );

      final parsed = roundTrip(activity).laps.single;
      expect(parsed.distanceMeters, isNull);
      expect(parsed.calories, isNull);
      expect(parsed.avgHeartRate, isNull);
      expect(parsed.maxPower, isNull);
      expect(parsed.event, isNull);
      expect(parsed.swimStroke, isNull);
      expect(parsed.numActiveLengths, isNull);
    });

    test('strength-training sets survive (active and rest)', () {
      final active = WorkoutSet(
        startTime: t0,
        endTime: t0.add(const Duration(seconds: 45)),
        isRest: false,
        exerciseCategoryId: 28,
        exerciseCategory: 'Squat',
        repetitions: 12,
        weightKg: 42.5,
      );
      final rest = WorkoutSet(
        startTime: t0.add(const Duration(seconds: 45)),
        endTime: t0.add(const Duration(seconds: 105)),
        isRest: true,
      );
      final activity = RawActivity(
        points: pointsAt(t0, 3),
        sets: [active, rest],
        sport: Sport.other,
      );

      final sets = roundTrip(activity).sets;
      expect(sets, hasLength(2));

      final parsedActive = sets[0];
      expect(parsedActive.startTime, active.startTime);
      expect(parsedActive.endTime, active.endTime);
      expect(parsedActive.isRest, isFalse);
      expect(parsedActive.exerciseCategoryId, 28);
      expect(parsedActive.exerciseCategory, 'Squat');
      expect(parsedActive.repetitions, 12);
      expect(parsedActive.weightKg, closeTo(42.5, 0.01));

      final parsedRest = sets[1];
      expect(parsedRest.startTime, rest.startTime);
      expect(parsedRest.endTime, rest.endTime);
      expect(parsedRest.isRest, isTrue);
      expect(parsedRest.exerciseCategoryId, isNull);
      expect(parsedRest.repetitions, isNull);
      expect(parsedRest.weightKg, isNull);
    });

    test('multi-session activities keep every session and its sport', () {
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        sport: Sport.swimming,
        summary: const ActivitySummary(
          totalDistanceMeters: 1500.0,
          calories: 300.0,
        ),
        additionalSessions: const [
          ActivitySummary(
            sport: Sport.cycling,
            totalDistanceMeters: 40000.0,
            avgPower: 210.0,
          ),
          ActivitySummary(
            sport: Sport.running,
            totalDistanceMeters: 10000.0,
            avgHeartRate: 165.0,
          ),
        ],
      );

      final parsed = roundTrip(activity);
      expect(parsed.sport, Sport.swimming);
      expect(parsed.summary?.totalDistanceMeters, closeTo(1500.0, 0.01));
      expect(parsed.summary?.calories, 300.0);
      expect(parsed.additionalSessions, hasLength(2));

      final bike = parsed.additionalSessions[0];
      expect(bike.sport, Sport.cycling);
      expect(bike.totalDistanceMeters, closeTo(40000.0, 0.01));
      expect(bike.avgPower, 210.0);

      final run = parsed.additionalSessions[1];
      expect(run.sport, Sport.running);
      expect(run.totalDistanceMeters, closeTo(10000.0, 0.01));
      expect(run.avgHeartRate, 165.0);
    });

    test('timer events and swim lengths survive', () {
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        sport: Sport.swimming,
        events: [
          ActivityEvent(
            time: t0.add(const Duration(seconds: 10)),
            event: 0,
            eventType: 4,
            data: 7,
          ),
          ActivityEvent(
            time: t0.add(const Duration(seconds: 20)),
            event: 0,
            eventType: 0,
          ),
        ],
        lengths: [
          SwimLength(
            startTime: t0,
            endTime: t0.add(const Duration(seconds: 22)),
            isActive: true,
            totalStrokes: 18,
            avgSpeed: 1.136,
            swimStroke: SwimStroke.freestyle,
          ),
          SwimLength(
            startTime: t0.add(const Duration(seconds: 22)),
            endTime: t0.add(const Duration(seconds: 30)),
            isActive: false,
          ),
        ],
      );

      final parsed = roundTrip(activity);

      expect(parsed.events, hasLength(2));
      final stop = parsed.events[0];
      expect(stop.time, t0.add(const Duration(seconds: 10)));
      expect(stop.isTimerEvent, isTrue);
      expect(stop.isStop, isTrue);
      expect(stop.data, 7);
      final start = parsed.events[1];
      expect(start.isStart, isTrue);
      expect(start.data, isNull);

      expect(parsed.lengths, hasLength(2));
      final active = parsed.lengths[0];
      expect(active.startTime, t0);
      expect(active.endTime, t0.add(const Duration(seconds: 22)));
      expect(active.isActive, isTrue);
      expect(active.totalStrokes, 18);
      expect(active.avgSpeed, closeTo(1.136, 0.001));
      expect(active.swimStroke, SwimStroke.freestyle);
      final idle = parsed.lengths[1];
      expect(idle.isActive, isFalse);
      expect(idle.totalStrokes, isNull);
      expect(idle.swimStroke, isNull);
    });

    test('record channels survive: grade, left_right_balance, fit_field_N', () {
      final times = [
        for (var i = 0; i < 4; i++) t0.add(Duration(seconds: i * 10)),
      ];
      List<Sample> series(List<double> values) => [
        for (var i = 0; i < values.length; i++)
          Sample(time: times[i], value: values[i]),
      ];
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        sport: Sport.cycling,
        channels: {
          // Named record fields the parser assigns to fields 78 and 120.
          Channel.custom('grade'): series([-3.5, 0.0, 2.5, 4.0]),
          Channel.custom('left_right_balance'): series([48, 49, 50, 51]),
          // Generic captured native fields; 88 carries negatives (→ signed).
          Channel.custom('fit_field_90'): series([200, 210, 220, 230]),
          Channel.custom('fit_field_88'): series([-5, -2, 3, 7]),
        },
      );

      final parsed = roundTrip(activity);

      final grade = parsed.channel(Channel.custom('grade')).toList();
      expect(grade, hasLength(4));
      expect(grade[0].value, closeTo(-3.5, 0.01));
      expect(grade[2].value, closeTo(2.5, 0.01));

      final balance = parsed
          .channel(Channel.custom('left_right_balance'))
          .map((s) => s.value)
          .toList();
      expect(balance, [48, 49, 50, 51]);

      final f90 = parsed
          .channel(Channel.custom('fit_field_90'))
          .map((s) => s.value)
          .toList();
      expect(f90, [200, 210, 220, 230]);

      final f88 = parsed
          .channel(Channel.custom('fit_field_88'))
          .map((s) => s.value)
          .toList();
      expect(f88, [-5, -2, 3, 7]);
    });

    test('unmodeled session and lap fields survive raw (incl. negatives)', () {
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        sport: Sport.running,
        summary: const ActivitySummary(
          totalDistanceMeters: 5000.0,
          extraFitFields: {22: 1500.0, 23: 1200.0, 200: -50.0},
        ),
        laps: [
          Lap(
            startTime: t0,
            endTime: t0.add(const Duration(minutes: 5)),
            distanceMeters: 1000.0,
            extraFitFields: const {21: 800.0, 22: 600.0, 210: -7.0},
          ),
        ],
      );

      final parsed = roundTrip(activity);
      expect(parsed.summary?.extraFitFields, {
        22: 1500.0,
        23: 1200.0,
        200: -50.0,
      });
      expect(parsed.laps.single.extraFitFields, {
        21: 800.0,
        22: 600.0,
        210: -7.0,
      });
    });

    test('multi-session extra fields stay per session under shared layout', () {
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        sport: Sport.cycling,
        summary: const ActivitySummary(
          totalDistanceMeters: 40000.0,
          extraFitFields: {22: 900.0},
        ),
        additionalSessions: const [
          ActivitySummary(
            sport: Sport.running,
            totalDistanceMeters: 10000.0,
            extraFitFields: {23: 300.0},
          ),
        ],
      );

      final parsed = roundTrip(activity);
      // Field 22 (primary only) and 23 (additional only) share one definition;
      // each session keeps only its own value, the other stays invalid/absent.
      expect(parsed.summary?.extraFitFields, {22: 900.0});
      expect(parsed.additionalSessions.single.extraFitFields, {23: 300.0});
    });

    test('unmodeled session and lap array fields survive raw', () {
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        sport: Sport.running,
        summary: const ActivitySummary(
          totalDistanceMeters: 5000.0,
          extraFitArrays: {
            120: [60.0, 120.0, 300.0, 90.0, 30.0], // time_in_hr_zone-like
            121: [-5.0, 10.0], // negative element → signed
          },
        ),
        laps: [
          Lap(
            startTime: t0,
            endTime: t0.add(const Duration(minutes: 5)),
            extraFitArrays: const {
              106: [10.0, 20.0, 30.0],
            },
          ),
        ],
      );

      final parsed = roundTrip(activity);
      expect(parsed.summary?.extraFitArrays[120], [
        60.0,
        120.0,
        300.0,
        90.0,
        30.0,
      ]);
      expect(parsed.summary?.extraFitArrays[121], [-5.0, 10.0]);
      expect(parsed.laps.single.extraFitArrays[106], [10.0, 20.0, 30.0]);
    });

    test('device metadata survives (device_info + file_creator)', () {
      final activity = RawActivity(
        points: pointsAt(t0, 3),
        sport: Sport.cycling,
        device: const ActivityDeviceMetadata(
          manufacturer: 'Wahoo Fitness',
          model: 'ELEMNT BOLT',
          product: '28',
          serialNumber: '1231627776',
          softwareVersion: '20.49',
          fitManufacturerId: 32,
          fitProductId: 28,
        ),
      );

      final parsed = roundTrip(activity);

      final device = parsed.device;
      expect(device, isNotNull);
      expect(device!.fitManufacturerId, 32);
      expect(device.manufacturer, 'Wahoo Fitness');
      expect(device.fitProductId, 28);
      expect(device.serialNumber, '1231627776');
      expect(device.softwareVersion, '20.49');
      expect(device.model, 'ELEMNT BOLT');
    });

    test('device metadata without software version keeps nulls', () {
      final activity = RawActivity(
        points: pointsAt(t0, 3),
        sport: Sport.running,
        device: const ActivityDeviceMetadata(
          manufacturer: 'Coros',
          model: 'COROS APEX 42mm',
          fitManufacturerId: 294,
        ),
      );

      final parsed = roundTrip(activity);

      final device = parsed.device;
      expect(device, isNotNull);
      expect(device!.fitManufacturerId, 294);
      expect(device.model, 'COROS APEX 42mm');
      expect(device.softwareVersion, isNull);
    });

    test('foreign custom channels survive as developer fields', () {
      final times = [
        for (var i = 0; i < 4; i++) t0.add(Duration(seconds: i * 10)),
      ];
      List<Sample> series(List<double> values) => [
        for (var i = 0; i < values.length; i++)
          Sample(time: times[i], value: values[i]),
      ];
      final activity = RawActivity(
        points: pointsAt(t0, 4),
        sport: Sport.cycling,
        channels: {
          // Cross-format channels with no native FIT record field; float64
          // developer fields keep fractional and negative values exact.
          Channel.waterTemperature: series([18.5, 18.6, 18.4, 18.2]),
          Channel.depth: series([1.2, 3.4, 2.8, 0.9]),
          Channel.course: series([181.25, 182.5, 190.0, 210.75]),
          Channel.custom('leg_spring_stiffness'): series([
            10.1,
            10.4,
            -0.5,
            11.0,
          ]),
        },
      );

      final parsed = roundTrip(activity);

      List<double> values(Channel channel) =>
          parsed.channel(channel).map((s) => s.value).toList();

      expect(values(Channel.waterTemperature), [18.5, 18.6, 18.4, 18.2]);
      expect(values(Channel.depth), [1.2, 3.4, 2.8, 0.9]);
      expect(values(Channel.course), [181.25, 182.5, 190.0, 210.75]);
      expect(values(Channel.custom('leg_spring_stiffness')), [
        10.1,
        10.4,
        -0.5,
        11.0,
      ]);
    });

    test('facade FIT→FIT conversion keeps summary, laps, and sets', () async {
      final source = RawActivity(
        points: pointsAt(t0, 4),
        laps: [
          Lap(
            startTime: t0,
            endTime: t0.add(const Duration(seconds: 30)),
            numActiveLengths: 4,
            swimStroke: SwimStroke.butterfly,
          ),
        ],
        sets: [
          WorkoutSet(
            startTime: t0,
            endTime: t0.add(const Duration(seconds: 40)),
            isRest: false,
            repetitions: 8,
            weightKg: 60.0,
          ),
        ],
        sport: Sport.swimming,
        summary: const ActivitySummary(
          poolLengthMeters: 50.0,
          numActiveLengths: 30,
          swimStroke: SwimStroke.butterfly,
        ),
      );
      final encoded = ActivityEncoder.encode(source, ActivityFileFormat.fit);
      final converted = await ActivityFiles.convert(
        source: base64Decode(encoded),
        from: ActivityFileFormat.fit,
        to: ActivityFileFormat.fit,
        useIsolate: false,
      );
      final reparsed = ActivityParser.parseBytes(
        converted.asBytes(),
        ActivityFileFormat.fit,
      ).activity;

      expect(reparsed.summary?.poolLengthMeters, closeTo(50.0, 0.01));
      expect(reparsed.summary?.numActiveLengths, 30);
      expect(reparsed.summary?.swimStroke, SwimStroke.butterfly);
      expect(reparsed.laps.single.swimStroke, SwimStroke.butterfly);
      expect(reparsed.laps.single.numActiveLengths, 4);
      expect(reparsed.sets.single.repetitions, 8);
      expect(reparsed.sets.single.weightKg, closeTo(60.0, 0.01));
    });
  });
}
