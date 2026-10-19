// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for ActivityFiles facade API.
///
/// Tests the high-level convenience methods for loading, converting, and
/// exporting activity files.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/sample_data.dart';

void main() {
  group('ActivityFiles.channelSamplesFrom', () {
    test('returns empty map for activity with no channels', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10),
          ),
        ],
      );

      final result = ActivityFiles.channelSamplesFrom(activity);

      expect(result, isEmpty);
    });

    test(
      'converts HR samples to ChannelStreamSample with millisecond timestamps '
      'matching builderFromStreams/StreamTimestampDecoder',
      () {
        final t0 = DateTime.utc(2024, 1, 1, 10, 0, 0, 250);
        final t1 = DateTime.utc(2024, 1, 1, 10, 0, 10, 750);
        final activity = RawActivity(
          channels: {
            Channel.heartRate: [
              Sample(time: t0, value: 140),
              Sample(time: t1, value: 145),
            ],
          },
        );

        final result = ActivityFiles.channelSamplesFrom(activity);

        expect(result, contains(Channel.heartRate));
        final samples = result[Channel.heartRate]!;
        expect(samples, hasLength(2));
        expect(samples[0].timestamp, equals(t0.millisecondsSinceEpoch));
        expect(samples[0].value, equals(140));
        expect(samples[1].timestamp, equals(t1.millisecondsSinceEpoch));
        expect(samples[1].value, equals(145));

        // Round-trips through the default StreamTimestampDecoder without
        // losing sub-second precision.
        final builder = ActivityFiles.builderFromStreams(
          location: [
            (
              timestamp: samples[0].timestamp,
              latitude: 40.0,
              longitude: -105.0,
              elevation: null,
            ),
          ],
          channels: {Channel.heartRate: samples},
        );
        final rebuilt = builder.build(normalize: false);
        expect(
          rebuilt.channel(Channel.heartRate).first.time,
          equals(t0.toUtc()),
        );
      },
    );

    test('skips channels with no samples', () {
      final t0 = DateTime.utc(2024, 1, 1, 10);
      final activity = RawActivity(
        channels: {
          Channel.heartRate: [Sample(time: t0, value: 140)],
          Channel.cadence: [], // empty, should be skipped
        },
      );

      final result = ActivityFiles.channelSamplesFrom(activity);

      expect(result, contains(Channel.heartRate));
      expect(result, isNot(contains(Channel.cadence)));
    });

    test('preserves all populated channels', () {
      final t0 = DateTime.utc(2024, 1, 1, 10);
      final activity = RawActivity(
        channels: {
          Channel.heartRate: [Sample(time: t0, value: 140)],
          Channel.cadence: [Sample(time: t0, value: 85)],
          Channel.power: [Sample(time: t0, value: 220)],
        },
      );

      final result = ActivityFiles.channelSamplesFrom(activity);

      expect(
        result.keys,
        containsAll([Channel.heartRate, Channel.cadence, Channel.power]),
      );
      expect(result.length, equals(3));
    });

    test('round-trips channel values accurately', () {
      final t0 = DateTime.utc(2024, 1, 1, 10);
      final activity = RawActivity(
        channels: {
          Channel.power: [Sample(time: t0, value: 275.5)],
        },
      );

      final result = ActivityFiles.channelSamplesFrom(activity);

      expect(result[Channel.power]!.single.value, equals(275.5));
    });
  });

  // ---------------------------------------------------------------------------
  // ActivityFiles.importBatch + BatchImportResult / BatchImportFailure
  // (`loadBatch` is a deprecated forwarder for `importBatch`, see below.)
  // ---------------------------------------------------------------------------
  group('ActivityFiles.importBatch', () {
    test('loads multiple valid sources and all succeed', () async {
      final result = await ActivityFiles.importBatch([
        sampleGpx,
        sampleGpx,
      ], useIsolate: false);

      expect(result.allSucceeded, isTrue);
      expect(result.successCount, equals(2));
      expect(result.failureCount, equals(0));
      expect(result.total, equals(2));
      expect(result.failures, isEmpty);
    });

    test('captures failures without stopping by default', () async {
      const bad = 'this is not a valid activity file';
      final result = await ActivityFiles.importBatch([
        sampleGpx,
        bad,
        sampleGpx,
      ], useIsolate: false);

      expect(result.total, equals(3));
      expect(result.successCount, equals(2));
      expect(result.failureCount, equals(1));
      expect(result.allSucceeded, isFalse);
    });

    test('BatchImportFailure exposes source and error', () async {
      const bad = 'not a valid file';
      final result = await ActivityFiles.importBatch([bad], useIsolate: false);

      expect(result.failures, hasLength(1));
      final failure = result.failures.first;
      expect(failure.source, equals(bad));
      expect(failure.error, isNotNull);
    });

    test('stopOnError halts after first failure', () async {
      const bad = 'not a valid file';
      final result = await ActivityFiles.importBatch(
        [bad, sampleGpx, sampleGpx],
        useIsolate: false,
        stopOnError: true,
      );

      // Only one item processed before stop
      expect(result.total, equals(3));
      expect(result.failureCount, equals(1));
      expect(result.successCount, equals(0));
    });

    test('onProgress callback fires for each item', () async {
      final progressLog = <(int, int)>[];
      await ActivityFiles.importBatch(
        [sampleGpx, sampleGpx, sampleGpx],
        useIsolate: false,
        onProgress: (done, total) => progressLog.add((done, total)),
      );

      expect(progressLog, hasLength(3));
      expect(progressLog[0], equals((1, 3)));
      expect(progressLog[1], equals((2, 3)));
      expect(progressLog[2], equals((3, 3)));
    });

    test('onProgress fires even when a source fails', () async {
      const bad = 'not valid';
      final progressLog = <int>[];
      await ActivityFiles.importBatch(
        [sampleGpx, bad, sampleGpx],
        useIsolate: false,
        onProgress: (done, _) => progressLog.add(done),
      );

      expect(progressLog, equals([1, 2, 3]));
    });

    test('empty source list returns empty result', () async {
      final result = await ActivityFiles.importBatch([], useIsolate: false);

      expect(result.total, equals(0));
      expect(result.successCount, equals(0));
      expect(result.failureCount, equals(0));
      expect(result.allSucceeded, isTrue);
    });

    test('BatchImportFailure.toString includes source and error', () async {
      const bad = 'bad source';
      final result = await ActivityFiles.importBatch([bad], useIsolate: false);

      final str = result.failures.first.toString();
      expect(str, contains('BatchImportFailure'));
      expect(str, contains('bad source'));
    });
  });

  group('RawEditor.merge', () {
    test('RawEditor.merge throws ArgumentError for an empty list', () {
      expect(() => RawEditor.merge(const []), throwsArgumentError);
    });
  });

  group('RawEditor.autoFix', () {
    test(
      'matches the diagnostics-producing autoFix pipeline exercised via convert',
      () async {
        final base = DateTime.utc(2025, 1, 1, 10);
        final activity = RawActivity(
          points: [
            GeoPoint(latitude: 52.52, longitude: 13.405, time: base),
            GeoPoint(
              latitude: 200,
              longitude: 13.406,
              time: base.add(const Duration(minutes: 5)),
            ),
            GeoPoint(
              latitude: 52.53,
              longitude: 13.41,
              time: base.add(const Duration(minutes: 10)),
            ),
          ],
        );
        const options = ActivityAutoFixOptions(
          fixInvalidGps: true,
          fixChannelDrift: true,
          fixDistanceDrift: true,
          fixTimestampGaps: true,
          gapThreshold: Duration(minutes: 3),
          maxInsertedGapPoints: 20,
        );

        final fixed = RawEditor(activity).autoFix(options).activity;

        expect(fixed.points.any((p) => p.latitude.abs() > 90), isFalse);
        expect(fixed.channel(Channel.distance), isNotEmpty);
        expect(fixed.points.length, greaterThan(activity.points.length));
      },
    );

    test('is chainable with other RawEditor operations', () {
      final base = DateTime.utc(2025, 1, 2, 8);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.009,
            longitude: -105.0,
            time: base.add(const Duration(minutes: 5)),
          ),
        ],
      );

      final result = RawEditor(activity)
          .autoFix(
            const ActivityAutoFixOptions(
              fixInvalidGps: false,
              fixChannelDrift: false,
              fixDistanceDrift: false,
              fixTimestampGaps: false,
              autoLapByDistance: true,
              autoLapDistanceMeters: 100,
            ),
          )
          .smoothHR(3)
          .activity;

      expect(result.laps, isNotEmpty);
    });
  });

  group('EncoderOptions.geojsonGeometry', () {
    test('export(to: .geojson) defaults to a LineString feature', () async {
      final activity = (await ActivityFiles.import(
        sampleGpx,
        useIsolate: false,
      )).activity;

      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.geojson,
      );

      expect(result.encoded, contains('"LineString"'));
    });

    test(
      'export(to: .geojson, options: points) matches GeojsonEncoder.encodeAsPoints',
      () async {
        final activity = (await ActivityFiles.import(
          sampleGpx,
          useIsolate: false,
        )).activity;

        final result = ActivityFiles.export(
          activity: activity,
          to: ActivityFileFormat.geojson,
          options: const EncoderOptions(
            geojsonGeometry: GeojsonGeometry.points,
          ),
        );

        expect(result.encoded, contains('"Point"'));
        expect(result.encoded, isNot(contains('"LineString"')));
      },
    );
  });

  group('ActivityFiles.buildAndExport', () {
    test('threads autoFix through for stream input', () async {
      final base = DateTime.utc(2024, 5, 4, 6);
      final ts0 = base.millisecondsSinceEpoch;
      final List<LocationStreamSample> location = [
        (timestamp: ts0, latitude: 40.0, longitude: -105.0, elevation: 1600),
        (
          timestamp: ts0 + 300000,
          latitude: 40.009,
          longitude: -105.0,
          elevation: 1600,
        ),
      ];

      final result = await ActivityFiles.buildAndExport(
        location: location,
        sport: Sport.running,
        to: ActivityFileFormat.gpx,
        autoFix: const ActivityAutoFixOptions(
          fixInvalidGps: false,
          fixChannelDrift: false,
          fixDistanceDrift: false,
          fixTimestampGaps: false,
          autoLapByDistance: true,
          autoLapDistanceMeters: 100,
        ),
      );

      expect(result.activity.laps, isNotEmpty);
      expect(
        result.diagnostics.any((d) => d.code == 'autofix.laps.auto_generated'),
        isTrue,
      );
    });
  });
}
