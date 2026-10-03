// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for isolate platform adapters.
library;

import 'package:activity_files/activity_files.dart';
import 'package:activity_files/src/api/export_serialization.dart';
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

  group('EncoderOptions survive the isolate boundary', () {
    test('every field round-trips through ExportSerialization', () {
      final options = EncoderOptions(
        defaultMaxDelta: const Duration(seconds: 3),
        precisionLatLon: 4,
        precisionEle: 2,
        maxDeltaPerChannel: {Channel.heartRate: const Duration(seconds: 7)},
        gpxVersion: GpxVersion.v1_0,
        tcxVersion: TcxVersion.v1,
        geojsonGeometry: GeojsonGeometry.points,
        geojsonIncludeChannels: true,
      );
      final restored = ExportSerialization.encoderOptionsFromJson(
        ExportSerialization.encoderOptionsToJson(options),
      );
      expect(restored.defaultMaxDelta, equals(options.defaultMaxDelta));
      expect(restored.precisionLatLon, equals(options.precisionLatLon));
      expect(restored.precisionEle, equals(options.precisionEle));
      expect(
        restored.maxDeltaPerChannel[Channel.heartRate],
        equals(const Duration(seconds: 7)),
      );
      expect(restored.gpxVersion, equals(GpxVersion.v1_0));
      expect(restored.tcxVersion, equals(TcxVersion.v1));
      expect(restored.geojsonGeometry, equals(GeojsonGeometry.points));
      expect(restored.geojsonIncludeChannels, isTrue);
    });

    test('a payload without the GeoJSON keys falls back to the defaults', () {
      final restored = ExportSerialization.encoderOptionsFromJson({
        'defaultMaxDeltaMicros': const Duration(seconds: 5).inMicroseconds,
        'precisionLatLon': 6,
        'precisionEle': 1,
        'maxDeltaPerChannel': <String, int>{},
        'gpxVersion': 'v1_1',
        'tcxVersion': 'v2',
      });
      expect(restored.geojsonGeometry, equals(GeojsonGeometry.lineString));
      expect(restored.geojsonIncludeChannels, isFalse);
    });

    test('exportAsync in an isolate emits Point features when asked', () async {
      final activity = _fullyPopulatedActivity();
      const options = EncoderOptions(
        geojsonGeometry: GeojsonGeometry.points,
        geojsonIncludeChannels: true,
      );
      final direct = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.geojson,
        options: options,
      );
      final isolated = await ActivityFiles.exportAsync(
        activity: activity,
        to: ActivityFileFormat.geojson,
        options: options,
        useIsolate: true,
      );
      expect(isolated.asString(), equals(direct.asString()));
      expect(isolated.asString(), contains('"type":"Point"'));
      expect(isolated.asString(), isNot(contains('"type":"LineString"')));
    });
  });
}

int _isolatedComputation() => 73;
