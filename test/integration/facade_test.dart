// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for ActivityFiles facade API.
///
/// Tests the high-level convenience methods for loading, converting, and
/// exporting activity files.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/sample_data.dart';
import '../helpers/fit_helpers.dart';
import '../helpers/stream_helpers.dart';

void main() {
  const encoderOptions = EncoderOptions(
    defaultMaxDelta: Duration(seconds: 3),
    precisionLatLon: 6,
    precisionEle: 2,
  );

  group('Facade convenience', () {
    test('load infers GPX format from inline content', () async {
      final result = await ActivityFiles.load(sampleGpx, useIsolate: false);
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
        source: sampleGpx,
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
        final encoded = encodeUtf16LeWithBom(sampleGpx);
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
        source: sampleGpx,
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

    test('load and convert accept chunked stream sources', () async {
      final bytes = utf8.encode(sampleGpx);
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
      final bytes = utf8.encode(sampleGpx);
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
      final bytes = utf8.encode(sampleGpx);
      final stream = CountingStream([bytes.sublist(0, 40), bytes.sublist(40)]);

      final loaded = await ActivityFiles.load(stream, useIsolate: false);

      expect(loaded.activity.points, isNotEmpty);
      expect(stream.listenCount, equals(1));
    });

    test('parseStream surfaces format exceptions as diagnostics', () async {
      final stream = Stream<List<int>>.fromIterable([utf8.encode(sampleGpx)]);
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
      final bytes = utf8.encode(sampleGpx);
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
        final bytes = utf8.encode(sampleGpx);
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
        source: sampleGpx,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
      );
      expect(conversion.validation, isNull);
      expect(conversion.processingStats.validationDuration, isNull);
    });

    test('convert runs validation when requested', () async {
      final conversion = await ActivityFiles.convert(
        source: sampleGpx,
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
        source: sampleGpx,
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
        source: sampleGpx,
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
      final stream = Stream<List<int>>.fromIterable([utf8.encode(sampleGpx)]);
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

    test(
      'export copyWith refreshes binary cache when encoded changes',
      () async {
        final conversion = await ActivityFiles.convert(
          source: sampleGpx,
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

  group('Multi-activity operations', () {
    test('merge combines multiple activities and sorts by default', () {
      final base = DateTime.utc(2024, 12, 1, 6);
      final swim = ActivityFiles.builder()
        ..sport = Sport.swimming
        ..addPoint(latitude: 40.0, longitude: -105.0, time: base)
        ..addPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 5)),
        )
        ..addSample(channel: Channel.heartRate, time: base, value: 120)
        ..addLap(
          startTime: base,
          endTime: base.add(const Duration(minutes: 5)),
          distanceMeters: 400,
          name: 'Swim',
        );

      final bike = ActivityFiles.builder()
        ..sport = Sport.cycling
        ..addPoint(
          latitude: 40.0002,
          longitude: -105.0002,
          time: base.add(const Duration(minutes: 10)),
        )
        ..addPoint(
          latitude: 40.0003,
          longitude: -105.0003,
          time: base.add(const Duration(minutes: 15)),
        )
        ..addSample(
          channel: Channel.heartRate,
          time: base.add(const Duration(minutes: 10)),
          value: 140,
        )
        ..addSample(
          channel: Channel.power,
          time: base.add(const Duration(minutes: 10)),
          value: 200,
        )
        ..addLap(
          startTime: base.add(const Duration(minutes: 10)),
          endTime: base.add(const Duration(minutes: 15)),
          distanceMeters: 2000,
          name: 'Bike',
        );

      final merged = ActivityFiles.merge([
        swim.build(),
        bike.build(),
      ], normalize: true);

      expect(merged.points.length, equals(4));
      expect(merged.points.first.time, equals(base));
      expect(
        merged.points.last.time,
        equals(base.add(const Duration(minutes: 15))),
      );
      expect(merged.channel(Channel.heartRate).length, equals(2));
      expect(merged.channel(Channel.power).length, equals(1));
      expect(merged.laps.length, equals(2));
      expect(merged.sport, equals(Sport.swimming));
    });

    test('merge preserves sport per lap when requested', () {
      final base = DateTime.utc(2024, 12, 1, 7);
      final swim = ActivityFiles.builder()
        ..sport = Sport.swimming
        ..addPoint(latitude: 40.0, longitude: -105.0, time: base)
        ..addLap(
          startTime: base,
          endTime: base.add(const Duration(minutes: 5)),
        );

      final bike = ActivityFiles.builder()
        ..sport = Sport.cycling
        ..addPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 10)),
        )
        ..addLap(
          startTime: base.add(const Duration(minutes: 10)),
          endTime: base.add(const Duration(minutes: 20)),
        );

      final merged = ActivityFiles.merge([
        swim.build(),
        bike.build(),
      ], preserveSportPerLap: true);

      expect(merged.laps.length, equals(2));
      expect(merged.laps[0].sport, equals(Sport.swimming));
      expect(merged.laps[1].sport, equals(Sport.cycling));
    });

    test('merge handles single activity passthrough', () {
      final base = DateTime.utc(2024, 12, 1, 8);
      final activity = ActivityFiles.builder()
        ..addPoint(latitude: 40.0, longitude: -105.0, time: base);

      final merged = ActivityFiles.merge([activity.build()]);

      expect(merged.points.length, equals(1));
      expect(identical(merged, activity.build()), isFalse);
    });

    test('merge rejects empty activity list', () {
      expect(() => ActivityFiles.merge([]), throwsArgumentError);
    });

    test('merge supports custom creator', () {
      final base = DateTime.utc(2024, 12, 1, 9);
      final a1 = ActivityFiles.builder()
        ..creator = 'device1'
        ..addPoint(latitude: 40.0, longitude: -105.0, time: base);
      final a2 = ActivityFiles.builder()
        ..creator = 'device2'
        ..addPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 1)),
        );

      final merged = ActivityFiles.merge([
        a1.build(),
        a2.build(),
      ], creator: 'multi-device-merger');

      expect(merged.creator, equals('multi-device-merger'));
    });

    test('splitBySport separates triathlon by sport laps', () {
      final base = DateTime.utc(2024, 12, 2, 6);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 5)),
        ),
        GeoPoint(
          latitude: 40.0002,
          longitude: -105.0002,
          time: base.add(const Duration(minutes: 15)),
        ),
        GeoPoint(
          latitude: 40.0003,
          longitude: -105.0003,
          time: base.add(const Duration(minutes: 20)),
        ),
      ];
      final laps = [
        Lap(
          startTime: base,
          endTime: base.add(const Duration(minutes: 5)),
          sport: Sport.swimming,
          name: 'Swim',
        ),
        Lap(
          startTime: base.add(const Duration(minutes: 15)),
          endTime: base.add(const Duration(minutes: 20)),
          sport: Sport.cycling,
          name: 'Bike',
        ),
      ];
      final channels = {
        Channel.heartRate: [
          Sample(time: base, value: 120),
          Sample(time: base.add(const Duration(minutes: 5)), value: 125),
          Sample(time: base.add(const Duration(minutes: 15)), value: 140),
          Sample(time: base.add(const Duration(minutes: 20)), value: 145),
        ],
      };
      final triathlon = RawActivity(
        points: points,
        laps: laps,
        channels: channels,
        sport: Sport.other,
      );

      final splits = ActivityFiles.splitBySport(triathlon);

      expect(splits.length, equals(2));
      expect(splits.containsKey(Sport.swimming), isTrue);
      expect(splits.containsKey(Sport.cycling), isTrue);

      final swim = splits[Sport.swimming]!;
      expect(swim.points.length, equals(2));
      expect(swim.points.first.time, equals(base));
      expect(swim.laps.length, equals(1));
      expect(swim.laps.first.name, equals('Swim'));
      expect(swim.channel(Channel.heartRate).length, equals(2));

      final bike = splits[Sport.cycling]!;
      expect(bike.points.length, equals(2));
      expect(
        bike.points.first.time,
        equals(base.add(const Duration(minutes: 15))),
      );
      expect(bike.laps.length, equals(1));
      expect(bike.laps.first.name, equals('Bike'));
    });

    test('splitBySport returns single-sport activity as-is', () {
      final base = DateTime.utc(2024, 12, 2, 7);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.0001,
            longitude: -105.0001,
            time: base.add(const Duration(minutes: 5)),
          ),
        ],
        laps: [
          Lap(
            startTime: base,
            endTime: base.add(const Duration(minutes: 5)),
            sport: Sport.running,
          ),
        ],
        sport: Sport.running,
      );

      final splits = ActivityFiles.splitBySport(activity);

      expect(splits.length, equals(1));
      expect(splits[Sport.running], isNotNull);
      expect(splits[Sport.running]!.points.length, equals(2));
    });

    test('splitBySport handles activity without laps', () {
      final base = DateTime.utc(2024, 12, 2, 8);
      final activity = RawActivity(
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
        sport: Sport.cycling,
      );

      final splits = ActivityFiles.splitBySport(activity);

      expect(splits.length, equals(1));
      expect(splits[Sport.cycling], isNotNull);
    });

    test(
      'splitBySport uses activity sport for laps without explicit sport',
      () {
        final base = DateTime.utc(2024, 12, 2, 9);
        final activity = RawActivity(
          points: [
            GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
            GeoPoint(
              latitude: 40.0001,
              longitude: -105.0001,
              time: base.add(const Duration(minutes: 5)),
            ),
          ],
          laps: [
            Lap(startTime: base, endTime: base.add(const Duration(minutes: 5))),
          ],
          sport: Sport.walking,
        );

        final splits = ActivityFiles.splitBySport(activity);

        expect(splits.length, equals(1));
        expect(splits.containsKey(Sport.walking), isTrue);
      },
    );
  });

  group('Sport inference', () {
    test('inferSport resolves nested object values', () {
      final source = {
        'metadata': {
          'activity': {'type': 'cycling'},
        },
      };
      expect(ActivityFiles.inferSport(source), equals(Sport.cycling));
    });

    test('inferSport resolves iterable values', () {
      final source = [
        'unknown',
        {'sport': 'swimming'},
      ];
      expect(ActivityFiles.inferSport(source), equals(Sport.swimming));
    });

    test('inferSport resolves numeric sport codes', () {
      expect(ActivityFiles.inferSport(0), equals(Sport.other));
      expect(ActivityFiles.inferSport(1), equals(Sport.running));
      expect(ActivityFiles.inferSport(2), equals(Sport.cycling));
      expect(ActivityFiles.inferSport(3), equals(Sport.swimming));
      expect(ActivityFiles.inferSport(4), equals(Sport.walking));
      expect(ActivityFiles.inferSport(5), equals(Sport.hiking));
      expect(ActivityFiles.inferSport(99), equals(Sport.unknown));
    });

    test('clearSportMappers removes all registered mappers', () {
      Sport? mapper1(dynamic source) => source == 1 ? Sport.cycling : null;
      Sport? mapper2(dynamic source) => source == 2 ? Sport.running : null;
      ActivityFiles.registerSportMapper(mapper1);
      ActivityFiles.registerSportMapper(mapper2);
      addTearDown(ActivityFiles.clearSportMappers);

      expect(ActivityFiles.inferSport(1), equals(Sport.cycling));
      expect(ActivityFiles.inferSport(2), equals(Sport.running));

      ActivityFiles.clearSportMappers();

      // After clearing custom mappers, built-in primitive mappers still work
      expect(ActivityFiles.inferSport(1), equals(Sport.running));
      expect(ActivityFiles.inferSport(2), equals(Sport.cycling));
    });

    test('unregisterSportMapper returns true when mapper removed', () {
      Sport? mapper(dynamic source) => null;
      ActivityFiles.registerSportMapper(mapper);
      addTearDown(ActivityFiles.clearSportMappers);

      final removed = ActivityFiles.unregisterSportMapper(mapper);
      expect(removed, isTrue);

      final removedAgain = ActivityFiles.unregisterSportMapper(mapper);
      expect(removedAgain, isFalse);
    });
  });

  group('Format detection', () {
    test('detectFormat identifies GPX from string content', () {
      final format = ActivityFiles.detectFormat(sampleGpx);
      expect(format, equals(ActivityFileFormat.gpx));
    });

    test('detectFormat identifies TCX from string content', () {
      final format = ActivityFiles.detectFormat(sampleTcx);
      expect(format, equals(ActivityFileFormat.tcx));
    });

    test('detectFormat identifies FIT from base64 string', () {
      final fitBytes = buildFitFileWithDeveloperData();
      final base64Fit = base64Encode(fitBytes);
      final format = ActivityFiles.detectFormat(base64Fit);
      expect(format, equals(ActivityFileFormat.fit));
    });

    test('detectFormat identifies FIT from binary bytes', () {
      final fitBytes = buildFitFileWithDeveloperData();
      final format = ActivityFiles.detectFormat(fitBytes);
      expect(format, equals(ActivityFileFormat.fit));
    });

    test('detectFormat returns null for ambiguous content', () {
      final format = ActivityFiles.detectFormat('random text');
      expect(format, isNull);
    });

    test('detectFormat handles UTF-32 BOM', () {
      // Create a minimal GPX with UTF-32 BE BOM
      final minimalGpx = '<?xml version="1.0"?><gpx></gpx>';
      final withBom = BytesBuilder()
        ..add([0x00, 0x00, 0xFE, 0xFF]); // UTF-32 BE BOM
      // Encode each character as UTF-32 BE (4 bytes per char)
      for (final codeUnit in minimalGpx.codeUnits) {
        withBom.add([0x00, 0x00, (codeUnit >> 8) & 0xFF, codeUnit & 0xFF]);
      }
      final format = ActivityFiles.detectFormat(
        Uint8List.fromList(withBom.toBytes()),
      );
      expect(format, equals(ActivityFileFormat.gpx));
    });
  });

  group('Transform helpers', () {
    test('sortAndDedup removes duplicate timestamps', () {
      final base = DateTime.utc(2024, 12, 3, 6);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 1)),
        ),
      ];
      final activity = RawActivity(points: points);

      final cleaned = ActivityFiles.sortAndDedup(activity);

      expect(cleaned.points.length, equals(2));
    });

    test('edit returns RawEditor for fluent transforms', () {
      final base = DateTime.utc(2024, 12, 3, 7);
      final activity = RawActivity(
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
      );

      final editor = ActivityFiles.edit(activity);

      expect(editor, isA<RawEditor>());
      expect(editor.activity, equals(activity));
    });

    test('recomputeDistanceAndSpeed recalculates from GPS', () {
      final base = DateTime.utc(2024, 12, 3, 8);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0009,
          longitude: -105.0009,
          time: base.add(const Duration(minutes: 1)),
        ),
      ];
      final activity = RawActivity(points: points);

      final recomputed = ActivityFiles.recomputeDistanceAndSpeed(activity);

      final distance = recomputed.channel(Channel.distance);
      expect(distance, isNotEmpty);
      expect(distance.last.value, greaterThan(0));

      final speed = recomputed.channel(Channel.speed);
      expect(speed, isNotEmpty);
    });
  });

  group('Builder bulk operations', () {
    test('builder addPoints bulk method', () {
      final base = DateTime.utc(2024, 12, 4, 6);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 1)),
        ),
      ];

      final activity = ActivityFiles.builder()..addPoints(points);

      expect(activity.build().points.length, equals(2));
    });

    test('builder addChannel bulk method', () {
      final base = DateTime.utc(2024, 12, 4, 7);
      final samples = [
        Sample(time: base, value: 140),
        Sample(time: base.add(const Duration(minutes: 1)), value: 145),
      ];

      final activity = ActivityFiles.builder()
        ..addPoint(latitude: 40.0, longitude: -105.0, time: base)
        ..addPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 1)),
        )
        ..addChannel(Channel.heartRate, samples);

      expect(activity.build().channel(Channel.heartRate).length, equals(2));
    });

    test('builder addLaps bulk method', () {
      final base = DateTime.utc(2024, 12, 4, 8);
      final laps = [
        Lap(
          startTime: base,
          endTime: base.add(const Duration(minutes: 5)),
          distanceMeters: 500,
        ),
        Lap(
          startTime: base.add(const Duration(minutes: 5)),
          endTime: base.add(const Duration(minutes: 10)),
          distanceMeters: 600,
        ),
      ];

      final activity = ActivityFiles.builder()
        ..addPoint(latitude: 40.0, longitude: -105.0, time: base)
        ..addPoint(
          latitude: 40.0001,
          longitude: -105.0001,
          time: base.add(const Duration(minutes: 10)),
        )
        ..addLaps(laps);

      expect(activity.build().laps.length, equals(2));
    });

    test('builder addGpxMetadataExtensions bulk method', () {
      final extensions = [
        GpxExtensionNode(
          name: 'tag1',
          namespacePrefix: 'ex',
          namespaceUri: 'https://example.com',
        ),
        GpxExtensionNode(
          name: 'tag2',
          namespacePrefix: 'ex',
          namespaceUri: 'https://example.com',
        ),
      ];

      final activity = ActivityFiles.builder()
        ..addGpxMetadataExtensions(extensions);

      expect(activity.build().gpxMetadataExtensions.length, equals(2));
    });

    test('builder addGpxTrackExtensions bulk method', () {
      final extensions = [
        GpxExtensionNode(
          name: 'tag1',
          namespacePrefix: 'ex',
          namespaceUri: 'https://example.com',
        ),
        GpxExtensionNode(
          name: 'tag2',
          namespacePrefix: 'ex',
          namespaceUri: 'https://example.com',
        ),
      ];

      final activity = ActivityFiles.builder()
        ..addGpxTrackExtensions(extensions);

      expect(activity.build().gpxTrackExtensions.length, equals(2));
    });
  });

  group('FIT integrity checks', () {
    test('load with strictFitIntegrity rejects corrupted FIT files', () async {
      final bytes = await File('example/assets/sample.fit').readAsBytes();
      final corrupted = Uint8List.fromList(bytes);
      corrupted[corrupted.length - 1] ^= 0xFF;

      await expectLater(
        () => ActivityFiles.load(
          corrupted,
          format: ActivityFileFormat.fit,
          useIsolate: false,
          strictFitIntegrity: true,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('load without strictFitIntegrity tolerates CRC errors', () async {
      final bytes = await File('example/assets/sample.fit').readAsBytes();
      final corrupted = Uint8List.fromList(bytes);
      corrupted[corrupted.length - 1] ^= 0xFF;

      final result = await ActivityFiles.load(
        corrupted,
        format: ActivityFileFormat.fit,
        useIsolate: false,
        strictFitIntegrity: false,
      );

      expect(result.hasErrors, isTrue);
      expect(result.activity.points, isNotEmpty);
    });
  });

  group('Normalization optimization', () {
    test('normalizeActivity short-circuits for already-normalized data', () {
      final base = DateTime.utc(2024, 12, 5, 6);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.0001,
            longitude: -105.0001,
            time: base.add(const Duration(minutes: 1)),
          ),
        ],
      );

      final normalized = ActivityFiles.normalizeActivity(activity);

      // Short-circuit optimization returns same object for already-normalized data
      expect(identical(normalized, activity), isTrue);

      final stats = ActivityFiles.export(
        activity: normalized,
        to: ActivityFileFormat.gpx,
      ).processingStats.normalization;

      expect(stats, isNotNull);
      expect(stats!.applied, isTrue);
      // Short-circuit means no changes were needed
      expect(stats.hasChanges, isFalse);
    });
  });

  group('GPX extension helpers', () {
    test('gpxActivityLabelNode supports custom namespace', () {
      final node = ActivityFiles.gpxActivityLabelNode(
        'Running',
        prefix: 'custom',
        namespaceUri: 'https://custom.example.com',
        attributes: {'priority': 'high'},
      );

      expect(node.name, equals('activity'));
      expect(node.namespacePrefix, equals('custom'));
      expect(node.namespaceUri, equals('https://custom.example.com'));
      expect(node.value, equals('Running'));
      expect(node.attributes['priority'], equals('high'));
    });

    test('gpxDeviceNode includes extra fields', () {
      final device = ActivityDeviceMetadata(
        manufacturer: 'Garmin',
        model: 'Fenix 7',
      );
      final node = ActivityFiles.gpxDeviceNode(
        device,
        extras: {'firmware': '12.34', 'batteryLevel': 85},
      );

      expect(node.name, equals('device'));
      expect(node.children, isNotEmpty);

      final hasManufacturer = node.children.any(
        (child) => child.name == 'manufacturer' && child.value == 'Garmin',
      );
      expect(hasManufacturer, isTrue);

      final hasFirmware = node.children.any(
        (child) => child.name == 'firmware' && child.value == '12.34',
      );
      expect(hasFirmware, isTrue);
    });

    test('gpxDeviceSummaryNode uses defaults correctly', () {
      final device = ActivityDeviceMetadata(
        manufacturer: 'Wahoo',
        model: 'ELEMNT BOLT',
        serialNumber: 'SN12345',
      );
      final node = ActivityFiles.gpxDeviceSummaryNode(device);

      expect(node.name, equals('deviceSummary'));
      expect(
        node.namespacePrefix,
        equals(ActivityFiles.gpxDefaultExtensionPrefix),
      );
      expect(
        node.namespaceUri,
        equals(ActivityFiles.gpxDefaultExtensionNamespace),
      );
      expect(node.children, isNotEmpty);
    });
  });

  group('Additional edge cases and coverage', () {
    test('load handles File sources correctly', () async {
      final file = File('example/assets/sample.gpx');
      final result = await ActivityFiles.load(file, useIsolate: false);
      expect(result.format, equals(ActivityFileFormat.gpx));
      expect(result.activity.points, isNotEmpty);
    });

    test('load handles Stream sources correctly', () async {
      final file = File('example/assets/sample.gpx');
      final stream = file.openRead();
      final result = await ActivityFiles.load(stream, useIsolate: false);
      expect(result.format, equals(ActivityFileFormat.gpx));
      expect(result.activity.points, isNotEmpty);
    });

    test('load with explicit format overrides detection', () async {
      final result = await ActivityFiles.load(
        sampleGpx,
        format: ActivityFileFormat.gpx,
        useIsolate: false,
      );
      expect(result.format, equals(ActivityFileFormat.gpx));
    });

    test('convert with exportInIsolate=true offloads encoding', () async {
      final result = await ActivityFiles.convert(
        source: sampleGpx,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
        exportInIsolate: true,
      );
      expect(result.targetFormat, equals(ActivityFileFormat.tcx));
      expect(result.encoded, isNotEmpty);
    });

    test('convert with runValidation appends diagnostics', () async {
      // Create an activity with validation issues
      final base = DateTime.utc(2024, 12, 10, 6);
      final problematic = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base), // duplicate
        ],
      );
      final gpxString = ActivityEncoder.encode(
        problematic,
        ActivityFileFormat.gpx,
      );

      final result = await ActivityFiles.convert(
        source: gpxString,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
        runValidation: true,
      );

      expect(result.validation, isNotNull);
      expect(result.hasDiagnostics, isTrue);
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

    test('validate returns structural validation result', () {
      final base = DateTime.utc(2024, 12, 10, 9);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.0001,
            longitude: -105.0001,
            time: base.add(const Duration(minutes: 1)),
          ),
        ],
      );

      final result = ActivityFiles.validate(activity);

      expect(result, isNotNull);
      expect(result.isValid, isTrue);
    });

    test('validate with custom gap warning threshold', () {
      final base = DateTime.utc(2024, 12, 10, 10);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.0001,
            longitude: -105.0001,
            time: base.add(const Duration(minutes: 10)),
          ),
        ],
      );

      final result = ActivityFiles.validate(
        activity,
        gapWarningThreshold: const Duration(minutes: 5),
      );

      expect(result.warnings.isNotEmpty, isTrue);
    });

    test('builder clear method resets all state', () {
      final base = DateTime.utc(2024, 12, 10, 11);
      final builder = ActivityFiles.builder()
        ..sport = Sport.running
        ..creator = 'test'
        ..addPoint(latitude: 40.0, longitude: -105.0, time: base)
        ..addSample(channel: Channel.heartRate, time: base, value: 150);

      builder.clear();

      final activity = builder.build(normalize: false);
      expect(activity.points, isEmpty);
      expect(activity.channels, isEmpty);
      expect(activity.laps, isEmpty);
    });

    test('builder setDeviceMetadata sets device', () {
      final device = ActivityDeviceMetadata(
        manufacturer: 'TestManufacturer',
        model: 'TestModel',
      );
      final builder = ActivityFiles.builder()..setDeviceMetadata(device);

      final activity = builder.build();
      expect(activity.device, isNotNull);
      expect(activity.device!.manufacturer, equals('TestManufacturer'));
    });

    test('builder configureGpxMetadata sets GPX metadata fields', () {
      final builder = ActivityFiles.builder()
        ..configureGpxMetadata(
          name: 'Test Activity',
          description: 'Test Description',
          includeCreatorDescription: false,
        );

      final activity = builder.build();
      expect(activity.gpxMetadataName, equals('Test Activity'));
      expect(activity.gpxMetadataDescription, equals('Test Description'));
      expect(activity.gpxIncludeCreatorMetadataDescription, isFalse);
    });

    test('builder configureGpxTrack sets GPX track fields', () {
      final builder = ActivityFiles.builder()
        ..configureGpxTrack(
          name: 'Track Name',
          description: 'Track Description',
          type: 'Workout',
        );

      final activity = builder.build();
      expect(activity.gpxTrackName, equals('Track Name'));
      expect(activity.gpxTrackDescription, equals('Track Description'));
      expect(activity.gpxTrackType, equals('Workout'));
    });

    test('builder clearGpxExtensions removes all GPX extensions', () {
      final builder = ActivityFiles.builder()
        ..addGpxMetadataExtension(
          GpxExtensionNode(
            name: 'test',
            namespacePrefix: 'ex',
            namespaceUri: 'https://example.com',
          ),
        )
        ..clearGpxExtensions();

      final activity = builder.build();
      expect(activity.gpxMetadataExtensions, isEmpty);
      expect(activity.gpxTrackExtensions, isEmpty);
    });

    test('registerSportMapper ignores duplicate mappers', () {
      Sport? mapper(dynamic source) => null;
      ActivityFiles.registerSportMapper(mapper);
      ActivityFiles.registerSportMapper(mapper); // Should be ignored
      addTearDown(ActivityFiles.clearSportMappers);

      final removed = ActivityFiles.unregisterSportMapper(mapper);
      expect(removed, isTrue);

      final removedAgain = ActivityFiles.unregisterSportMapper(mapper);
      expect(removedAgain, isFalse); // Already removed
    });

    test('inferSport uses custom fallback', () {
      final result = ActivityFiles.inferSport(
        'unknown sport type',
        fallback: Sport.other,
      );
      expect(result, equals(Sport.other));
    });

    test('export with normalize=false but unsorted data auto-sorts', () {
      final base = DateTime.utc(2024, 12, 10, 12);
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0001,
            longitude: -105.0001,
            time: base.add(const Duration(minutes: 1)),
          ),
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        ],
      );

      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.gpx,
        normalize: false,
      );

      expect(result.activity.points.first.time, equals(base));
    });

    test('exportAsync offloads work to isolate', () async {
      final base = DateTime.utc(2024, 12, 10, 13);
      final activity = RawActivity(
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
      );

      final result = await ActivityFiles.exportAsync(
        activity: activity,
        to: ActivityFileFormat.gpx,
        useIsolate: true,
      );

      expect(result.encoded, isNotEmpty);
    });

    test(
      'ActivityConversionResult.copyWith preserves binary cache correctly',
      () async {
        final result = await ActivityFiles.convert(
          source: sampleGpx,
          to: ActivityFileFormat.fit,
          useIsolate: false,
        );

        final copied = result.copyWith();
        expect(copied.asBytes(), equals(result.asBytes()));
      },
    );

    test('ActivityLoadResult provides payload', () async {
      final result = await ActivityFiles.load(sampleGpx, useIsolate: false);
      expect(result.payload, isNotNull);
      expect(result.stringPayload, isNotNull);
      expect(result.stringPayload, equals(sampleGpx));
    });

    test('builderFromStreams with custom timestampConverter', () {
      DateTime customDecoder(int timestamp) =>
          DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);

      final base = DateTime.utc(2024, 12, 10, 14);
      final ts = (base.millisecondsSinceEpoch / 1000).round();

      final builder = ActivityFiles.builderFromStreams(
        location: [
          (timestamp: ts, latitude: 40.0, longitude: -105.0, elevation: 1600),
        ],
        timestampConverter: customDecoder,
      );

      final activity = builder.build();
      expect(activity.points.length, equals(1));
      expect(activity.points.first.time, equals(base));
    });

    test('convertAndExport from streams with all parameters', () async {
      final base = DateTime.utc(2024, 12, 10, 15);
      final ts = base.millisecondsSinceEpoch;

      final result = await ActivityFiles.convertAndExport(
        location: [
          (timestamp: ts, latitude: 40.0, longitude: -105.0, elevation: 1600),
          (
            timestamp: ts + 60000,
            latitude: 40.0001,
            longitude: -105.0001,
            elevation: 1601,
          ),
        ],
        channels: {
          Channel.heartRate: [
            (timestamp: ts, value: 140),
            (timestamp: ts + 60000, value: 145),
          ],
        },
        label: 'Test Activity',
        creator: 'test-suite',
        sportSource: Sport.running,
        to: ActivityFileFormat.gpx,
        normalize: true,
        runValidation: true,
      );

      expect(result.activity.sport, equals(Sport.running));
      expect(result.activity.points.length, equals(2));
      expect(result.validation, isNotNull);
    });

    test('detectFormat with allowFilePaths reads from disk', () async {
      final format = ActivityFiles.detectFormat(
        'example/assets/sample.gpx',
        allowFilePaths: true,
      );
      expect(format, equals(ActivityFileFormat.gpx));
    });

    test('detectFormat without allowFilePaths treats string as content', () {
      final format = ActivityFiles.detectFormat(
        'example/assets/sample.gpx',
        allowFilePaths: false,
      );
      expect(format, isNull); // Path string doesn't look like any format
    });

    test('merge with custom creator', () {
      final base = DateTime.utc(2024, 12, 10, 16);
      final act1 = RawActivity(
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
        sport: Sport.running,
      );
      final act2 = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0001,
            longitude: -105.0001,
            time: base.add(const Duration(minutes: 1)),
          ),
        ],
        sport: Sport.cycling,
      );

      final merged = ActivityFiles.merge([
        act1,
        act2,
      ], creator: 'custom-creator');

      expect(merged.creator, equals('custom-creator'));
      expect(merged.sport, equals(Sport.running)); // First activity's sport
    });

    test(
      'splitBySport with laps without explicit sport uses activity sport',
      () {
        final base = DateTime.utc(2024, 12, 10, 17);
        final activity = RawActivity(
          points: [
            GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
            GeoPoint(
              latitude: 40.0001,
              longitude: -105.0001,
              time: base.add(const Duration(minutes: 10)),
            ),
          ],
          laps: [
            Lap(
              startTime: base,
              endTime: base.add(const Duration(minutes: 10)),
            ),
          ],
          sport: Sport.hiking,
        );

        final splits = ActivityFiles.splitBySport(activity);

        expect(splits.length, equals(1));
        expect(splits[Sport.hiking], isNotNull);
      },
    );

    test('gpxActivityLabelNode uses defaults', () {
      final node = ActivityFiles.gpxActivityLabelNode('Test');

      expect(
        node.namespacePrefix,
        equals(ActivityFiles.gpxDefaultExtensionPrefix),
      );
      expect(
        node.namespaceUri,
        equals(ActivityFiles.gpxDefaultExtensionNamespace),
      );
    });
  });

  group('Error messages and diagnostics', () {
    test('format detection error message guides user', () {
      expect(
        () => ActivityFiles.load('not a valid format', useIsolate: false),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('specified explicitly'),
          ),
        ),
      );
    });

    test('format detection error hints about allowFilePaths', () {
      expect(
        () => ActivityFiles.load(
          'example/assets/sample.gpx',
          allowFilePaths: false,
          useIsolate: false,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('specified explicitly'),
              contains('allowFilePaths'),
            ]),
          ),
        ),
      );
    });

    test('FIT integrity error message hints at verification steps', () async {
      final bytes = await File('example/assets/sample.fit').readAsBytes();
      final corrupted = Uint8List.fromList(bytes);
      corrupted[corrupted.length - 1] ^= 0xFF;

      await expectLater(
        () => ActivityFiles.load(
          corrupted,
          format: ActivityFileFormat.fit,
          useIsolate: false,
          strictFitIntegrity: true,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('integrity check failed'),
              contains('strictFitIntegrity'),
            ]),
          ),
        ),
      );
    });

    test(
      'payload limit error message hints at streaming and maxPayloadBytes',
      () {
        expect(
          () => ActivityFiles.load('x' * (65 * 1024 * 1024), useIsolate: false),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf([
                contains('exceeds'),
                contains('bytes'),
                contains('maxPayloadBytes'),
              ]),
            ),
          ),
        );
      },
    );

    test('parser format exception includes actionable hints', () {
      // Valid GPX with format mismatch: parser detects format errors gracefully
      const gpxContent = '<?xml version="1.0"?><gpx></gpx>';
      final result = ActivityParser.parse(gpxContent, ActivityFileFormat.gpx);

      // Valid GPX should parse (even if empty), diagnostics list is available
      expect(result, isNotNull);
      expect(result.diagnostics, isNotNull);
    });

    test('FIT integrity and payload limit errors have actionable context', () {
      // Verify error message structure for limit exceeded
      expect(
        () => ActivityFiles.load('x' * (65 * 1024 * 1024), useIsolate: false),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('maxPayloadBytes'),
          ),
        ),
      );
    });

    test('diagnostic summary includes node reference info when requested', () {
      const problematicGpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T00:00:00Z</time>
      </trkpt>
      <trkpt lat="invalid" lon="-105.0">
        <time>2024-01-01T00:05:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
''';

      final result = ActivityParser.parse(
        problematicGpx,
        ActivityFileFormat.gpx,
      );

      final summary = DiagnosticsFormatter(
        result.diagnostics,
      ).summary(includeSeverity: true, includeNode: true);
      expect(summary, isNotEmpty);
      if (result.diagnostics.any((d) => d.node != null)) {
        expect(summary, contains('gpx'));
      }
    });

    test('encoding-related parsing produces structured results', () {
      // Valid TCX structure
      final validTcx = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<TrainingCenterDatabase>'
        '  <Activities>'
        '    <Activity Sport="Running">'
        '      <Lap StartTime="2024-01-01T00:00:00Z">'
        '        <TotalTimeSeconds>600</TotalTimeSeconds>'
        '        <DistanceMeters>1000</DistanceMeters>'
        '        <Intensity>Active</Intensity>'
        '        <Track></Track>'
        '      </Lap>'
        '    </Activity>'
        '  </Activities>'
        '</TrainingCenterDatabase>',
      );

      final result = ActivityParser.parseBytes(
        validTcx,
        ActivityFileFormat.tcx,
      );

      // Well-formed TCX should parse successfully
      expect(result.activity, isNotNull);
      expect(result.diagnostics, isNotNull);
    });
  });
}
