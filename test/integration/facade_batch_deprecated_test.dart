// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for ActivityFiles facade API.
///
/// Tests the high-level convenience methods for loading, converting, and
/// exporting activity files.
library;

import 'dart:async';

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
        // losing sub-second precision (this used to silently divide by 1000).
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
          Channel.cadence: [], // empty — should be skipped
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
  // (`importBatch` was originally named `loadBatch`, kept as a deprecated
  // forwarder — see below.)
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

    test('deprecated loadBatch matches importBatch', () async {
      final viaNewName = await ActivityFiles.importBatch([
        sampleGpx,
      ], useIsolate: false);
      final viaOldName =
          // ignore: deprecated_member_use_from_same_package
          await ActivityFiles.loadBatch([sampleGpx], useIsolate: false);

      expect(viaNewName.successCount, equals(viaOldName.successCount));
    });
  });

  // ---------------------------------------------------------------------------
  // Facade API redesign: new names/homes added, old ones kept as deprecated
  // forwarders with identical behavior. See dev/docs/FACADE_API_REDESIGN.md
  // for the full staged rollout plan.
  // ---------------------------------------------------------------------------
  group('ActivityFiles.import matches deprecated ActivityFiles.load', () {
    test('identical activity/format for the same source', () async {
      final imported = await ActivityFiles.import(sampleGpx, useIsolate: false);
      // ignore: deprecated_member_use_from_same_package
      final loaded = await ActivityFiles.load(sampleGpx, useIsolate: false);

      expect(imported.hasErrors, isFalse);
      expect(imported.format, equals(loaded.format));
      expect(
        imported.activity.points.length,
        equals(loaded.activity.points.length),
      );
    });
  });

  group(
    'ActivityFiles.convertStream matches deprecated convertAndExportStream',
    () {
      test('identical encoded output', () async {
        final bytes = sampleGpx.codeUnits;

        final viaNewName = await ActivityFiles.convertStream(
          source: Stream<List<int>>.fromIterable([bytes]),
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.tcx,
          parseInIsolate: false,
        );
        final viaOldName =
            // ignore: deprecated_member_use_from_same_package
            await ActivityFiles.convertAndExportStream(
              source: Stream<List<int>>.fromIterable([bytes]),
              from: ActivityFileFormat.gpx,
              to: ActivityFileFormat.tcx,
              parseInIsolate: false,
            );

        expect(viaNewName.hasErrors, isFalse);
        expect(viaNewName.encoded, equals(viaOldName.encoded));
      });
    },
  );

  group(
    'RawEditor.merge/splitBySport match deprecated ActivityFiles equivalents',
    () {
      test('RawEditor.merge matches ActivityFiles.merge', () async {
        final a = (await ActivityFiles.import(
          sampleGpx,
          useIsolate: false,
        )).activity;
        final b = (await ActivityFiles.import(
          sampleGpx,
          useIsolate: false,
        )).activity;

        final viaEditor = RawEditor.merge([a, b], normalize: false);
        // ignore: deprecated_member_use_from_same_package
        final viaFacade = ActivityFiles.merge([a, b], normalize: false);

        expect(viaEditor.points.length, equals(viaFacade.points.length));
        expect(viaEditor.sport, equals(viaFacade.sport));
      });

      test('RawEditor.merge throws ArgumentError for an empty list', () {
        expect(() => RawEditor.merge(const []), throwsArgumentError);
      });

      test(
        'RawEditor.splitBySport matches ActivityFiles.splitBySport',
        () async {
          final activity = (await ActivityFiles.import(
            sampleGpx,
            useIsolate: false,
          )).activity;

          final viaEditor = RawEditor.splitBySport(activity);
          // ignore: deprecated_member_use_from_same_package
          final viaFacade = ActivityFiles.splitBySport(activity);

          expect(viaEditor.keys, equals(viaFacade.keys));
        },
      );
    },
  );

  group(
    'RawActivityBuilder GPX node builders match deprecated ActivityFiles.gpx*Node',
    () {
      test('activityLabelNode matches gpxActivityLabelNode', () {
        final viaBuilder = RawActivityBuilder.activityLabelNode('Morning Run');
        // ignore: deprecated_member_use_from_same_package
        final viaFacade = ActivityFiles.gpxActivityLabelNode('Morning Run');

        expect(viaBuilder.name, equals(viaFacade.name));
        expect(viaBuilder.value, equals(viaFacade.value));
        expect(viaBuilder.namespaceUri, equals(viaFacade.namespaceUri));
      });

      test('deviceNode matches gpxDeviceNode', () {
        const device = ActivityDeviceMetadata(
          manufacturer: 'Withings',
          model: 'ScanWatch',
        );

        final viaBuilder = RawActivityBuilder.deviceNode(device);
        // ignore: deprecated_member_use_from_same_package
        final viaFacade = ActivityFiles.gpxDeviceNode(device);

        expect(viaBuilder.name, equals(viaFacade.name));
        expect(viaBuilder.children.length, equals(viaFacade.children.length));
      });

      test('deviceSummaryNode matches gpxDeviceSummaryNode', () {
        const device = ActivityDeviceMetadata(manufacturer: 'Garmin');

        final viaBuilder = RawActivityBuilder.deviceSummaryNode(
          device,
          extras: {'battery': 95},
        );
        final viaFacade =
            // ignore: deprecated_member_use_from_same_package
            ActivityFiles.gpxDeviceSummaryNode(device, extras: {'battery': 95});

        expect(viaBuilder.name, equals(viaFacade.name));
        expect(viaBuilder.children.length, equals(viaFacade.children.length));
      });
    },
  );

  group('Deprecated ActivityFiles shortcuts still work identically', () {
    test(
      'sortAndDedup/trimInvalid/recomputeDistanceAndSpeed match edit() chain',
      () async {
        final activity = (await ActivityFiles.import(
          sampleGpx,
          useIsolate: false,
        )).activity;

        expect(
          // ignore: deprecated_member_use_from_same_package
          ActivityFiles.sortAndDedup(activity).points.length,
          equals(
            ActivityFiles.edit(activity).sortAndDedup().activity.points.length,
          ),
        );
        expect(
          // ignore: deprecated_member_use_from_same_package
          ActivityFiles.trimInvalid(activity).points.length,
          equals(
            ActivityFiles.edit(activity).trimInvalid().activity.points.length,
          ),
        );
        expect(
          // ignore: deprecated_member_use_from_same_package
          ActivityFiles.recomputeDistanceAndSpeed(activity).channels.keys,
          equals(
            ActivityFiles.edit(
              activity,
            ).recomputeDistanceAndSpeed().activity.channels.keys,
          ),
        );
      },
    );

    test('exportToCsv/importFromCsv round-trip', () async {
      final activity = (await ActivityFiles.import(
        sampleGpx,
        useIsolate: false,
      )).activity;

      // ignore: deprecated_member_use_from_same_package
      final csv = ActivityFiles.exportToCsv(activity);
      // ignore: deprecated_member_use_from_same_package
      final reparsed = ActivityFiles.importFromCsv(csv);

      expect(reparsed.activity.points.length, equals(activity.points.length));
    });

    test('exportToGeojson/importFromGeojson round-trip', () async {
      final activity = (await ActivityFiles.import(
        sampleGpx,
        useIsolate: false,
      )).activity;

      // ignore: deprecated_member_use_from_same_package
      final geojson = ActivityFiles.exportToGeojson(activity);
      // ignore: deprecated_member_use_from_same_package
      final reparsed = ActivityFiles.importFromGeojson(geojson);

      expect(reparsed.activity.points.length, equals(activity.points.length));
    });

    test('exportToCsvMultiple still encodes multiple activities', () async {
      final activity = (await ActivityFiles.import(
        sampleGpx,
        useIsolate: false,
      )).activity;

      // ignore: deprecated_member_use_from_same_package
      final csv = ActivityFiles.exportToCsvMultiple([activity, activity]);

      expect(csv, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Facade API redesign Tier 0/1.5: RawEditor.autoFix(), the EncoderOptions
  // geojson geometry flag, and buildAndExport().
  // ---------------------------------------------------------------------------
  group('RawEditor.autoFix (Tier 0)', () {
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

  group('EncoderOptions.geojsonGeometry (Tier 1.5)', () {
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

    test(
      'export(to: .geojson, options: points+channels) matches deprecated exportToGeojsonPoints',
      () async {
        final activity = (await ActivityFiles.import(
          sampleGpx,
          useIsolate: false,
        )).activity;

        final viaExport = ActivityFiles.export(
          activity: activity,
          to: ActivityFileFormat.geojson,
          options: const EncoderOptions(
            geojsonGeometry: GeojsonGeometry.points,
            geojsonIncludeChannels: true,
          ),
        );
        final viaDeprecated =
            // ignore: deprecated_member_use_from_same_package
            ActivityFiles.exportToGeojsonPoints(
              activity,
              includeChannels: true,
            );

        expect(viaExport.encoded, equals(viaDeprecated));
      },
    );
  });

  group('ActivityFiles.buildAndExport (Tier 1.5)', () {
    test(
      'matches convertAndExport(location: ...) for the same input',
      () async {
        final base = DateTime.utc(2024, 5, 3, 7);
        final ts0 = base.millisecondsSinceEpoch;
        final List<LocationStreamSample> location = [
          (timestamp: ts0, latitude: 40.0, longitude: -105.0, elevation: 1600),
          (
            timestamp: ts0 + 1000,
            latitude: 40.0002,
            longitude: -105.0002,
            elevation: 1602,
          ),
        ];
        final channels = {
          Channel.heartRate: [
            (timestamp: ts0, value: 135),
            (timestamp: ts0 + 1000, value: 148),
          ],
        };

        final viaBuildAndExport = await ActivityFiles.buildAndExport(
          location: location,
          channels: channels,
          label: 'Tier 1.5 build',
          sportSource: 'running',
          to: ActivityFileFormat.gpx,
        );
        final viaConvertAndExport = await ActivityFiles.convertAndExport(
          location: location,
          channels: channels,
          label: 'Tier 1.5 build',
          sportSource: 'running',
          to: ActivityFileFormat.gpx,
        );

        expect(viaBuildAndExport.hasErrors, isFalse);
        expect(viaBuildAndExport.encoded, equals(viaConvertAndExport.encoded));
      },
    );

    test(
      'threads autoFix through (previously silently ignored for streams)',
      () async {
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
          result.diagnostics.any(
            (d) => d.code == 'autofix.laps.auto_generated',
          ),
          isTrue,
        );
      },
    );
  });
}
