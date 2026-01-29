// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:activity_files/src/api/export_serialization.dart';
import 'package:activity_files/src/api/export_stats.dart';
import 'package:activity_files/src/platform/file_system.dart' as file_system;
import 'package:activity_files/src/platform/file_system_io.dart' as fs_io;
import 'package:activity_files/src/platform/file_system_stub.dart' as fs_stub;
import 'package:activity_files/src/platform/isolate_runner.dart'
    as isolate_runner;
import 'package:activity_files/src/platform/isolate_runner_stub.dart'
    as isolate_stub;
import 'package:activity_files/src/platform/isolate_runner_vm.dart'
    as isolate_vm;
import 'package:test/test.dart';

void main() {
  const encoderOptions = EncoderOptions(
    defaultMaxDelta: Duration(seconds: 3),
    precisionLatLon: 6,
    precisionEle: 2,
  );

  // TODO(0.5.0)(test): Add multi-device test suite (Wahoo, Coros, eBike files)
  // to validate FIT extraction works across different device profiles and
  // vendor-specific field implementations.

  group('Facade convenience', () {
    test('load infers GPX format from inline content', () async {
      final result = await ActivityFiles.load(_sampleGpx, useIsolate: false);
      expect(result.format, equals(ActivityFileFormat.gpx));
      expect(result.activity.points.length, equals(3));
      expect(result.diagnostics, isEmpty);
    });

    test('inferSport applies registered mappers before fallbacks', () {
      Sport? mapper(dynamic source) {
        return source is int && source == 42 ? Sport.cycling : null;
      }

      ActivityFiles.registerSportMapper(mapper);
      addTearDown(() => ActivityFiles.unregisterSportMapper(mapper));
      expect(ActivityFiles.inferSport(42), equals(Sport.cycling));
      expect(ActivityFiles.inferSport('running'), equals(Sport.running));
    });

    test('inferSport derives sport hints from descriptive labels', () {
      expect(ActivityFiles.inferSport('Morning Run'), equals(Sport.running));
      expect(
        ActivityFiles.inferSport('Lunch Ride 40km'),
        equals(Sport.cycling),
      );
      expect(
        ActivityFiles.inferSport('Sunset Walk With Dog'),
        equals(Sport.walking),
      );
    });

    test('convert returns binary FIT payload', () async {
      final conversion = await ActivityFiles.convert(
        source: _sampleGpx,
        to: ActivityFileFormat.fit,
        useIsolate: false,
      );
      expect(conversion.isBinary, isTrue);
      final bytes = conversion.asBytes();
      expect(bytes.length, greaterThan(0));
      final parsed = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      expect(parsed.activity.points.length, greaterThan(0));
      final stats = conversion.processingStats;
      expect(stats.normalization, isNotNull);
      expect(stats.normalization!.applied, isTrue);
      expect(stats.validationDuration, isNull);
    });

    test(
      'load detects UTF-16 GPX payloads without misclassification',
      () async {
        final encoded = _encodeUtf16LeWithBom(_sampleGpx);
        final result = await ActivityFiles.load(
          Uint8List.fromList(encoded),
          useIsolate: false,
        );
        expect(result.format, equals(ActivityFileFormat.gpx));
        expect(result.activity.points.length, equals(3));
      },
    );

    test('load decodes Latin-1 byte payloads when encoding provided', () async {
      const gpxWithAccents = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Latiné Device" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Sortie Résumé</name>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T00:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
''';
      final bytes = Uint8List.fromList(latin1.encode(gpxWithAccents));

      final result = await ActivityFiles.load(
        bytes,
        useIsolate: false,
        encoding: latin1,
      );

      expect(result.activity.points, isNotEmpty);
      expect(result.activity.creator, equals('Latiné Device'));
    });

    test('convert supports export isolation', () async {
      final conversion = await ActivityFiles.convert(
        source: _sampleGpx,
        to: ActivityFileFormat.fit,
        useIsolate: false,
        exportInIsolate: true,
      );
      expect(conversion.isBinary, isTrue);
      expect(conversion.asBytes().length, greaterThan(0));
      expect(conversion.processingStats.normalization, isNotNull);
    });

    test('convertAndExport enforces mutually exclusive inputs', () async {
      final ts = DateTime.utc(2024, 5, 1).millisecondsSinceEpoch;
      final location = [
        (timestamp: ts, latitude: 40.0, longitude: -105.0, elevation: 1600.0),
      ];
      await expectLater(
        () => ActivityFiles.convertAndExport(
          source: _sampleGpx,
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

    test('load and convert accept chunked stream sources', () async {
      final bytes = utf8.encode(_sampleGpx);
      final stream = Stream<List<int>>.fromIterable([
        bytes.sublist(0, bytes.length ~/ 2),
        bytes.sublist(bytes.length ~/ 2),
      ]);
      final loaded = await ActivityFiles.load(stream, useIsolate: false);
      expect(loaded.format, equals(ActivityFileFormat.gpx));
      expect(loaded.activity.points.length, equals(3));

      final convertStream = Stream<List<int>>.fromIterable([
        bytes.sublist(0, 30),
        bytes.sublist(30),
      ]);
      final conversion = await ActivityFiles.convert(
        source: convertStream,
        to: ActivityFileFormat.fit,
        useIsolate: false,
      );
      expect(conversion.sourceFormat, equals(ActivityFileFormat.gpx));
      expect(conversion.isBinary, isTrue);
      expect(conversion.asBytes().length, greaterThan(0));
    });

    test('load detects format from fragmented streams without hints', () async {
      final bytes = utf8.encode(_sampleGpx);
      final stream = Stream<List<int>>.fromIterable([
        bytes.sublist(0, 3),
        bytes.sublist(3, 25),
        bytes.sublist(25),
      ]);

      final loaded = await ActivityFiles.load(stream, useIsolate: false);

      expect(loaded.format, equals(ActivityFileFormat.gpx));
      expect(loaded.activity.points, isNotEmpty);
    });

    test('load subscribes to stream sources only once', () async {
      final bytes = utf8.encode(_sampleGpx);
      final stream = _CountingStream([bytes.sublist(0, 40), bytes.sublist(40)]);

      final loaded = await ActivityFiles.load(stream, useIsolate: false);

      expect(loaded.activity.points, isNotEmpty);
      expect(stream.listenCount, equals(1));
    });

    test('parseStream surfaces format exceptions as diagnostics', () async {
      final stream = Stream<List<int>>.fromIterable([utf8.encode(_sampleGpx)]);
      final result = await ActivityParser.parseStream(
        stream,
        ActivityFileFormat.gpx,
        useIsolate: false,
        maxBytes: 4,
      );
      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isNotEmpty,
      );
      expect(result.activity.points, isEmpty);
    });

    test('load exposes payload bytes for stream-backed sources', () async {
      final bytes = utf8.encode(_sampleGpx);
      final stream = Stream<List<int>>.fromIterable([
        bytes.sublist(0, 15),
        bytes.sublist(15),
      ]);

      final loaded = await ActivityFiles.load(stream, useIsolate: false);

      expect(loaded.bytesPayload, isNotNull);
      expect(loaded.bytesPayload, orderedEquals(bytes));
      expect(loaded.stringPayload, isNull);
    });

    test(
      'stream-backed bytesPayload can be handed to other upload APIs',
      () async {
        final bytes = utf8.encode(_sampleGpx);
        final stream = Stream<List<int>>.fromIterable([
          bytes.sublist(0, 20),
          bytes.sublist(20, 60),
          bytes.sublist(60),
        ]);
        final loaded = await ActivityFiles.load(stream, useIsolate: false);
        final payload = loaded.bytesPayload;
        expect(payload, isNotNull);
        expect(payload, orderedEquals(bytes));

        final reparsed = await ActivityFiles.load(payload!, useIsolate: false);
        expect(reparsed.format, equals(ActivityFileFormat.gpx));
        expect(
          reparsed.activity.points.length,
          equals(loaded.activity.points.length),
        );
      },
    );

    test(
      'convertAndExport accepts File sources with auto-detected format',
      () async {
        final file = File('example/assets/sample.tcx');
        final result = await ActivityFiles.convertAndExport(
          source: file,
          to: ActivityFileFormat.gpx,
          useIsolate: false,
          runValidation: true,
        );
        expect(result.targetFormat, equals(ActivityFileFormat.gpx));
        expect(result.activity.points, isNotEmpty);
        expect(result.validation, isNotNull);
        expect(result.asString(), contains('<gpx'));
      },
    );

    test('load requires allowFilePaths for string paths', () async {
      final path = 'example/assets/sample.gpx';
      await expectLater(
        () => ActivityFiles.load(path, useIsolate: false),
        throwsArgumentError,
      );
      final allowed = await ActivityFiles.load(
        path,
        useIsolate: false,
        allowFilePaths: true,
      );
      expect(allowed.activity.points, isNotEmpty);
      expect(allowed.sourceDescription, equals(path));
    });

    test('convert requires allowFilePaths for string paths', () async {
      final path = 'example/assets/sample.gpx';
      await expectLater(
        () => ActivityFiles.convert(
          source: path,
          to: ActivityFileFormat.fit,
          useIsolate: false,
        ),
        throwsArgumentError,
      );
      final conversion = await ActivityFiles.convert(
        source: path,
        to: ActivityFileFormat.fit,
        useIsolate: false,
        allowFilePaths: true,
      );
      expect(conversion.sourceFormat, equals(ActivityFileFormat.gpx));
      expect(conversion.activity.points, isNotEmpty);
    });

    test('convert skips validation unless requested', () async {
      final conversion = await ActivityFiles.convert(
        source: _sampleGpx,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
      );
      expect(conversion.validation, isNull);
      expect(conversion.processingStats.validationDuration, isNull);
    });

    test('convert runs validation when requested', () async {
      final conversion = await ActivityFiles.convert(
        source: _sampleGpx,
        to: ActivityFileFormat.tcx,
        runValidation: true,
        useIsolate: false,
      );
      expect(conversion.validation, isNotNull);
      expect(conversion.processingStats.validationDuration, isNotNull);
    });

    test('load surfaces malformed GPX payloads as diagnostics', () async {
      const malformed = '<gpx version="1.1"><trk><trkseg></gpx';
      final result = await ActivityFiles.load(
        malformed,
        format: ActivityFileFormat.gpx,
        useIsolate: false,
      );
      expect(result.hasErrors, isTrue);
      expect(
        result.diagnostics.where((d) => d.code == 'gpx.parse.xml_error'),
        isNotEmpty,
      );
      expect(result.activity.points, isEmpty);
    });

    test('load surfaces malformed TCX payloads as diagnostics', () async {
      const malformed =
          '<TrainingCenterDatabase><Activities></TrainingCenterDatabase';
      final result = await ActivityFiles.load(
        malformed,
        format: ActivityFileFormat.tcx,
        useIsolate: false,
      );
      expect(result.hasErrors, isTrue);
      expect(
        result.diagnostics.where((d) => d.code == 'tcx.parse.xml_error'),
        isNotEmpty,
      );
      expect(result.activity.points, isEmpty);
    });

    test('load surfaces invalid FIT binaries as diagnostics', () async {
      final invalid = Uint8List.fromList(List<int>.filled(16, 0));
      final result = await ActivityFiles.load(
        invalid,
        format: ActivityFileFormat.fit,
        useIsolate: false,
      );
      expect(result.hasErrors, isTrue);
      expect(
        result.diagnostics.where((d) => d.code == 'parser.format_exception'),
        isNotEmpty,
      );
      expect(result.activity.points, isEmpty);
    });

    test('FIT parser validates optional header CRC', () {
      final bytes = File('example/assets/sample.fit').readAsBytesSync();
      final corrupted = Uint8List.fromList(bytes);
      final headerSize = corrupted[0];
      corrupted[headerSize - 1] ^= 0xFF;

      final result = ActivityParser.parseBytes(
        corrupted,
        ActivityFileFormat.fit,
      );

      expect(
        result.diagnostics.where((d) => d.code == 'fit.header.crc_mismatch'),
        isNotEmpty,
      );
    });

    test('convertAndExport builds activities from raw streams', () async {
      final baseTime = DateTime.utc(2024, 5, 3, 7);
      final ts0 = baseTime.millisecondsSinceEpoch;
      final device = ActivityDeviceMetadata(
        manufacturer: 'Withings',
        model: 'ScanWatch',
      );
      final export = await ActivityFiles.convertAndExport(
        location: [
          (timestamp: ts0, latitude: 40.0, longitude: -105.0, elevation: 1600),
          (
            timestamp: ts0 + 1000,
            latitude: 40.0002,
            longitude: -105.0002,
            elevation: 1602,
          ),
        ],
        channels: {
          Channel.heartRate: [
            (timestamp: ts0, value: 140),
            (timestamp: ts0 + 1000, value: 144),
          ],
        },
        device: device,
        creator: 'withings-exporter',
        label: 'Morning Run',
        sportSource: {'category': 'running'},
        gpxMetadataName: 'Morning Run',
        gpxMetadataDescription: 'Withings export',
        includeCreatorInGpxMetadataDescription: false,
        gpxTrackType: 'Run',
        metadataExtensions: [ActivityFiles.gpxActivityLabelNode('Morning Run')],
        trackExtensions: [
          ActivityFiles.gpxDeviceSummaryNode(device, extras: {'battery': 95}),
        ],
        to: ActivityFileFormat.gpx,
        normalize: true,
        runValidation: true,
      );
      final gpx = export.asString();
      expect(gpx, contains('<name>Morning Run</name>'));
      expect(gpx, contains('<desc>Withings export</desc>'));
      expect(gpx, contains('<type>Run</type>'));
      expect(gpx, contains('ext:activity'));
      expect(export.activity.sport, equals(Sport.running));
      expect(export.activity.device?.manufacturer, equals('Withings'));
    });

    test('stream exports honor timestamp converters and laps', () async {
      final base = DateTime.utc(2024, 5, 4, 12);
      final ts0 = base.millisecondsSinceEpoch ~/ 1000; // seconds resolution
      DateTime decode(int seconds) =>
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
      final lap = Lap(
        startTime: decode(ts0),
        endTime: decode(ts0 + 120),
        distanceMeters: 600,
        name: 'Segment 1',
      );

      final export = await ActivityFiles.convertAndExport(
        location: [
          (timestamp: ts0, latitude: 40.0, longitude: -105.0, elevation: 1600),
          (
            timestamp: ts0 + 120,
            latitude: 40.0004,
            longitude: -105.0004,
            elevation: 1608,
          ),
        ],
        channels: {
          Channel.heartRate: [
            (timestamp: ts0, value: 135),
            (timestamp: ts0 + 120, value: 148),
          ],
        },
        laps: [lap],
        label: 'Lunch Ride',
        creator: 'stream-integration',
        sportSource: 'cycling',
        timestampConverter: decode,
        to: ActivityFileFormat.gpx,
        normalize: true,
        runValidation: true,
      );

      expect(export.activity.points.first.time, equals(lap.startTime));
      expect(export.activity.points.last.time, equals(lap.endTime));
      expect(export.activity.laps.length, equals(1));
      expect(export.activity.laps.single.name, equals('Segment 1'));
      expect(export.activity.sport, equals(Sport.cycling));
      expect(export.validation, isNotNull);
      final gpx = export.asString();
      expect(gpx, contains('<name>Lunch Ride</name>'));
      expect(gpx, contains('<trkpt'));
    });

    test('builder assembles activities and seeds existing data', () {
      final baseTime = DateTime.utc(2024, 5, 1, 8);
      final builder = ActivityFiles.builder()
        ..sport = Sport.running
        ..creator = 'builder-test'
        ..addPoint(
          latitude: 40.0,
          longitude: -105.0,
          elevation: 1600,
          time: baseTime,
        )
        ..addSample(channel: Channel.heartRate, time: baseTime, value: 140)
        ..addLap(
          startTime: baseTime,
          endTime: baseTime.add(const Duration(minutes: 1)),
          distanceMeters: 200,
          name: 'Warmup',
        );

      final activity = builder.build();
      expect(activity.points.length, equals(1));
      expect(activity.channel(Channel.heartRate).length, equals(1));
      expect(activity.laps.length, equals(1));
      expect(activity.sport, equals(Sport.running));
      expect(activity.creator, equals('builder-test'));

      final reseeded = ActivityFiles.builder(activity).build();
      expect(reseeded.points.length, equals(activity.points.length));
      expect(reseeded.channel(Channel.heartRate).length, equals(1));
    });

    test('builderFromStreams converts tuples into activity points', () {
      final baseTime = DateTime.utc(2024, 5, 2, 9);
      final ts0 = baseTime.millisecondsSinceEpoch;
      final builder = ActivityFiles.builderFromStreams(
        location: [
          (timestamp: ts0, latitude: 40.0, longitude: -105.0, elevation: 1600),
          (
            timestamp: ts0 + 1000,
            latitude: 40.0003,
            longitude: -105.0004,
            elevation: null,
          ),
        ],
        channels: {
          Channel.heartRate: [
            (timestamp: ts0, value: 140),
            (timestamp: ts0 + 1000, value: 142),
          ],
        },
        sport: Sport.running,
        creator: 'streams-builder',
      );
      final activity = builder.build(normalize: false);
      expect(activity.points.length, equals(2));
      expect(activity.channel(Channel.heartRate).length, equals(2));
      expect(activity.points.first.time, equals(baseTime));
      expect(activity.sport, equals(Sport.running));
      expect(activity.creator, equals('streams-builder'));
    });

    test('builder configure helpers update metadata and track settings', () {
      final baseTime = DateTime.utc(2024, 5, 2, 10);
      final builder = ActivityFiles.builder()
        ..configureGpxMetadata(
          name: 'Meta Title',
          description: 'Meta Description',
          includeCreatorDescription: false,
        )
        ..configureGpxTrack(
          name: 'Track Name',
          description: 'Track Description',
          type: 'Workout',
        )
        ..addGpxMetadataExtension(
          GpxExtensionNode(
            name: 'metaTag',
            namespacePrefix: 'custom',
            namespaceUri: 'https://example.com/meta',
            value: 'meta',
          ),
        )
        ..addGpxTrackExtension(
          GpxExtensionNode(
            name: 'trackTag',
            namespacePrefix: 'custom',
            namespaceUri: 'https://example.com/track',
            value: 'track',
          ),
        );
      builder.clearGpxExtensions();
      builder
        ..addGpxMetadataExtension(
          GpxExtensionNode(
            name: 'metaTag2',
            namespacePrefix: 'custom',
            namespaceUri: 'https://example.com/meta',
            value: 'meta2',
          ),
        )
        ..addGpxTrackExtension(
          GpxExtensionNode(
            name: 'trackTag2',
            namespacePrefix: 'custom',
            namespaceUri: 'https://example.com/track',
            value: 'track2',
          ),
        )
        ..addPoint(latitude: 40.0, longitude: -105.0, time: baseTime);
      final activity = builder.build(normalize: false);
      expect(activity.gpxMetadataName, equals('Meta Title'));
      expect(activity.gpxMetadataDescription, equals('Meta Description'));
      expect(activity.gpxIncludeCreatorMetadataDescription, isFalse);
      expect(activity.gpxTrackName, equals('Track Name'));
      expect(activity.gpxTrackDescription, equals('Track Description'));
      expect(activity.gpxTrackType, equals('Workout'));
      expect(activity.gpxMetadataExtensions.single.name, equals('metaTag2'));
      expect(activity.gpxTrackExtensions.single.name, equals('trackTag2'));
    });

    test('builder clear resets accumulated state', () {
      final baseTime = DateTime.utc(2024, 5, 2, 11);
      final builder = ActivityFiles.builder()
        ..sport = Sport.running
        ..creator = 'first'
        ..addPoint(latitude: 40.0, longitude: -105.0, time: baseTime)
        ..addSample(channel: Channel.heartRate, time: baseTime, value: 150)
        ..addLap(
          startTime: baseTime,
          endTime: baseTime.add(const Duration(minutes: 1)),
          distanceMeters: 200,
        )
        ..addGpxMetadataExtension(
          GpxExtensionNode(
            name: 'oldMeta',
            namespacePrefix: 'custom',
            namespaceUri: 'https://example.com/meta',
            value: 'old',
          ),
        );
      builder.clear();
      builder
        ..sport = Sport.cycling
        ..creator = 'second'
        ..addPoint(
          latitude: 41.0,
          longitude: -106.0,
          time: baseTime.add(const Duration(minutes: 5)),
        )
        ..addSample(
          channel: Channel.power,
          time: baseTime.add(const Duration(minutes: 5)),
          value: 200,
        )
        ..addLap(
          startTime: baseTime.add(const Duration(minutes: 5)),
          endTime: baseTime.add(const Duration(minutes: 6)),
          distanceMeters: 300,
        )
        ..addGpxMetadataExtension(
          GpxExtensionNode(
            name: 'newMeta',
            namespacePrefix: 'custom',
            namespaceUri: 'https://example.com/meta',
            value: 'new',
          ),
        );
      final activity = builder.build(normalize: false);
      expect(activity.sport, equals(Sport.cycling));
      expect(activity.creator, equals('second'));
      expect(activity.points.length, equals(1));
      expect(activity.channel(Channel.power).single.value, closeTo(200, 1e-9));
      expect(activity.laps.single.distanceMeters, closeTo(300, 1e-9));
      expect(activity.gpxMetadataExtensions.single.name, equals('newMeta'));
    });

    test('export surfaces validation diagnostics and summary helpers', () {
      final baseTime = DateTime.utc(2024, 6, 1, 7);
      final builder = ActivityFiles.builder()
        ..sport = Sport.cycling
        ..creator = 'export-test'
        ..addPoint(latitude: 40.0, longitude: -105.0, time: baseTime)
        ..addPoint(
          latitude: 40.0005,
          longitude: -105.0005,
          time: baseTime.add(const Duration(minutes: 10)),
        )
        ..addPoint(
          latitude: 40.0006,
          longitude: -105.0006,
          time: baseTime.add(const Duration(minutes: 11)),
        );
      final activity = builder.build(normalize: false);

      final export = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.gpx,
      );
      expect(export.validation, isNotNull);
      expect(export.warningCount, greaterThanOrEqualTo(1));
      expect(export.hasWarnings, isTrue);
      final summary = export.diagnosticsSummary();
      expect(summary.toLowerCase(), contains('gap'));
      expect(export.asBytes().length, greaterThan(0));
      final stats = export.processingStats;
      expect(stats.normalization, isNotNull);
      expect(stats.validationDuration, isNotNull);

      final withoutValidation = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.gpx,
        runValidation: false,
      );
      expect(withoutValidation.validation, isNull);
      expect(withoutValidation.diagnostics, isEmpty);
      expect(withoutValidation.processingStats.validationDuration, isNull);
    });

    test('validateRawActivity flags lap ordering and bounds issues', () {
      final base = DateTime.utc(2024, 6, 1, 8);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0005,
          longitude: -105.0005,
          time: base.add(const Duration(minutes: 5)),
        ),
      ];
      final laps = [
        Lap(
          startTime: base.subtract(const Duration(minutes: 1)),
          endTime: base.add(const Duration(minutes: 1)),
          name: 'Early',
        ),
        Lap(
          startTime: base.add(const Duration(seconds: 30)),
          endTime: base.add(const Duration(seconds: 30)),
          name: 'Overlap',
        ),
        Lap(
          startTime: base.add(const Duration(minutes: 4)),
          endTime: base.add(const Duration(minutes: 6)),
          name: 'Late',
        ),
      ];

      final result = validateRawActivity(
        RawActivity(points: points, laps: laps),
      );

      expect(result.errors.any((error) => error.contains('Lap 2')), isTrue);
      expect(
        result.errors.any((error) => error.contains('previous lap')),
        isTrue,
      );
      expect(
        result.warnings.any(
          (warning) => warning.contains('before the first point'),
        ),
        isTrue,
      );
      expect(
        result.warnings.any(
          (warning) => warning.contains('after the last point'),
        ),
        isTrue,
      );
    });

    test('validateRawActivity warns when channels extend beyond points', () {
      final base = DateTime.utc(2024, 6, 2, 7);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0005,
          longitude: -105.0005,
          time: base.add(const Duration(minutes: 5)),
        ),
      ];
      final power = [
        Sample(time: base.subtract(const Duration(seconds: 10)), value: 180),
        Sample(time: base.add(const Duration(minutes: 1)), value: 200),
        Sample(time: base.add(const Duration(minutes: 6)), value: 220),
      ];

      final result = validateRawActivity(
        RawActivity(points: points, channels: {Channel.power: power}),
      );

      expect(
        result.warnings.any(
          (warning) => warning.contains('before the first point'),
        ),
        isTrue,
      );
      expect(
        result.warnings.any(
          (warning) => warning.contains('after the last point'),
        ),
        isTrue,
      );
    });

    test('load surfaces structured diagnostics summary', () async {
      const problematicGpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="diagnostics-test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Diagnostics</name>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T00:00:00Z</time>
      </trkpt>
      <trkpt lat="40.1" lon="-105.1">
        <ele>oops</ele>
        <time>2024-01-01T00:05:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
''';
      final result = await ActivityFiles.load(
        problematicGpx,
        useIsolate: false,
      );
      expect(result.warningCount, equals(1));
      expect(result.hasWarnings, isTrue);
      final summary = result.diagnosticsSummary(
        includeSeverity: false,
        includeNode: true,
      );
      expect(summary, contains('Invalid elevation'));
    });

    test('channelSnapshot resolves nearest samples', () {
      final baseTime = DateTime.utc(2024, 7, 1, 6);
      final activity = ActivityFiles.builder()
        ..addPoint(latitude: 39.9, longitude: -105.0, time: baseTime)
        ..addPoint(
          latitude: 39.9005,
          longitude: -105.0005,
          time: baseTime.add(const Duration(seconds: 4)),
        )
        ..addSample(channel: Channel.heartRate, time: baseTime, value: 140)
        ..addSample(
          channel: Channel.heartRate,
          time: baseTime.add(const Duration(seconds: 3)),
          value: 148,
        )
        ..addSample(
          channel: Channel.power,
          time: baseTime.add(const Duration(seconds: 2)),
          value: 210,
        );
      final built = activity.build();
      final snapshot = ActivityFiles.channelSnapshot(
        baseTime.add(const Duration(seconds: 2)),
        built,
        maxDelta: const Duration(seconds: 5),
      );
      expect(snapshot.heartRate, closeTo(148, 0.001));
      expect(snapshot.power, closeTo(210, 0.001));
      expect(snapshot.isEmpty, isFalse);
    });

    test('builder supports device metadata and GPX extensions', () {
      final baseTime = DateTime.utc(2024, 8, 1, 9);
      final device = ActivityDeviceMetadata(
        manufacturer: 'Withings',
        model: 'ScanWatch',
        softwareVersion: '1.2.3',
      );
      final metadataExtension = GpxExtensionNode(
        name: 'metaTag',
        namespacePrefix: 'ex',
        namespaceUri: 'https://example.com/gpx',
        value: 'meta',
      );
      final trackExtension = GpxExtensionNode(
        name: 'trackTag',
        namespacePrefix: 'ex',
        namespaceUri: 'https://example.com/gpx',
        value: 'track',
      );
      final activity = ActivityFiles.builder()
        ..sport = Sport.running
        ..creator = 'extension-test'
        ..setDeviceMetadata(device)
        ..addGpxMetadataExtension(metadataExtension)
        ..addGpxTrackExtension(trackExtension)
        ..addPoint(latitude: 40.2, longitude: -104.9, time: baseTime)
        ..addPoint(
          latitude: 40.2004,
          longitude: -104.8996,
          time: baseTime.add(const Duration(minutes: 1)),
        );
      final built = activity.build();
      expect(built.device, isNotNull);
      expect(built.gpxMetadataExtensions.length, equals(1));
      expect(built.gpxTrackExtensions.length, equals(1));

      final gpx = ActivityEncoder.encode(built, ActivityFileFormat.gpx);
      expect(gpx, contains('<device>'));
      expect(gpx, contains('<manufacturer>Withings</manufacturer>'));
      expect(gpx, contains('<ex:metaTag>meta</ex:metaTag>'));
      expect(gpx, contains('<ex:trackTag>track</ex:trackTag>'));
      expect(gpx, contains('xmlns:ex="https://example.com/gpx"'));
      final tcx = ActivityEncoder.encode(built, ActivityFileFormat.tcx);
      expect(tcx, contains('<Manufacturer>Withings</Manufacturer>'));
      final parsedTcx = ActivityParser.parse(tcx, ActivityFileFormat.tcx);
      expect(parsedTcx.activity.device, isNotNull);
      expect(parsedTcx.activity.device!.manufacturer, equals('Withings'));
      expect(parsedTcx.activity.gpxMetadataExtensions.length, equals(1));
      final fitString = ActivityEncoder.encode(
        built,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      final fitParsed = ActivityParser.parseBytes(
        base64Decode(fitString),
        ActivityFileFormat.fit,
      );
      expect(fitParsed.activity.device, isNotNull);
      expect(fitParsed.activity.device!.manufacturer, isNotEmpty);
    });

    test('gpx device helpers emit metadata and track summaries', () {
      final baseTime = DateTime.utc(2024, 8, 1, 10);
      final device = ActivityDeviceMetadata(
        manufacturer: 'Withings',
        model: 'ScanWatch',
        serialNumber: 'XYZ123',
      );
      final builder = ActivityFiles.builder()
        ..sport = Sport.running
        ..creator = 'device-helper'
        ..addPoint(latitude: 40.2, longitude: -104.9, time: baseTime)
        ..addPoint(
          latitude: 40.2005,
          longitude: -104.8995,
          time: baseTime.add(const Duration(minutes: 1)),
        )
        ..addGpxMetadataExtension(
          ActivityFiles.gpxDeviceNode(device, extras: {'battery': 85}),
        )
        ..addGpxTrackExtension(
          ActivityFiles.gpxDeviceSummaryNode(
            device,
            extras: {'battery': 85, 'calibration': 'fresh'},
          ),
        );
      final gpx = ActivityEncoder.encode(
        builder.build(),
        ActivityFileFormat.gpx,
      );
      expect(gpx, contains('<ext:device>'));
      expect(gpx, contains('<ext:deviceSummary>'));
      expect(gpx, contains('<ext:manufacturer>Withings</ext:manufacturer>'));
      expect(gpx, contains('<ext:battery>85</ext:battery>'));
      expect(gpx, contains('<ext:calibration>fresh</ext:calibration>'));
    });

    test('convertAndExport can append validation results', () async {
      final result = await ActivityFiles.convertAndExport(
        source: _sampleGpx,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
        runValidation: true,
      );
      expect(result.asString(), isNotEmpty);
      expect(result.validation, isNotNull);
      expect(result.processingStats.validationDuration, isNotNull);
    });

    test('convertAndExport honours export isolation', () async {
      final result = await ActivityFiles.convertAndExport(
        source: _sampleGpx,
        to: ActivityFileFormat.fit,
        useIsolate: false,
        exportInIsolate: true,
      );
      expect(result.isBinary, isTrue);
      expect(result.asBytes().length, greaterThan(0));
      expect(result.processingStats.normalization, isNotNull);
    });

    test('exportAsync offloads when requested', () async {
      final baseTime = DateTime.utc(2024, 9, 1, 6);
      final activity = ActivityFiles.builder()
        ..addPoint(latitude: 40.0, longitude: -105.0, time: baseTime)
        ..addPoint(
          latitude: 40.0002,
          longitude: -105.0002,
          time: baseTime.add(const Duration(minutes: 1)),
        );
      final asyncResult = await ActivityFiles.exportAsync(
        activity: activity.build(normalize: false),
        to: ActivityFileFormat.gpx,
        runValidation: false,
        useIsolate: true,
      );
      expect(asyncResult.encoded, isNotEmpty);
      expect(asyncResult.processingStats.normalization, isNotNull);
    });

    test('convertAndExportStream handles streamed payloads', () async {
      final stream = Stream<List<int>>.fromIterable([utf8.encode(_sampleGpx)]);
      final streamed = await ActivityFiles.convertAndExportStream(
        source: stream,
        from: ActivityFileFormat.gpx,
        to: ActivityFileFormat.tcx,
        parseInIsolate: false,
        runValidation: true,
      );
      expect(streamed.targetFormat, equals(ActivityFileFormat.tcx));
      expect(streamed.validation, isNotNull);
    });

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
        source: _sampleGpx,
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

    test(
      'export copyWith refreshes binary cache when encoded changes',
      () async {
        final conversion = await ActivityFiles.convert(
          source: _sampleGpx,
          to: ActivityFileFormat.fit,
          useIsolate: false,
        );
        final mutated = Uint8List.fromList(conversion.asBytes());
        mutated[0] = (mutated[0] + 1) % 256;
        final mutatedEncoded = base64Encode(mutated);
        final updated = conversion.copyWith(encoded: mutatedEncoded);
        expect(updated.encoded, equals(mutatedEncoded));
        expect(updated.asBytes().first, equals(mutated.first));
      },
    );

    test('FIT encoder prefers explicit manufacturer/product ids', () async {
      final baseTime = DateTime.utc(2024, 11, 1, 6);
      final metadata = ActivityDeviceMetadata(
        manufacturer: 'Withings',
        fitManufacturerId: 201,
        fitProductId: 42,
        serialNumber: '98765',
      );
      final builder = ActivityFiles.builder()
        ..setDeviceMetadata(metadata)
        ..addPoint(latitude: 40.0, longitude: -105.0, time: baseTime)
        ..addPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: baseTime.add(const Duration(seconds: 2)),
        );
      final export = ActivityFiles.export(
        activity: builder.build(),
        to: ActivityFileFormat.fit,
        runValidation: false,
      );
      final parsed = ActivityParser.parseBytes(
        export.asBytes(),
        ActivityFileFormat.fit,
      );
      final device = parsed.activity.device;
      expect(device, isNotNull);
      expect(device!.fitManufacturerId, equals(201));
      expect(device.fitProductId, equals(42));
      expect(device.serialNumber, equals('98765'));
    });

    test('DiagnosticsFormatter summarizes diagnostics consistently', () {
      final diagnostics = [
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'demo.warning',
          message: 'Shallow warning',
        ),
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'demo.error',
          message: 'Serious issue',
        ),
      ];
      final formatter = DiagnosticsFormatter(diagnostics);
      expect(formatter.warningCount, equals(1));
      expect(formatter.errorCount, equals(1));
      expect(formatter.hasWarnings, isTrue);
      expect(formatter.hasErrors, isTrue);
      final summary = formatter.summary(includeSeverity: false);
      expect(summary, contains('demo.error'));
    });

    test('trimInvalid removes out-of-range points and channel samples', () {
      final base = DateTime.utc(2024, 1, 5, 6);
      final points = [
        GeoPoint(latitude: 95, longitude: 0, time: base),
        GeoPoint(
          latitude: 40.0,
          longitude: -105.0,
          time: base.add(const Duration(minutes: 1)),
        ),
        GeoPoint(
          latitude: 40.0,
          longitude: -190,
          time: base.add(const Duration(minutes: 2)),
        ),
      ];
      final lap = Lap(
        startTime: base.subtract(const Duration(minutes: 1)),
        endTime: base.add(const Duration(minutes: 3)),
        distanceMeters: 1500,
      );
      final activity = RawActivity(
        points: points,
        channels: {
          Channel.heartRate: [
            Sample(time: base, value: 130),
            Sample(time: base.add(const Duration(minutes: 1)), value: 140),
            Sample(time: base.add(const Duration(minutes: 2)), value: 150),
          ],
        },
        laps: [lap],
      );

      final trimmed = ActivityFiles.trimInvalid(activity);
      expect(trimmed.points.length, equals(1));
      expect(trimmed.points.single.latitude, closeTo(40, 1e-9));
      final hr = trimmed.channel(Channel.heartRate);
      expect(hr.length, equals(1));
      expect(hr.single.value, closeTo(140, 1e-9));
      expect(trimmed.laps.length, equals(1));
      expect(trimmed.laps.single.startTime, equals(points[1].time));
      expect(trimmed.laps.single.endTime, equals(points[1].time));
    });

    test('trimInvalid clamps channels and laps to point window', () {
      final base = DateTime.utc(2024, 1, 5, 7);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 1)),
        ),
      ];
      final hrSamples = [
        Sample(time: base, value: 130),
        Sample(time: base.add(const Duration(minutes: 1)), value: 140),
        Sample(time: base.add(const Duration(minutes: 2)), value: 150),
      ];
      final lap = Lap(
        startTime: base,
        endTime: base.add(const Duration(minutes: 2)),
        distanceMeters: 500,
      );
      final trimmed = ActivityFiles.trimInvalid(
        RawActivity(
          points: points,
          channels: {Channel.heartRate: hrSamples},
          laps: [lap],
        ),
      );
      final hr = trimmed.channel(Channel.heartRate);
      expect(hr.length, equals(2));
      expect(hr.last.time, equals(points.last.time));
      expect(trimmed.laps.single.endTime, equals(points.last.time));
    });

    test('crop restricts activity range and trims laps', () {
      final base = DateTime.utc(2024, 1, 6, 8);
      final points = List<GeoPoint>.generate(
        4,
        (index) => GeoPoint(
          latitude: 40.0 + index * 0.0001,
          longitude: -105.0 - index * 0.0001,
          time: base.add(Duration(minutes: index)),
        ),
      );
      final hrSamples = List<Sample>.generate(
        4,
        (index) =>
            Sample(time: points[index].time, value: 130 + index.toDouble()),
      );
      final lap = Lap(
        startTime: base,
        endTime: base.add(const Duration(minutes: 3)),
        distanceMeters: 2000,
      );
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hrSamples},
        laps: [lap],
      );

      final cropped = ActivityFiles.crop(
        activity,
        start: base.add(const Duration(minutes: 1)),
        end: base.add(const Duration(minutes: 2)),
      );
      expect(cropped.points.length, equals(2));
      expect(cropped.points.first.time, equals(points[1].time));
      expect(cropped.points.last.time, equals(points[2].time));
      final hr = cropped.channel(Channel.heartRate);
      expect(hr.length, equals(2));
      expect(hr.first.time, equals(points[1].time));
      expect(hr.last.time, equals(points[2].time));
      expect(cropped.laps.single.startTime, equals(points[1].time));
      expect(cropped.laps.single.endTime, equals(points[2].time));
    });

    test('smoothHeartRate applies moving average to heart-rate channel', () {
      final base = DateTime.utc(2024, 1, 7, 9);
      final points = [
        GeoPoint(latitude: 40, longitude: -105, time: base),
        GeoPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 1)),
        ),
        GeoPoint(
          latitude: 40.0002,
          longitude: -105.0002,
          time: base.add(const Duration(minutes: 2)),
        ),
      ];
      final hrSamples = [
        Sample(time: points[0].time, value: 100),
        Sample(time: points[1].time, value: 150),
        Sample(time: points[2].time, value: 190),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hrSamples},
      );

      final smoothed = ActivityFiles.smoothHeartRate(activity, window: 3);
      final hr = smoothed.channel(Channel.heartRate);
      expect(hr.length, equals(3));
      expect(hr[0].time, equals(points[0].time));
      expect(hr[0].value, closeTo(125, 1e-6));
      expect(hr[1].value, closeTo((100 + 150 + 190) / 3, 1e-6));
      expect(hr[2].value, closeTo(170, 1e-6));
    });

    test('normalizeActivity respects disabled cleanup steps', () {
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

      final normalized = ActivityFiles.normalizeActivity(activity);
      expect(normalized.points.length, equals(1));
      expect(normalized.points.single.latitude, closeTo(40, 1e-9));
      final hr = normalized.channel(Channel.heartRate);
      expect(hr.length, equals(1));
      expect(hr.single.value, closeTo(135, 1e-9));
    });

    test('channelSnapshot resolves nearest samples with derived pace', () {
      final base = DateTime.utc(2024, 1, 8, 10);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40, longitude: -105, time: base),
          GeoPoint(
            latitude: 40.0002,
            longitude: -105.0002,
            time: base.add(const Duration(seconds: 10)),
          ),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: base, value: 150),
            Sample(time: base.add(const Duration(seconds: 10)), value: 140),
          ],
          Channel.speed: [
            Sample(time: base.add(const Duration(seconds: 2)), value: 4),
          ],
        },
      );

      final snapshot = ActivityFiles.channelSnapshot(
        base.add(const Duration(seconds: 2)),
        activity,
        maxDelta: const Duration(seconds: 5),
      );
      expect(snapshot.heartRate, closeTo(150, 1e-9));
      expect(snapshot.heartRateDelta, equals(const Duration(seconds: 2)));
      expect(snapshot.speed, closeTo(4, 1e-9));
      expect(snapshot.speedDelta, equals(Duration.zero));
      expect(snapshot.pace, closeTo(250, 1e-9));
      expect(snapshot.isEmpty, isFalse);
    });

    test('channelSnapshot omits samples beyond tolerance', () {
      final base = DateTime.utc(2024, 1, 8, 11);
      final activity = RawActivity(
        points: [GeoPoint(latitude: 40, longitude: -105, time: base)],
        channels: {
          Channel.heartRate: [Sample(time: base, value: 155)],
        },
      );

      final snapshot = ActivityFiles.channelSnapshot(
        base.add(const Duration(seconds: 5)),
        activity,
        maxDelta: const Duration(seconds: 1),
      );
      expect(snapshot.isEmpty, isTrue);
      expect(snapshot.heartRate, isNull);
      expect(snapshot.heartRateDelta, isNull);
      expect(snapshot.pace, isNull);
    });

    test('export reports normalization stats when cleanup applies', () {
      final base = DateTime.utc(2024, 1, 9, 6);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0002,
          longitude: -105.0002,
          time: base.add(const Duration(minutes: 1)),
        ),
      ];
      final hrSamples = [
        Sample(time: base, value: 130),
        Sample(time: base, value: 135),
        Sample(time: base.add(const Duration(minutes: 1)), value: 140),
      ];
      final export = ActivityFiles.export(
        activity: RawActivity(
          points: points,
          channels: {Channel.heartRate: hrSamples},
        ),
        to: ActivityFileFormat.gpx,
      );
      final stats = export.processingStats.normalization;
      expect(stats, isNotNull);
      expect(stats!.applied, isTrue);
      expect(stats.pointsBefore, equals(3));
      expect(stats.pointsAfter, equals(2));
      expect(stats.totalSamplesBefore, equals(3));
      expect(stats.totalSamplesAfter, equals(2));
      expect(stats.hasChanges, isTrue);
      expect(export.processingStats.hasNormalization, isTrue);
      expect(export.processingStats.hasValidationTiming, isTrue);
    });
  });

  group('FIT encoder regressions', () {
    test('encodes null elevations using FIT sentinel', () {
      final start = DateTime.utc(2024, 1, 1, 6);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: start),
          GeoPoint(
            latitude: 40.0005,
            longitude: -105.0005,
            elevation: 12,
            time: start.add(const Duration(seconds: 10)),
          ),
        ],
      );
      final fitPayload = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
      );
      final parsed = ActivityParser.parseBytes(
        base64Decode(fitPayload),
        ActivityFileFormat.fit,
      );
      expect(parsed.activity.points.first.elevation, isNull);
      expect(parsed.activity.points[1].elevation, closeTo(12, 1e-6));
    });

    test('distance samples respect channel tolerances', () {
      final start = DateTime.utc(2024, 1, 2, 7);
      final points = [
        GeoPoint(latitude: 39.0, longitude: -104.0, time: start),
        GeoPoint(
          latitude: 39.0005,
          longitude: -104.0005,
          time: start.add(const Duration(minutes: 1)),
        ),
      ];
      final distanceSamples = [Sample(time: start, value: 1234.5)];
      final activity = RawActivity(
        points: points,
        channels: {Channel.distance: distanceSamples},
      );
      final fitPayload = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
      );
      final parsed = ActivityParser.parseBytes(
        base64Decode(fitPayload),
        ActivityFileFormat.fit,
      );
      final parsedDistances = parsed.activity.channel(Channel.distance);
      expect(parsedDistances.length, equals(1));
      expect(parsedDistances.first.value, closeTo(1234.5, 1e-6));
    });

    test('parser skips developer data payloads without misalignment', () {
      final bytes = _buildFitFileWithDeveloperData();
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      expect(result.activity.points.length, equals(1));
      expect(result.diagnostics, isEmpty);
    });

    test('FIT parser flags CRC mismatches as errors', () async {
      final bytes = await File('example/assets/sample.fit').readAsBytes();
      final corrupted = Uint8List.fromList(bytes);
      corrupted[corrupted.length - 1] ^= 0xFF;
      final result = ActivityParser.parseBytes(
        corrupted,
        ActivityFileFormat.fit,
      );
      final hasCrcError = result.diagnostics.any(
        (d) =>
            d.severity == ParseSeverity.error &&
            (d.code.contains('crc') || d.code.contains('trailer')),
      );
      expect(hasCrcError, isTrue);
      expect(result.activity.points, isEmpty);
    });
  });

  group('Export serialization', () {
    test('roundtrips activities with metadata, channels, and extensions', () {
      final base = DateTime.utc(2024, 8, 1, 6);
      final device = ActivityDeviceMetadata(
        manufacturer: 'Withings',
        model: 'ScanWatch',
        product: 'watch',
        serialNumber: 'abc123',
        softwareVersion: '1.2.3',
        fitManufacturerId: 201,
        fitProductId: 42,
      );
      final metadataExtensions = <GpxExtensionNode>[
        GpxExtensionNode(
          name: 'meta',
          namespacePrefix: 'ext',
          namespaceUri: 'https://example.com/ext',
          value: 'payload',
          attributes: const {'id': 'meta-1'},
          children: [
            GpxExtensionNode(
              name: 'child',
              namespacePrefix: 'ext',
              namespaceUri: 'https://example.com/ext',
              value: 'child-value',
            ),
          ],
        ),
      ];
      final trackExtensions = <GpxExtensionNode>[
        GpxExtensionNode(
          name: 'track',
          namespaceUri: 'https://example.com/track',
          value: 'track-value',
        ),
      ];
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            elevation: 1600,
            time: base,
          ),
          GeoPoint(
            latitude: 40.0002,
            longitude: -105.0003,
            elevation: 1605,
            time: base.add(const Duration(seconds: 30)),
          ),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: base, value: 140),
            Sample(time: base.add(const Duration(seconds: 30)), value: 145),
          ],
          Channel.custom('respiration'): [
            Sample(time: base.add(const Duration(seconds: 15)), value: 12),
          ],
        },
        laps: [
          Lap(
            startTime: base,
            endTime: base.add(const Duration(minutes: 1)),
            distanceMeters: 210,
            name: 'Lap 1',
          ),
        ],
        sport: Sport.running,
        creator: 'serializer-test',
        device: device,
        gpxMetadataName: 'Morning Run',
        gpxMetadataDescription: 'Neighborhood loop',
        gpxIncludeCreatorMetadataDescription: false,
        gpxTrackName: 'Morning Run',
        gpxTrackDescription: 'Neighborhood loop',
        gpxTrackType: 'Run',
        gpxMetadataExtensions: metadataExtensions,
        gpxTrackExtensions: trackExtensions,
      );

      final serialized = ExportSerialization.activityToJson(activity);
      final roundTrip = ExportSerialization.activityFromJson(
        serialized.cast<String, Object?>(),
      );

      expect(roundTrip.points.length, equals(activity.points.length));
      expect(roundTrip.points.first.latitude, closeTo(40.0, 1e-9));
      expect(
        roundTrip.points.last.time.toIso8601String(),
        equals(activity.points.last.time.toIso8601String()),
      );
      expect(roundTrip.channels.length, equals(activity.channels.length));
      expect(
        roundTrip.channels[Channel.heartRate]!.last.value,
        closeTo(145, 1e-9),
      );
      final respiration = roundTrip.channels[Channel.custom('respiration')];
      expect(respiration, isNotNull);
      expect(respiration!.single.value, closeTo(12, 1e-9));
      expect(roundTrip.laps.single.distanceMeters, closeTo(210, 1e-9));
      expect(roundTrip.device?.serialNumber, equals('abc123'));
      expect(roundTrip.creator, equals('serializer-test'));
      expect(roundTrip.gpxMetadataDescription, equals('Neighborhood loop'));
      expect(roundTrip.gpxIncludeCreatorMetadataDescription, isFalse);
      expect(roundTrip.gpxTrackExtensions.single.name, equals('track'));
      expect(
        roundTrip.gpxMetadataExtensions.single.children.single.name,
        equals('child'),
      );
    });

    test('serializes encoder options with per-channel overrides', () {
      final options = EncoderOptions(
        defaultMaxDelta: const Duration(seconds: 5),
        precisionLatLon: 7,
        precisionEle: 2,
        maxDeltaPerChannel: {
          Channel.heartRate: const Duration(seconds: 2),
          Channel.custom('respiration'): const Duration(milliseconds: 500),
        },
      );

      final json = ExportSerialization.encoderOptionsToJson(options);
      final restored = ExportSerialization.encoderOptionsFromJson(
        json.cast<String, Object?>(),
      );

      expect(restored.defaultMaxDelta, equals(const Duration(seconds: 5)));
      expect(restored.precisionLatLon, equals(7));
      expect(restored.precisionEle, equals(2));
      expect(
        restored.maxDeltaPerChannel[Channel.heartRate],
        equals(const Duration(seconds: 2)),
      );
      expect(
        restored.maxDeltaPerChannel[Channel.custom('respiration')],
        equals(const Duration(milliseconds: 500)),
      );
      expect(restored.gpxVersion, equals(GpxVersion.v1_1));
      expect(restored.tcxVersion, equals(TcxVersion.v2));
    });

    test('serializes diagnostics and validation payloads', () {
      final diagnostic = ParseDiagnostic(
        severity: ParseSeverity.warning,
        code: 'demo.code',
        message: 'Problem',
        node: const ParseNodeReference(
          path: '/gpx/trk[0]/trkseg[0]/trkpt[1]',
          index: 1,
          description: 'trkpt',
        ),
      );
      final diagnosticJson = ExportSerialization.diagnosticToJson(diagnostic);
      final decodedDiagnostic = ExportSerialization.diagnosticFromJson(
        diagnosticJson.cast<String, Object?>(),
      );
      expect(decodedDiagnostic.code, equals('demo.code'));
      expect(decodedDiagnostic.message, equals('Problem'));
      expect(decodedDiagnostic.node, isNotNull);
      expect(
        decodedDiagnostic.node!.path,
        equals('/gpx/trk[0]/trkseg[0]/trkpt[1]'),
      );

      final validation = ValidationResult(
        errors: const ['gap error'],
        warnings: const ['speed warning'],
      );
      final validationJson = ExportSerialization.validationToJson(validation);
      final decodedValidation = ExportSerialization.validationFromJson(
        validationJson.cast<String, Object?>(),
      );
      expect(decodedValidation.errors, contains('gap error'));
      expect(decodedValidation.warnings, contains('speed warning'));
    });

    test('serializes normalization and processing stats', () {
      const normalization = NormalizationStats(
        applied: true,
        pointsBefore: 10,
        pointsAfter: 8,
        totalSamplesBefore: 20,
        totalSamplesAfter: 15,
        duration: Duration(milliseconds: 12),
      );
      final normalizationJson = ExportSerialization.normalizationStatsToJson(
        normalization,
      );
      final restoredNormalization =
          ExportSerialization.normalizationStatsFromJson(
            normalizationJson.cast<String, Object?>(),
          );
      expect(restoredNormalization.applied, isTrue);
      expect(restoredNormalization.pointsDelta, equals(-2));
      expect(restoredNormalization.totalSamplesDelta, equals(-5));

      final processing = ActivityProcessingStats(
        normalization: normalization,
        validationDuration: const Duration(milliseconds: 25),
      );
      final processingJson = ExportSerialization.processingStatsToJson(
        processing,
      );
      final restoredProcessing = ExportSerialization.processingStatsFromJson(
        processingJson.cast<String, Object?>(),
      );
      expect(restoredProcessing.hasNormalization, isTrue);
      expect(restoredProcessing.normalization!.pointsAfter, equals(8));
      expect(restoredProcessing.hasValidationTiming, isTrue);
      expect(
        restoredProcessing.validationDuration,
        equals(const Duration(milliseconds: 25)),
      );

      final emptyProcessing = ExportSerialization.processingStatsFromJson(null);
      expect(emptyProcessing.hasNormalization, isFalse);
      expect(emptyProcessing.hasValidationTiming, isFalse);
    });

    test('handles nullable device metadata serialization helpers', () {
      expect(ExportSerialization.deviceToJson(null), isNull);
      expect(ExportSerialization.deviceFromJson(null), isNull);
    });
  });

  group('Platform adapters', () {
    test('file system stub returns safe fallbacks for web targets', () async {
      expect(fs_stub.isPlatformFile(Object()), isFalse);
      expect(fs_stub.platformFilePath(Object()), isNull);
      expect(await fs_stub.readPlatformFile(Object()), isNull);
      expect(fs_stub.platformPathExists('missing'), isFalse);
      await expectLater(
        fs_stub.readPlatformPath('missing'),
        throwsUnsupportedError,
      );
    });

    test('file system IO handles platform files on non-web targets', () async {
      final tempDir = await Directory.systemTemp.createTemp('af_fs_test');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final file = File('${tempDir.path}/sample.txt');
      await file.writeAsString('hello world');

      expect(fs_io.isPlatformFile(file), isTrue);
      expect(fs_io.platformFilePath(file), equals(file.path));

      final fromFile = await fs_io.readPlatformFile(file);
      expect(fromFile, isNotNull);
      expect(fromFile!.path, equals(file.path));
      expect(fromFile.bytes.length, greaterThan(0));

      expect(fs_io.platformPathExists(file.path), isTrue);
      final pathBytes = await fs_io.readPlatformPath(file.path);
      expect(pathBytes.length, greaterThan(0));

      expect(file_system.isPlatformFile(file), isTrue);
      expect(file_system.platformFilePath(file), equals(file.path));
    });

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

  group('Fixture assets', () {
    const assets = {
      'sample.gpx': ActivityFileFormat.gpx,
      'sample.tcx': ActivityFileFormat.tcx,
      'sample.fit': ActivityFileFormat.fit,
    };

    Future<String> assetPath(String name) async {
      final directory = Directory('example/assets');
      if (!await directory.exists()) {
        throw StateError('example/assets directory not found');
      }
      return '${directory.path}${Platform.pathSeparator}$name';
    }

    test('detectFormat identifies fixture formats', () async {
      for (final entry in assets.entries) {
        final path = await assetPath(entry.key);
        final detected = ActivityFiles.detectFormat(path, allowFilePaths: true);
        expect(detected, equals(entry.value));

        final loaded = await ActivityFiles.load(
          path,
          useIsolate: false,
          allowFilePaths: true,
        );
        expect(loaded.format, equals(entry.value));
        if (entry.value != ActivityFileFormat.fit) {
          expect(
            loaded.activity.points,
            isNotEmpty,
            reason: 'Expected points for ${entry.key}',
          );
        }
        final errors = loaded.diagnostics
            .where((d) => d.severity == ParseSeverity.error)
            .toList();
        if (entry.value == ActivityFileFormat.fit) {
          expect(
            errors,
            isNotEmpty,
            reason: 'Expected FIT integrity errors for ${entry.key}',
          );
        } else {
          expect(errors, isEmpty, reason: 'Unexpected errors for ${entry.key}');
        }
      }
    });

    test('load handles FIT bytes and base64 payload', () async {
      final fitPath = await assetPath('sample.fit');
      final fitBytes = await File(fitPath).readAsBytes();

      final detectedBytes = ActivityFiles.detectFormat(fitBytes);
      expect(detectedBytes, equals(ActivityFileFormat.fit));

      final bytesResult = await ActivityFiles.load(fitBytes, useIsolate: false);
      expect(bytesResult.format, equals(ActivityFileFormat.fit));

      final base64Payload = base64Encode(fitBytes);
      final base64Result = await ActivityFiles.load(
        base64Payload,
        useIsolate: false,
      );
      expect(base64Result.format, equals(ActivityFileFormat.fit));
      expect(
        base64Result.activity.points.length,
        equals(bytesResult.activity.points.length),
      );
    });

    test('load enforces strict FIT integrity when requested', () async {
      final fitPath = await assetPath('sample.fit');
      final fitBytes = await File(fitPath).readAsBytes();
      await expectLater(
        () => ActivityFiles.load(
          fitBytes,
          useIsolate: false,
          strictFitIntegrity: true,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('convert can round-trip GPX fixture to FIT', () async {
      final gpxPath = await assetPath('sample.gpx');
      final loaded = await ActivityFiles.load(
        gpxPath,
        useIsolate: false,
        allowFilePaths: true,
      );

      final conversion = await ActivityFiles.convert(
        source: gpxPath,
        to: ActivityFileFormat.fit,
        useIsolate: false,
        allowFilePaths: true,
      );
      expect(conversion.isBinary, isTrue);

      final roundTrip = await ActivityFiles.load(
        conversion.asBytes(),
        useIsolate: false,
      );
      expect(roundTrip.format, equals(ActivityFileFormat.fit));
      expect(
        roundTrip.activity.points.length,
        equals(loaded.activity.points.length),
      );
    });
  });

  group('Format interop', () {
    test('GPX → Raw → TCX preserves HR and cadence', () {
      final gpxResult = ActivityParser.parse(
        _sampleGpx,
        ActivityFileFormat.gpx,
      );
      expect(gpxResult.warningDiagnostics, isEmpty);
      final activity = gpxResult.activity;

      final tcxString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.tcx,
        options: encoderOptions,
      );

      final tcxResult = ActivityParser.parse(tcxString, ActivityFileFormat.tcx);
      expect(tcxResult.warningDiagnostics, isEmpty);

      final tolerance = encoderOptions.defaultMaxDelta;
      final targetHr = activity.channel(Channel.heartRate);
      final roundHr = tcxResult.activity.channel(Channel.heartRate);
      for (final sample in targetHr) {
        expect(_hasMatchingSample(roundHr, sample, tolerance), isTrue);
      }

      final targetCad = activity.channel(Channel.cadence);
      final roundCad = tcxResult.activity.channel(Channel.cadence);
      for (final sample in targetCad) {
        expect(_hasMatchingSample(roundCad, sample, tolerance), isTrue);
      }
    });

    test('TCX → Raw → GPX preserves HR and cadence extensions', () {
      final tcxResult = ActivityParser.parse(
        _sampleTcx,
        ActivityFileFormat.tcx,
      );
      expect(tcxResult.warningDiagnostics, isEmpty);

      final gpx = ActivityEncoder.encode(
        tcxResult.activity,
        ActivityFileFormat.gpx,
        options: encoderOptions,
      );

      final gpxResult = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
      expect(gpxResult.warningDiagnostics, isEmpty);

      final originalHr = tcxResult.activity.channel(Channel.heartRate);
      final roundHr = gpxResult.activity.channel(Channel.heartRate);
      final originalCad = tcxResult.activity.channel(Channel.cadence);
      final roundCad = gpxResult.activity.channel(Channel.cadence);

      expect(
        roundHr.map((s) => s.value.round()),
        orderedEquals(originalHr.map((s) => s.value.round())),
      );
      expect(
        roundCad.map((s) => s.value.round()),
        orderedEquals(originalCad.map((s) => s.value.round())),
      );
    });

    test('FIT encode → parse round trip', () {
      final activity = _buildSampleActivity();

      final fitString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      expect(fitString, isNotEmpty);

      final parsed = ActivityParser.parse(fitString, ActivityFileFormat.fit);
      expect(parsed.warningDiagnostics, isEmpty);
      expect(parsed.activity.points.length, activity.points.length);
      expect(
        parsed.activity.channel(Channel.heartRate).map((s) => s.value.round()),
        orderedEquals(
          activity.channel(Channel.heartRate).map((s) => s.value.round()),
        ),
      );
      expect(
        parsed.activity.channel(Channel.distance).last.value,
        closeTo(activity.channel(Channel.distance).last.value, 0.05),
      );
      final parsedSpeeds = parsed.activity
          .channel(Channel.speed)
          .map((s) => s.value)
          .toList();
      final originalSpeeds = activity
          .channel(Channel.speed)
          .map((s) => s.value)
          .toList();
      expect(parsedSpeeds.length, originalSpeeds.length);
      for (var i = 0; i < originalSpeeds.length; i++) {
        expect(parsedSpeeds[i], closeTo(originalSpeeds[i], 0.5));
      }
      expect(parsed.activity.sport, equals(Sport.cycling));
    });

    test('FIT encoder supports sensor-only activities', () {
      final start = DateTime.utc(2024, 2, 1, 6);
      final hrSamples = [
        Sample(time: start, value: 95),
        Sample(time: start.add(const Duration(seconds: 30)), value: 100),
        Sample(time: start.add(const Duration(minutes: 1)), value: 105),
      ];
      final activity = RawActivity(
        channels: {Channel.heartRate: hrSamples},
        sport: Sport.running,
      );

      final fitString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );

      final parsed = ActivityParser.parse(fitString, ActivityFileFormat.fit);

      expect(parsed.activity.points, isEmpty);
      final parsedHr = parsed.activity.channel(Channel.heartRate);
      expect(parsedHr.length, equals(hrSamples.length));
      expect(
        parsedHr.map((sample) => sample.value.round()),
        orderedEquals(hrSamples.map((sample) => sample.value.round())),
      );
    });

    test('FIT binary payload obeys header and CRC', () {
      final activity = _buildSampleActivity();
      final fitString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );

      final bytes = base64Decode(fitString);
      expect(bytes.length, greaterThan(20));
      final headerSize = bytes[0];
      expect(headerSize, equals(14));
      final byteData = ByteData.sublistView(Uint8List.fromList(bytes));
      final dataSize = byteData.getUint32(4, Endian.little);
      expect(headerSize + dataSize + 2, equals(bytes.length));

      final payload = bytes.sublist(headerSize);
      final storedCrc =
          payload[payload.length - 2] | (payload[payload.length - 1] << 8);
      final computedCrc = _fitCrc(payload.sublist(0, payload.length - 2));
      expect(storedCrc, equals(computedCrc));
    });

    test('FIT parser reports trailer CRC mismatches', () {
      final activity = _buildSampleActivity();
      final fitBytes = base64Decode(
        ActivityEncoder.encode(activity, ActivityFileFormat.fit),
      );
      final tampered = Uint8List.fromList(fitBytes);
      tampered[tampered.length - 1] ^= 0xFF;

      final result = ActivityParser.parseBytes(
        tampered,
        ActivityFileFormat.fit,
      );

      expect(
        result.diagnostics.where(
          (diagnostic) => diagnostic.code == 'fit.trailer.crc_mismatch',
        ),
        isNotEmpty,
      );
    });

    test('FIT parser warns when trailer is truncated', () {
      final activity = _buildSampleActivity();
      final fitBytes = base64Decode(
        ActivityEncoder.encode(activity, ActivityFileFormat.fit),
      );
      final truncated = Uint8List.fromList(
        fitBytes.sublist(0, fitBytes.length - 2),
      );

      final result = ActivityParser.parseBytes(
        truncated,
        ActivityFileFormat.fit,
      );

      expect(
        result.diagnostics.where(
          (diagnostic) => diagnostic.code == 'fit.trailer.truncated',
        ),
        isNotEmpty,
      );
    });

    test('FIT raw round-trip preserves serialization', () {
      final activity = _buildSampleActivity();
      final firstFit = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      final parsed = ActivityParser.parse(firstFit, ActivityFileFormat.fit);
      expect(parsed.warningDiagnostics, isEmpty);

      final secondFit = ActivityEncoder.encode(
        parsed.activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );

      final firstBytes = base64Decode(firstFit);
      final secondBytes = base64Decode(secondFit);
      expect(secondBytes.length, equals(firstBytes.length));

      final secondParsed = ActivityParser.parse(
        secondFit,
        ActivityFileFormat.fit,
      ).activity;
      expect(secondParsed.points.length, activity.points.length);
      expect(
        secondParsed.channel(Channel.power).map((s) => s.value.round()),
        orderedEquals(
          activity.channel(Channel.power).map((s) => s.value.round()),
        ),
      );
      expect(
        secondParsed.channel(Channel.temperature).map((s) => s.value.round()),
        orderedEquals(
          activity.channel(Channel.temperature).map((s) => s.value.round()),
        ),
      );
    });

    test('GPX round-trip retains point count and timestamps', () {
      final parseResult = ActivityParser.parse(
        _sampleGpx,
        ActivityFileFormat.gpx,
      );
      final encoded = ActivityEncoder.encode(
        parseResult.activity,
        ActivityFileFormat.gpx,
        options: encoderOptions,
      );
      final roundTrip = ActivityParser.parse(encoded, ActivityFileFormat.gpx);

      final originalTimes = parseResult.activity.points
          .map((p) => p.time)
          .toList();
      final newTimes = roundTrip.activity.points.map((p) => p.time).toList();
      expect(newTimes.length, originalTimes.length);
      expect(newTimes, orderedEquals(originalTimes));
    });

    test('FIT compressed headers parsed from raw bytes', () {
      final bytes = _buildCompressedFitSample();
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      expect(result.warningDiagnostics, isEmpty);

      final points = result.activity.points;
      expect(points.length, equals(2));

      final base = DateTime.utc(1989, 12, 31);
      expect(
        points.first.time,
        equals(base.add(const Duration(seconds: 1000))),
      );
      expect(points.last.time, equals(base.add(const Duration(seconds: 1001))));

      expect(points.first.latitude, closeTo(0.0, 1e-6));
      expect(points.last.latitude, closeTo(0.0005, 1e-6));
    });
  });

  group('Async parsing', () {
    test('parseAsync mirrors synchronous GPX parser', () async {
      final sync = ActivityParser.parse(_sampleGpx, ActivityFileFormat.gpx);
      final asyncResult = await ActivityParser.parseAsync(
        _sampleGpx,
        ActivityFileFormat.gpx,
        useIsolate: false,
      );
      expect(asyncResult.activity.points.length, sync.activity.points.length);
      expect(asyncResult.diagnostics, isEmpty);
    });

    test('parseBytesAsync offloads FIT parsing', () async {
      final activity = _buildSampleActivity();
      final fitPayload = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      final bytes = base64Decode(fitPayload);
      final result = await ActivityParser.parseBytesAsync(
        bytes,
        ActivityFileFormat.fit,
      );
      expect(result.activity.points.length, activity.points.length);
      expect(result.diagnostics, isEmpty);
    });

    test('parseStream parses chunked FIT binary', () async {
      final activity = _buildSampleActivity();
      final fitPayload = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      final bytes = base64Decode(fitPayload);
      final stream = Stream<List<int>>.fromIterable([
        bytes.sublist(0, bytes.length ~/ 2),
        bytes.sublist(bytes.length ~/ 2),
      ]);
      final result = await ActivityParser.parseStream(
        stream,
        ActivityFileFormat.fit,
        useIsolate: false,
      );
      expect(result.activity.points.length, activity.points.length);
      expect(result.diagnostics, isEmpty);
    });
  });

  group('Transforms', () {
    test('crop, downsample, and resample adjust counts', () {
      final start = DateTime.utc(2024, 1, 1, 12);
      final points = List.generate(
        6,
        (index) => GeoPoint(
          latitude: 40.0 + index * 0.001,
          longitude: -105.0 + index * 0.001,
          elevation: 1600 + index.toDouble(),
          time: start.add(Duration(seconds: index * 10)),
        ),
      );
      final hr = List.generate(
        6,
        (index) =>
            Sample(time: points[index].time, value: 140 + index.toDouble()),
      );
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hr},
      );

      final cropped = RawEditor(activity)
          .crop(
            start.add(const Duration(seconds: 10)),
            start.add(const Duration(seconds: 40)),
          )
          .activity;
      expect(cropped.points.length, 4);

      final downsampled = RawEditor(
        activity,
      ).downsampleTime(const Duration(seconds: 20)).activity;
      expect(downsampled.points.length, lessThan(activity.points.length));

      final resampled = RawTransforms.resample(
        activity,
        step: const Duration(seconds: 5),
      );
      expect(resampled.points.length, greaterThan(activity.points.length));
      expect(
        resampled.channel(Channel.heartRate).length,
        equals(activity.channel(Channel.heartRate).length),
      );

      final (activity: withDistance, totalDistance: total) =
          RawTransforms.computeCumulativeDistance(activity);
      expect(withDistance.channel(Channel.distance), isNotEmpty);
      expect(total, greaterThan(0));
    });

    test('markLapsByDistance computes split distances and remainder', () {
      final base = DateTime.utc(2024, 1, 2);
      final points = [
        GeoPoint(latitude: 40, longitude: -105, time: base),
        GeoPoint(
          latitude: 40.0005,
          longitude: -105.0005,
          time: base.add(const Duration(minutes: 5)),
        ),
        GeoPoint(
          latitude: 40.0007,
          longitude: -105.0007,
          time: base.add(const Duration(minutes: 10)),
        ),
        GeoPoint(
          latitude: 40.0009,
          longitude: -105.0009,
          time: base.add(const Duration(minutes: 15)),
        ),
      ];
      final distances = [
        Sample(time: points[0].time, value: 0),
        Sample(time: points[1].time, value: 800),
        Sample(time: points[2].time, value: 1800),
        Sample(time: points[3].time, value: 2300),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.distance: distances},
      );
      final laps = RawEditor(activity).markLapsByDistance(1000).activity.laps;
      expect(laps.length, 3);
      final rounded = laps
          .map((lap) => lap.distanceMeters?.round())
          .toList(growable: false);
      expect(rounded, equals([1000, 1000, 300]));
      expect(laps.last.distanceMeters, closeTo(300, 1e-6));
    });

    test('markLapsByDistance tolerates distance resets', () {
      final base = DateTime.utc(2024, 1, 5);
      final samples = <Sample>[
        Sample(time: base, value: 0),
        Sample(time: base.add(const Duration(minutes: 5)), value: 1100),
        Sample(time: base.add(const Duration(minutes: 10)), value: 1500),
        Sample(time: base.add(const Duration(minutes: 15)), value: 200),
        Sample(time: base.add(const Duration(minutes: 20)), value: 800),
        Sample(time: base.add(const Duration(minutes: 25)), value: 1400),
      ];
      final activity = RawActivity(channels: {Channel.distance: samples});

      final laps = RawEditor(activity).markLapsByDistance(1000).activity.laps;

      expect(laps.length, equals(3));
      expect(laps[0].distanceMeters, closeTo(1000, 1e-6));
      expect(laps[1].distanceMeters, closeTo(1000, 1e-6));
      expect(laps[2].distanceMeters, closeTo(700, 1e-6));
    });

    test('downsampleTime retains trailing point and channel samples', () {
      final base = DateTime.utc(2024, 1, 3, 6);
      final points = [
        GeoPoint(latitude: 40, longitude: -105, time: base),
        GeoPoint(
          latitude: 40.0002,
          longitude: -105.0002,
          time: base.add(const Duration(seconds: 3)),
        ),
        GeoPoint(
          latitude: 40.0004,
          longitude: -105.0004,
          time: base.add(const Duration(seconds: 5)),
        ),
      ];
      final hrSamples = [
        Sample(time: points[0].time, value: 140),
        Sample(time: points[2].time, value: 145),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hrSamples},
      );
      final downsampled = RawEditor(
        activity,
      ).downsampleTime(const Duration(seconds: 4)).activity;
      expect(downsampled.points.last.time, points.last.time);
      final hr = downsampled.channel(Channel.heartRate);
      expect(hr, isNotEmpty);
      expect(hr.last.time, points.last.time);
      expect(hr.last.value, closeTo(145, 1e-9));
    });

    test('sortAndDedup keeps latest sample for duplicate timestamps', () {
      final timestamp = DateTime.utc(2024, 1, 4, 7);
      final points = [GeoPoint(latitude: 40, longitude: -105, time: timestamp)];
      final samples = [
        Sample(time: timestamp, value: 150),
        Sample(time: timestamp, value: 155),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: samples},
      );
      final normalized = RawEditor(activity).sortAndDedup().activity;
      final hr = normalized.channel(Channel.heartRate);
      expect(hr.length, 1);
      expect(hr.single.value, closeTo(155, 1e-9));
    });
  });

  group('Validation', () {
    test('flags duplicates and coordinate issues', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final invalid = RawActivity(
        points: [
          GeoPoint(latitude: 95, longitude: 0, time: time),
          GeoPoint(latitude: 40, longitude: 200, time: time),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: time, value: 140),
            Sample(time: time, value: 141),
          ],
        },
      );

      final result = validateRawActivity(
        invalid,
        gapWarningThreshold: Duration.zero,
      );
      expect(result.errors.length, greaterThanOrEqualTo(3));
    });

    test('reports large gaps as warnings', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40, longitude: -105, time: time),
          GeoPoint(
            latitude: 40.01,
            longitude: -105.01,
            time: time.add(const Duration(minutes: 10)),
          ),
        ],
      );

      final result = validateRawActivity(
        activity,
        gapWarningThreshold: const Duration(seconds: 60),
      );
      expect(result.errors, isEmpty);
      expect(result.warnings, isNotEmpty);
    });
  });
}

RawActivity _buildSampleActivity() {
  final baseTime = DateTime.utc(2024, 4, 1, 6);
  final points = [
    GeoPoint(
      latitude: 40.0,
      longitude: -105.0,
      elevation: 1600,
      time: baseTime,
    ),
    GeoPoint(
      latitude: 40.0005,
      longitude: -105.0005,
      elevation: 1601,
      time: baseTime.add(const Duration(seconds: 5)),
    ),
    GeoPoint(
      latitude: 40.0010,
      longitude: -105.0010,
      elevation: 1602,
      time: baseTime.add(const Duration(seconds: 10)),
    ),
  ];
  final hr = [
    Sample(time: points[0].time, value: 140),
    Sample(time: points[1].time, value: 142),
    Sample(time: points[2].time, value: 145),
  ];
  final cadence = [
    Sample(time: points[0].time, value: 80),
    Sample(time: points[1].time, value: 82),
    Sample(time: points[2].time, value: 84),
  ];
  final power = [
    Sample(time: points[0].time, value: 200),
    Sample(time: points[1].time, value: 210),
    Sample(time: points[2].time, value: 220),
  ];
  final temperature = [
    Sample(time: points[0].time, value: 21),
    Sample(time: points[1].time, value: 22),
    Sample(time: points[2].time, value: 23),
  ];

  final baseActivity = RawActivity(
    points: points,
    channels: {
      Channel.heartRate: hr,
      Channel.cadence: cadence,
      Channel.power: power,
      Channel.temperature: temperature,
    },
    laps: [
      Lap(
        startTime: points.first.time,
        endTime: points.last.time,
        distanceMeters: 150,
      ),
    ],
    sport: Sport.cycling,
    creator: 'unit-test device',
  );

  final result = RawTransforms.computeCumulativeDistance(baseActivity);
  final withDistance = result.activity;
  final withSpeed = RawEditor(
    withDistance,
  ).recomputeDistanceAndSpeed().activity;
  return withSpeed;
}

int _fitCrc(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    var tmp = _fitCrcTable[crc & 0x0F];
    crc = (crc >> 4) & 0x0FFF;
    crc ^= tmp ^ _fitCrcTable[byte & 0x0F];
    tmp = _fitCrcTable[crc & 0x0F];
    crc = (crc >> 4) & 0x0FFF;
    crc ^= tmp ^ _fitCrcTable[(byte >> 4) & 0x0F];
  }
  return crc & 0xFFFF;
}

const List<int> _fitCrcTable = [
  0x0000,
  0xCC01,
  0xD801,
  0x1400,
  0xF001,
  0x3C00,
  0x2800,
  0xE401,
  0xA001,
  0x6C00,
  0x7800,
  0xB401,
  0x5000,
  0x9C01,
  0x8801,
  0x4400,
];

bool _hasMatchingSample(
  List<Sample> samples,
  Sample target,
  Duration tolerance,
) {
  final targetMicros = target.time.microsecondsSinceEpoch;
  final limit = tolerance.inMicroseconds;
  for (final sample in samples) {
    final delta = (sample.time.microsecondsSinceEpoch - targetMicros).abs();
    if (delta <= limit && (sample.value - target.value).abs() < 0.5) {
      return true;
    }
  }
  return false;
}

class _CountingStream extends Stream<List<int>> {
  _CountingStream(this._chunks);

  final List<List<int>> _chunks;
  int listenCount = 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (listenCount > 0) {
      throw StateError('Stream can only be listened to once.');
    }
    listenCount++;
    final controller = StreamController<List<int>>();
    Future(() async {
      try {
        for (final chunk in _chunks) {
          controller.add(chunk);
          await Future<void>.delayed(Duration.zero);
        }
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      } finally {
        await controller.close();
      }
    });
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

Uint8List _buildCompressedFitSample() {
  final data = BytesBuilder();
  data.add([
    0x40, // definition header for local message 0
    0x00, // reserved
    0x00, // little-endian architecture
    0x14,
    0x00, // global message 20 (record)
    0x03, // field count
    0xFD,
    0x04,
    0x86, // timestamp (uint32)
    0x00,
    0x04,
    0x85, // latitude (sint32)
    0x01,
    0x04,
    0x85, // longitude (sint32)
  ]);

  int writeInt32(int value) => value & 0xFFFFFFFF;
  List<int> int32LE(int value) => [
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ];

  const timestamp = 1000;
  data.add([
    0x00, // data message header (local 0)
    ...int32LE(timestamp),
    ...int32LE(writeInt32(_encodeSemicircles(0.0))),
    ...int32LE(writeInt32(_encodeSemicircles(0.0))),
  ]);

  data.add([
    0x89, // compressed header: local 0, offset 9s (~1s total delta)
    ...int32LE(writeInt32(_encodeSemicircles(0.0005))),
    ...int32LE(writeInt32(_encodeSemicircles(0.0005))),
  ]);

  final payload = data.toBytes();
  final header = _buildFitHeader(payload.length);
  final crc = _fitCrc(payload);

  return Uint8List.fromList([
    ...header,
    ...payload,
    crc & 0xFF,
    (crc >> 8) & 0xFF,
  ]);
}

Uint8List _buildFitHeader(int dataSize) {
  final header = Uint8List(14);
  final bd = ByteData.view(header.buffer);
  header[0] = 14;
  header[1] = 0x10;
  bd.setUint16(2, 0, Endian.little);
  bd.setUint32(4, dataSize, Endian.little);
  header.setRange(8, 12, '.FIT'.codeUnits);
  final crc = _fitCrc(header.sublist(0, 12));
  bd.setUint16(12, crc, Endian.little);
  return header;
}

int _encodeSemicircles(double degrees) {
  return ((degrees * 2147483648.0) / 180.0).round();
}

Uint8List _buildFitFileWithDeveloperData() {
  final definition = BytesBuilder();
  definition
    ..add([0x40 | 0x20, 0x00, 0x00])
    ..add(_uint16LeBytes(20))
    ..addByte(3)
    ..add([0xFD, 0x04, 0x86])
    ..add([0x00, 0x04, 0x85])
    ..add([0x01, 0x04, 0x85])
    ..addByte(1)
    ..add([0x01, 0x02, 0x00]);

  final record = BytesBuilder();
  record
    ..addByte(0x00)
    ..add(_uint32LeBytes(1000))
    ..add(_int32LeBytes(_encodeSemicircles(0)))
    ..add(_int32LeBytes(_encodeSemicircles(0)))
    ..add([0x12, 0x34]);

  final fullDataBuilder = BytesBuilder()
    ..add(definition.toBytes())
    ..add(record.toBytes());
  final fullData = fullDataBuilder.toBytes();
  final crc = _fitCrc(fullData);
  final payloadBuilder = BytesBuilder()
    ..add(fullData)
    ..addByte(crc & 0xFF)
    ..addByte((crc >> 8) & 0xFF);
  final payload = payloadBuilder.toBytes();
  final header = _buildFitHeader(fullData.length);
  return Uint8List.fromList([...header, ...payload]);
}

List<int> _uint16LeBytes(int value) => [value & 0xFF, (value >> 8) & 0xFF];

List<int> _uint32LeBytes(int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

List<int> _int32LeBytes(int value) {
  final normalized = value & 0xFFFFFFFF;
  return _uint32LeBytes(normalized);
}

List<int> _encodeUtf16LeWithBom(String value) {
  final encoded = <int>[0xFF, 0xFE];
  for (final unit in value.codeUnits) {
    encoded.add(unit & 0xFF);
    encoded.add((unit >> 8) & 0xFF);
  }
  return encoded;
}

const String _sampleGpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="TestDevice"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <trk>
    <name>Sample Run</name>
    <type>Running</type>
    <trkseg>
      <trkpt lat="40.000000" lon="-105.000000">
        <ele>1600.0</ele>
        <time>2024-03-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>140</gpxtpx:hr>
            <gpxtpx:cad>82</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="40.000500" lon="-105.000500">
        <ele>1601.0</ele>
        <time>2024-03-01T10:00:10Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>142</gpxtpx:hr>
            <gpxtpx:cad>84</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="40.001000" lon="-105.001000">
        <ele>1602.0</ele>
        <time>2024-03-01T10:00:20Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>145</gpxtpx:hr>
            <gpxtpx:cad>86</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
''';

const String _sampleTcx = '''
<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-03-01T10:00:00Z</Id>
      <Lap StartTime="2024-03-01T10:00:00Z">
        <TotalTimeSeconds>20.0</TotalTimeSeconds>
        <DistanceMeters>140.0</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-03-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.000000</LatitudeDegrees>
              <LongitudeDegrees>-105.000000</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1600.0</AltitudeMeters>
            <DistanceMeters>0.0</DistanceMeters>
            <HeartRateBpm>
              <Value>140</Value>
            </HeartRateBpm>
            <Cadence>82</Cadence>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-03-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.000500</LatitudeDegrees>
              <LongitudeDegrees>-105.000500</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1601.0</AltitudeMeters>
            <DistanceMeters>70.0</DistanceMeters>
            <HeartRateBpm>
              <Value>142</Value>
            </HeartRateBpm>
            <Cadence>84</Cadence>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-03-01T10:00:20Z</Time>
            <Position>
              <LatitudeDegrees>40.001000</LatitudeDegrees>
              <LongitudeDegrees>-105.001000</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1602.0</AltitudeMeters>
            <DistanceMeters>140.0</DistanceMeters>
            <HeartRateBpm>
              <Value>145</Value>
            </HeartRateBpm>
            <Cadence>86</Cadence>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
''';

int _isolatedComputation() => 73;
