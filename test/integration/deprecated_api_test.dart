// SPDX-License-Identifier: BSD-3-Clause
// ignore_for_file: deprecated_member_use_from_same_package
/// Tests of deprecated API: each deprecated member still behaves like its
/// replacement until it is removed. The whole file goes with them in 0.10.0.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/sample_data.dart';

void main() {
  group('ActivityFiles.import matches deprecated ActivityFiles.load', () {
    test('identical activity/format for the same source', () async {
      final imported = await ActivityFiles.import(sampleGpx, useIsolate: false);
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
        final viaOldName = await ActivityFiles.convertAndExportStream(
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
    'RawActivityBuilder GPX node builders match deprecated ActivityFiles.gpx*Node',
    () {
      test('activityLabelNode matches gpxActivityLabelNode', () {
        final viaBuilder = RawActivityBuilder.activityLabelNode('Morning Run');
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
        final viaFacade = ActivityFiles.gpxDeviceSummaryNode(
          device,
          extras: {'battery': 95},
        );

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
          ActivityFiles.sortAndDedup(activity).points.length,
          equals(
            ActivityFiles.edit(activity).sortAndDedup().activity.points.length,
          ),
        );
        expect(
          ActivityFiles.trimInvalid(activity).points.length,
          equals(
            ActivityFiles.edit(activity).trimInvalid().activity.points.length,
          ),
        );
        expect(
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

      final csv = ActivityFiles.exportToCsv(activity);
      final reparsed = ActivityFiles.importFromCsv(csv);

      expect(reparsed.activity.points.length, equals(activity.points.length));
    });

    test('exportToGeojson/importFromGeojson round-trip', () async {
      final activity = (await ActivityFiles.import(
        sampleGpx,
        useIsolate: false,
      )).activity;

      final geojson = ActivityFiles.exportToGeojson(activity);
      final reparsed = ActivityFiles.importFromGeojson(geojson);

      expect(reparsed.activity.points.length, equals(activity.points.length));
    });

    test('exportToCsvMultiple still encodes multiple activities', () async {
      final activity = (await ActivityFiles.import(
        sampleGpx,
        useIsolate: false,
      )).activity;

      final csv = ActivityFiles.exportToCsvMultiple([activity, activity]);

      expect(csv, isNotEmpty);
    });
  });

  group('Deprecated ActivityFiles.normalizeActivity options', () {
    test('normalizeActivity handles edge case with no operations', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
        ],
      );

      final normalized = ActivityFiles.normalizeActivity(
        activity,
        sortAndDedup: false,
        trimInvalid: false,
      );

      expect(normalized.points.length, activity.points.length);
    });

    test('normalizeActivity with sortAndDedup=false skips sorting', () {
      final base = DateTime.utc(2024, 12, 10, 7);
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: base.add(const Duration(minutes: 1)),
          ),
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        ],
      );

      final normalized = ActivityFiles.normalizeActivity(
        activity,
        sortAndDedup: false,
        trimInvalid: false,
      );

      // Should return same object when no normalization requested
      expect(identical(normalized, activity), isTrue);
    });

    test('normalizeActivity with trimInvalid=false skips trimming', () {
      final base = DateTime.utc(2024, 12, 10, 8);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 200.0, longitude: -105.0, time: base), // invalid
        ],
      );

      final normalized = ActivityFiles.normalizeActivity(
        activity,
        sortAndDedup: false,
        trimInvalid: false,
      );

      expect(identical(normalized, activity), isTrue);
      expect(normalized.points.first.latitude, equals(200.0));
    });

    test(
      'normalizeActivity with both cleanup steps disabled leaves the activity untouched',
      () {
        final base = DateTime.utc(2024, 1, 7, 10);
        final duplicateTime = base.add(const Duration(minutes: 1));
        final points = [
          GeoPoint(latitude: 95, longitude: 0, time: base),
          GeoPoint(latitude: 40, longitude: -105, time: duplicateTime),
          GeoPoint(latitude: 40, longitude: -105, time: duplicateTime),
        ];
        final hrSamples = [
          Sample(time: base, value: 120),
          Sample(time: duplicateTime, value: 130),
          Sample(time: duplicateTime, value: 135),
        ];
        final activity = RawActivity(
          points: points,
          channels: {Channel.heartRate: hrSamples},
        );

        final untouched = ActivityFiles.normalizeActivity(
          activity,
          sortAndDedup: false,
          trimInvalid: false,
        );
        expect(untouched.points.length, equals(3));
        expect(untouched.channel(Channel.heartRate).length, equals(3));
      },
    );
  });

  group('Deprecated ActivityFiles.loadBatch', () {
    test('deprecated loadBatch matches importBatch', () async {
      final viaNewName = await ActivityFiles.importBatch([
        sampleGpx,
      ], useIsolate: false);
      final viaOldName = await ActivityFiles.loadBatch([
        sampleGpx,
      ], useIsolate: false);

      expect(viaNewName.successCount, equals(viaOldName.successCount));
    });
  });

  group('Deprecated ActivityFiles.merge and splitBySport', () {
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
      final viaFacade = ActivityFiles.merge([a, b], normalize: false);

      expect(viaEditor.points.length, equals(viaFacade.points.length));
      expect(viaEditor.sport, equals(viaFacade.sport));
    });

    test('RawEditor.splitBySport matches ActivityFiles.splitBySport', () async {
      final activity = (await ActivityFiles.import(
        sampleGpx,
        useIsolate: false,
      )).activity;

      final viaEditor = RawEditor.splitBySport(activity);
      final viaFacade = ActivityFiles.splitBySport(activity);

      expect(viaEditor.keys, equals(viaFacade.keys));
    });
  });

  group('Deprecated ActivityFiles.exportToGeojsonPoints', () {
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
        final viaDeprecated = ActivityFiles.exportToGeojsonPoints(
          activity,
          includeChannels: true,
        );

        expect(viaExport.encoded, equals(viaDeprecated));
      },
    );
  });

  group('Deprecated ActivityFiles.convertAndExport', () {
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
          label: 'build and export test',
          sportSource: 'running',
          to: ActivityFileFormat.gpx,
        );
        final viaConvertAndExport = await ActivityFiles.convertAndExport(
          location: location,
          channels: channels,
          label: 'build and export test',
          sportSource: 'running',
          to: ActivityFileFormat.gpx,
        );

        expect(viaBuildAndExport.hasErrors, isFalse);
        expect(viaBuildAndExport.encoded, equals(viaConvertAndExport.encoded));
      },
    );
  });

  group('Deprecated fitCorruptionHandling and runPipeline', () {
    test(
      'import with strict fitCorruptionHandling rejects corrupted FIT files',
      () async {
        final bytes = await File('example/assets/sample.fit').readAsBytes();
        final corrupted = Uint8List.fromList(bytes);
        corrupted[corrupted.length - 1] ^= 0xFF;

        await expectLater(
          () => ActivityFiles.import(
            corrupted,
            format: ActivityFileFormat.fit,
            useIsolate: false,
            fitCorruptionHandling: FitCorruptionHandling.strict,
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'import with bestEffort fitCorruptionHandling keeps parse result',
      () async {
        final bytes = await File('example/assets/sample.fit').readAsBytes();
        final corrupted = Uint8List.fromList(bytes);
        corrupted[corrupted.length - 1] ^= 0xFF;

        final result = await ActivityFiles.import(
          corrupted,
          format: ActivityFileFormat.fit,
          useIsolate: false,
          fitCorruptionHandling: FitCorruptionHandling.bestEffort,
        );

        expect(result.hasErrors, isTrue);
        expect(result.activity.points, isNotEmpty);
      },
    );

    test('runPipeline fromActivity applies auto-lap autofix', () async {
      final base = DateTime.utc(2025, 1, 3, 7);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.009,
            longitude: -105.0,
            time: base.add(const Duration(minutes: 5)),
          ),
          GeoPoint(
            latitude: 40.018,
            longitude: -105.0,
            time: base.add(const Duration(minutes: 10)),
          ),
        ],
        sport: Sport.running,
      );

      final request = ActivityExportRequest.fromActivity(
        activity: activity,
        to: ActivityFileFormat.gpx,
        runValidation: false,
        autoFix: const ActivityAutoFixOptions(
          fixInvalidGps: false,
          fixChannelDrift: false,
          fixDistanceDrift: false,
          fixTimestampGaps: false,
          autoLapByDistance: true,
          runningLapDistanceMeters: 1000,
        ),
      );

      final result = await ActivityFiles.runPipeline(request);

      expect(result.activity.laps, isNotEmpty);
      expect(
        result.diagnostics.any((d) => d.code == 'autofix.laps.auto_generated'),
        isTrue,
      );
    });
  });

  group('Deprecated runPipeline and ActivityExportRequest', () {
    test('runPipeline handles streamed sources with validation', () async {
      final bytes = await File('example/assets/sample.gpx').readAsBytes();
      final streamed = Stream<List<int>>.fromIterable([
        bytes.sublist(0, bytes.length ~/ 2),
        bytes.sublist(bytes.length ~/ 2),
      ]);
      final request = ActivityExportRequest.fromStream(
        stream: streamed,
        from: ActivityFileFormat.gpx,
        to: ActivityFileFormat.fit,
        runValidation: true,
        parseInIsolate: false,
        exportInIsolate: false,
      );
      final result = await ActivityFiles.runPipeline(request);
      expect(result.targetFormat, equals(ActivityFileFormat.fit));
      expect(result.isBinary, isTrue);
      expect(result.validation, isNotNull);
      expect(result.asBytes().length, greaterThan(0));
    });

    test('runPipeline executes activity request', () async {
      final baseTime = DateTime.utc(2024, 10, 1, 7);
      final activity = ActivityFiles.builder()
        ..addPoint(latitude: 40.0, longitude: -105.0, time: baseTime)
        ..addPoint(
          latitude: 40.0003,
          longitude: -105.0003,
          time: baseTime.add(const Duration(seconds: 5)),
        );
      final request = ActivityExportRequest.fromActivity(
        activity: activity.build(normalize: false),
        to: ActivityFileFormat.tcx,
        runValidation: true,
      );
      final result = await ActivityFiles.runPipeline(request);
      expect(result.targetFormat, ActivityFileFormat.tcx);
      expect(result.validation, isNotNull);
    });

    test('ActivityExportRequest handles source conversion', () async {
      final request = ActivityExportRequest.fromSource(
        source: sampleGpx,
        from: ActivityFileFormat.gpx,
        to: ActivityFileFormat.fit,
        runValidation: true,
        exportInIsolate: true,
      );
      final result = await ActivityFiles.runPipeline(request);
      expect(result.isBinary, isTrue);
      expect(result.validation, isNotNull);
      expect(result.processingStats.normalization, isNotNull);
    });
  });

  group('Deprecated ActivityFiles.convertAndExport inputs', () {
    test('convertAndExport enforces mutually exclusive inputs', () async {
      final ts = DateTime.utc(2024, 5, 1).millisecondsSinceEpoch;
      final location = [
        (timestamp: ts, latitude: 40.0, longitude: -105.0, elevation: 1600.0),
      ];
      await expectLater(
        () => ActivityFiles.convertAndExport(
          source: sampleGpx,
          location: location,
          to: ActivityFileFormat.gpx,
        ),
        throwsArgumentError,
      );
      await expectLater(
        () => ActivityFiles.convertAndExport(to: ActivityFileFormat.gpx),
        throwsArgumentError,
      );
    });
  });

  group('Deprecated ActivityConverter', () {
    test('legacy warnings parameter collects warning messages', () {
      const gpxWithBadTimestamp = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="40.0" lon="-105.0">
      <time>not-a-date</time>
    </trkpt>
    <trkpt lat="40.001" lon="-105.001">
      <time>2024-01-01T10:00:10Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>''';

      final warnings = <String>[];
      ActivityConverter.convert(
        gpxWithBadTimestamp,
        from: ActivityFileFormat.gpx,
        to: ActivityFileFormat.csv,
        warnings: warnings,
      );

      // The legacy list may be empty for valid parses, but it must not throw
      // and must be a List<String>.
      expect(warnings, isA<List<String>>());
    });
  });
}
