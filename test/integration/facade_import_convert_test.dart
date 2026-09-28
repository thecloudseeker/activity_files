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
      expect(stats.validationDuration, isNotNull);
    });

    test('multi-track GPX to TCX flattens all tracks and flags it', () async {
      const multiTrackGpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Track 1</name>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0"><time>2024-01-01T10:00:00Z</time></trkpt>
      <trkpt lat="40.001" lon="-105.001"><time>2024-01-01T10:00:10Z</time></trkpt>
    </trkseg>
  </trk>
  <trk>
    <name>Track 2</name>
    <trkseg>
      <trkpt lat="51.0" lon="0.5"><time>2024-01-02T08:00:00Z</time></trkpt>
      <trkpt lat="51.001" lon="0.501"><time>2024-01-02T08:00:10Z</time></trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final conversion = await ActivityFiles.convert(
        source: multiTrackGpx,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
      );

      // Points from BOTH tracks must survive the conversion.
      expect(conversion.encoded, contains('40.001'));
      expect(conversion.encoded, contains('51.001'));
      // The structural loss is reported as an info diagnostic.
      expect(
        conversion.diagnostics.any(
          (d) => d.code == 'lossy.multi_track_flattened',
        ),
        isTrue,
        reason: 'Expected a lossy.multi_track_flattened diagnostic',
      );
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

    test('convert runs validation by default', () async {
      final conversion = await ActivityFiles.convert(
        source: sampleGpx,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
      );
      expect(conversion.validation, isNotNull);
      expect(conversion.processingStats.validationDuration, isNotNull);
    });

    test('convert can skip validation when explicitly disabled', () async {
      final conversion = await ActivityFiles.convert(
        source: sampleGpx,
        to: ActivityFileFormat.tcx,
        runValidation: false,
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

    test('raising maxPayloadBytes above the 64MB default actually raises '
        'the limit for the returned payload too, not just parsing', () async {
      const gpx =
          '<?xml version="1.0"?>'
          '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
          '<trk><trkseg>'
          '<trkpt lat="40.0" lon="-105.0"><time>2024-01-01T10:00:00Z</time></trkpt>'
          '</trkseg></trk></gpx>';
      // Padded past the 64MB default so the bug (second materialize() call
      // hardcoded to the default instead of the caller's larger limit)
      // would throw and silently empty .payload despite a successful parse.
      final padded = utf8.encode(
        gpx.replaceFirst('</gpx>', '<!--${'x' * (65 * 1024 * 1024)}--></gpx>'),
      );
      Stream<List<int>> chunks() async* {
        const chunkSize = 1024 * 1024;
        for (var i = 0; i < padded.length; i += chunkSize) {
          yield padded.sublist(i, (i + chunkSize).clamp(0, padded.length));
        }
      }

      final result = await ActivityFiles.load(
        chunks(),
        format: ActivityFileFormat.gpx,
        useIsolate: false,
        maxPayloadBytes: 70 * 1024 * 1024,
      );

      expect(result.activity.points, hasLength(1));
      expect(result.bytesPayload, isNotNull);
      expect(result.bytesPayload!.length, equals(padded.length));
      expect(
        result.diagnostics.any((d) => d.code == 'activity.payload.unavailable'),
        isFalse,
      );
    });

    group('seeded diagnostics', () {
      final seeded = ParseDiagnostic(
        severity: ParseSeverity.info,
        code: 'caller.upstream_note',
        message: 'Carried in by the caller.',
      );

      test('convert() merges caller diagnostics after its own', () async {
        final result = await ActivityFiles.convert(
          source: sampleGpx,
          to: ActivityFileFormat.tcx,
          useIsolate: false,
          diagnostics: [seeded],
        );
        final codes = result.diagnostics.map((d) => d.code).toList();
        expect(codes, contains('caller.upstream_note'));
        expect(codes.last, equals('caller.upstream_note'));
      });

      test(
        'convert() seeding adds exactly one entry, disturbing nothing else',
        () async {
          final plain = await ActivityFiles.convert(
            source: sampleGpx,
            to: ActivityFileFormat.tcx,
            useIsolate: false,
          );
          final seededRun = await ActivityFiles.convert(
            source: sampleGpx,
            to: ActivityFileFormat.tcx,
            useIsolate: false,
            diagnostics: [seeded],
          );
          expect(
            seededRun.diagnostics.length,
            equals(plain.diagnostics.length + 1),
          );
          expect(
            seededRun.diagnostics
                .map((d) => d.code)
                .where((c) => c != 'caller.upstream_note'),
            equals(plain.diagnostics.map((d) => d.code)),
          );
        },
      );

      test('convertStream() merges caller diagnostics too', () async {
        final result = await ActivityFiles.convertStream(
          source: Stream.value(utf8.encode(sampleGpx)),
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.tcx,
          parseInIsolate: false,
          diagnostics: [seeded],
        );
        expect(
          result.diagnostics.map((d) => d.code),
          contains('caller.upstream_note'),
        );
      });
    });

    group('exportToCsvMultiple has no exact replacement', () {
      DateTime t(int s) =>
          DateTime.utc(2024, 1, 1, 10).add(Duration(seconds: s));
      GeoPoint pt(int s, double lat) =>
          GeoPoint(latitude: lat, longitude: 8.0, time: t(s));

      test(
        'merge() drops a point when timestamps collide across activities',
        () {
          // Both activities carry a point at +20s; they are distinct samples.
          final a = RawActivity(
            points: [pt(0, 47.0), pt(10, 47.1), pt(20, 47.2)],
            sport: Sport.running,
          );
          final b = RawActivity(
            points: [pt(5, 48.0), pt(20, 48.2), pt(30, 48.3)],
            sport: Sport.cycling,
          );

          // ignore: deprecated_member_use_from_same_package
          final concatenated = ActivityFiles.exportToCsvMultiple([a, b]);
          final mergedCsv = ActivityFiles.export(
            activity: RawEditor.merge([a, b]),
            to: ActivityFileFormat.csv,
          ).encoded;

          int rows(String csv) => csv.trim().split('\n').length - 1;

          // Concatenation keeps every source row; merging does not.
          expect(rows(concatenated), equals(6));
          expect(rows(mergedCsv), equals(5));
          expect(rows(mergedCsv), lessThan(rows(concatenated)));
        },
      );
    });
  });
}
