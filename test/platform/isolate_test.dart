// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for isolate platform adapters.
library;

import 'package:activity_files/activity_files.dart';
import 'package:activity_files/src/platform/isolate_runner.dart'
    as isolate_runner;
import 'package:activity_files/src/platform/isolate_runner_stub.dart'
    as isolate_stub;
import 'package:activity_files/src/platform/isolate_runner_vm.dart'
    as isolate_vm;
import 'package:test/test.dart';

RawActivity _fullyPopulatedActivity() {
  final t0 = DateTime.utc(2024, 5, 1, 6);
  final points = [
    GeoPoint(
      latitude: 40.0,
      longitude: -105.0,
      elevation: 1600.0,
      time: t0,
      gpxExtensions: [GpxExtensionNode(name: 'custom', value: '1')],
      gpxAttributes: {'hdop': '1.2'},
    ),
    GeoPoint(
      latitude: 40.001,
      longitude: -105.001,
      elevation: 1601.0,
      time: t0.add(const Duration(seconds: 10)),
    ),
  ];
  return RawActivity(
    points: points,
    channels: {
      Channel.heartRate: [
        Sample(time: t0, value: 140),
        Sample(time: points[1].time, value: 145),
      ],
    },
    laps: [
      Lap(
        startTime: t0,
        endTime: points[1].time,
        distanceMeters: 100,
        name: 'Lap 1',
        calories: 12,
        avgHeartRate: 142,
        maxHeartRate: 145,
        event: 9,
        eventType: 1,
        extraFitFields: {253: 42.0},
      ),
    ],
    sets: [
      WorkoutSet(
        startTime: t0,
        endTime: points[1].time,
        isRest: false,
        exerciseCategoryId: 28,
        repetitions: 10,
        weightKg: 60.0,
      ),
    ],
    events: [ActivityEvent(time: t0, event: 0, eventType: 0, data: 1)],
    lengths: [
      SwimLength(
        startTime: t0,
        endTime: points[1].time,
        isActive: true,
        totalStrokes: 8,
      ),
    ],
    sport: Sport.running,
    creator: 'Test Device',
    device: const ActivityDeviceMetadata(manufacturer: 'Garmin', model: 'X'),
    summary: const ActivitySummary(calories: 500, totalDistanceMeters: 5000),
    gpxMetadataName: 'Metadata name',
    gpxTrackName: 'Track name',
    gpxMetadataExtensions: [GpxExtensionNode(name: 'meta', value: 'v')],
    gpxTrackExtensions: [GpxExtensionNode(name: 'track', value: 'v')],
    gpxWaypoints: [GeoPoint(latitude: 41.0, longitude: -106.0, time: t0)],
    gpxRoutes: [
      GpxRoute(
        name: 'Route',
        points: [GeoPoint(latitude: 41.0, longitude: -106.0, time: t0)],
      ),
    ],
    gpxTrackSegments: const [0],
    tcxNotes: 'Some notes',
    tcxAuthor: 'Some author',
    metadata: const {'custom_key': 'custom_value'},
  );
}

void main() {
  group('Isolate adapters', () {
    test(
      'isolate runner stub executes inline when isolates unsupported',
      () async {
        var invoked = false;
        final result = await isolate_stub.runWithIsolation(() {
          invoked = true;
          return 7;
        }, useIsolate: true);
        expect(isolate_stub.isolatesSupported, isFalse);
        expect(result, equals(7));
        expect(invoked, isTrue);
      },
    );

    test('isolate runner VM offloads when isolates supported', () async {
      expect(isolate_vm.isolatesSupported, isTrue);
      final inline = await isolate_vm.runWithIsolation(
        () => 11,
        useIsolate: false,
      );
      expect(inline, equals(11));
      final offloaded = await isolate_vm.runWithIsolation(
        _isolatedComputation,
        useIsolate: true,
      );
      expect(offloaded, equals(73));
      final shared = await isolate_runner.runWithIsolation(
        _isolatedComputation,
        useIsolate: true,
      );
      expect(shared, equals(73));
    });
  });

  group('Isolate export data fidelity', () {
    test(
      'exportAsync(useIsolate: true) matches useIsolate: false byte-for-byte',
      () async {
        final activity = _fullyPopulatedActivity();

        final inline = await ActivityFiles.exportAsync(
          activity: activity,
          to: ActivityFileFormat.fit,
          normalize: false,
          useIsolate: false,
        );
        final isolated = await ActivityFiles.exportAsync(
          activity: activity,
          to: ActivityFileFormat.fit,
          normalize: false,
          useIsolate: true,
        );

        expect(isolated.asBytes(), equals(inline.asBytes()));
      },
    );

    test(
      'exportAsync(useIsolate: true) round-trips sets/summary/tcxNotes/metadata',
      () async {
        final activity = _fullyPopulatedActivity();

        final result = await ActivityFiles.exportAsync(
          activity: activity,
          to: ActivityFileFormat.fit,
          normalize: false,
          useIsolate: true,
        );

        expect(result.activity.sets, hasLength(1));
        expect(result.activity.events, hasLength(1));
        expect(result.activity.lengths, hasLength(1));
        expect(result.activity.summary, isNotNull);
        expect(result.activity.summary!.calories, equals(500));
        expect(result.activity.tcxNotes, equals('Some notes'));
        expect(result.activity.metadata['custom_key'], equals('custom_value'));
        expect(result.activity.laps.single.name, equals('Lap 1'));
        expect(result.activity.laps.single.calories, equals(12));
      },
    );
  });
}

int _isolatedComputation() => 73;
