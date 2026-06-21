// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for optional typed FIT views.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('FitTypedActivityView', () {
    final base = DateTime.utc(2024, 1, 1, 10, 0, 0);

    RawActivity buildActivity() {
      return RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.0005,
            longitude: -105.0005,
            time: base.add(const Duration(seconds: 10)),
          ),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: base, value: 140),
            Sample(time: base.add(const Duration(seconds: 10)), value: 145),
          ],
          Channel.power: [
            Sample(time: base, value: 250),
            Sample(time: base.add(const Duration(seconds: 10)), value: 265),
          ],
          Channel.custom('fit_dev_0_1'): [
            Sample(time: base, value: 12),
            Sample(time: base.add(const Duration(seconds: 10)), value: 15),
          ],
          Channel.custom('running_power'): [
            Sample(time: base, value: 255),
            Sample(time: base.add(const Duration(seconds: 10)), value: 275),
          ],
        },
        laps: [
          Lap(
            startTime: base,
            endTime: base.add(const Duration(minutes: 5)),
            distanceMeters: 1000,
          ),
        ],
        sport: Sport.running,
        creator: 'FIT Device Garmin',
        device: const ActivityDeviceMetadata(
          manufacturer: 'Garmin',
          fitManufacturerId: 1,
          fitProductId: 1000,
          softwareVersion: '2.05',
        ),
        summary: const ActivitySummary(
          elapsedTime: Duration(minutes: 5),
          timerTime: Duration(minutes: 5),
          totalDistanceMeters: 1000,
          avgHeartRate: 142,
          avgPower: 260,
        ),
      );
    }

    test('asFitView exposes typed session/lap/record access', () {
      final view = buildActivity().asFitView();

      expect(view.session.sport, equals(Sport.running));
      expect(view.session.creator, equals('FIT Device Garmin'));
      expect(view.session.device?.manufacturer, equals('Garmin'));
      expect(view.session.totalDistanceMeters, equals(1000));

      expect(view.laps, hasLength(1));
      expect(view.laps.first.sport, equals(Sport.running));
      expect(view.laps.first.distanceMeters, equals(1000));
      expect(view.laps.first.elapsed, equals(const Duration(minutes: 5)));

      final records = view.records.toList(growable: false);
      expect(records, hasLength(2));
      expect(records.first.heartRate, equals(140));
      expect(records.first.power, equals(250));
      expect(records.first.developerFields['fit_dev_0_1'], equals(12));
      expect(records.first.developerFields['running_power'], equals(255));
    });

    test('developerChannels only includes developer-oriented channels', () {
      final view = buildActivity().asFitView();

      final channels = view.developerChannels;
      expect(channels.containsKey('fit_dev_0_1'), isTrue);
      expect(channels.containsKey('running_power'), isTrue);
      expect(channels.containsKey(Channel.power.id), isFalse);
      expect(channels['fit_dev_0_1']?.length, equals(2));
    });

    test('channelMatchWindow controls nearest-sample matching', () {
      final activity = RawActivity(
        points: [GeoPoint(latitude: 40, longitude: -105, time: base)],
        channels: {
          Channel.heartRate: [
            Sample(time: base.add(const Duration(seconds: 8)), value: 150),
          ],
        },
      );

      final strict = activity.asFitView(
        channelMatchWindow: const Duration(seconds: 5),
      );
      expect(strict.records.first.heartRate, isNull);

      final lenient = activity.asFitView(
        channelMatchWindow: const Duration(seconds: 10),
      );
      expect(lenient.records.first.heartRate, equals(150));
    });

    test('sets forwards RawActivity.sets', () {
      final s = WorkoutSet(
        startTime: base,
        endTime: base.add(const Duration(seconds: 45)),
        isRest: false,
        exerciseCategory: 'Squat',
        repetitions: 10,
        weightKg: 60.0,
      );
      final activity = buildActivity().copyWith(sets: [s]);
      final view = activity.asFitView();
      expect(view.sets, hasLength(1));
      expect(view.sets.first.exerciseCategory, 'Squat');
      expect(view.sets.first.repetitions, 10);
      expect(view.sets.first.weightKg, 60.0);
    });

    test('sets is empty when activity has no sets', () {
      final view = buildActivity().asFitView();
      expect(view.sets, isEmpty);
    });
  });

  group('FitSessionView swim fields', () {
    final base = DateTime.utc(2024, 1, 1, 10, 0, 0);

    RawActivity buildSwimActivity() {
      return RawActivity(
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
        sport: Sport.swimming,
        summary: const ActivitySummary(
          elapsedTime: Duration(minutes: 30),
          poolLengthMeters: 50.0,
          numActiveLengths: 40,
          swimStroke: SwimStroke.freestyle,
          subSport: 45,
          totalCycles: 600,
        ),
      );
    }

    test('poolLengthMeters is forwarded from ActivitySummary', () {
      final view = buildSwimActivity().asFitView();
      expect(view.session.poolLengthMeters, equals(50.0));
    });

    test('numActiveLengths is forwarded from ActivitySummary', () {
      final view = buildSwimActivity().asFitView();
      expect(view.session.numActiveLengths, equals(40));
    });

    test('swimStroke is forwarded from ActivitySummary', () {
      final view = buildSwimActivity().asFitView();
      expect(view.session.swimStroke, equals(SwimStroke.freestyle));
    });

    test('swim fields are null when summary is absent', () {
      final activity = RawActivity(
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
      );
      final view = activity.asFitView();
      expect(view.session.poolLengthMeters, isNull);
      expect(view.session.numActiveLengths, isNull);
      expect(view.session.swimStroke, isNull);
    });
  });

  group('FitLapView swim fields', () {
    final base = DateTime.utc(2024, 1, 1, 10, 0, 0);

    test('swim fields are forwarded from Lap', () {
      final activity = RawActivity(
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
        laps: [
          Lap(
            startTime: base,
            endTime: base.add(const Duration(minutes: 10)),
            numActiveLengths: 20,
            swimStroke: SwimStroke.backstroke,
          ),
        ],
        sport: Sport.swimming,
      );
      final view = activity.asFitView();
      expect(view.laps, hasLength(1));
      expect(view.laps.first.numActiveLengths, equals(20));
      expect(view.laps.first.swimStroke, equals(SwimStroke.backstroke));
    });

    test('swim fields are null when lap has no swim data', () {
      final activity = RawActivity(
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
        laps: [
          Lap(startTime: base, endTime: base.add(const Duration(minutes: 5))),
        ],
      );
      final view = activity.asFitView();
      expect(view.laps.first.numActiveLengths, isNull);
      expect(view.laps.first.swimStroke, isNull);
    });
  });
}
