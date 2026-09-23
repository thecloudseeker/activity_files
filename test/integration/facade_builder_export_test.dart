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

void main() {
  const encoderOptions = EncoderOptions(
    defaultMaxDelta: Duration(seconds: 3),
    precisionLatLon: 6,
    precisionEle: 2,
  );

  group('Facade convenience (continued)', () {
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

    test('export to FIT reports lossy.pre_fit_epoch_timestamps_clamped for '
        'pre-1990 timestamps', () {
      final start = DateTime.utc(1970);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: start),
          GeoPoint(
            latitude: 40.001,
            longitude: -105.001,
            time: start.add(const Duration(seconds: 10)),
          ),
        ],
      );

      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.fit,
      );

      expect(
        result.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'lossy.pre_fit_epoch_timestamps_clamped',
          ),
        ),
      );
    });

    test('export flattens additionalTracks before ordering, so a second '
        'track sharing timestamps with the primary keeps every point', () {
      final base = DateTime.utc(2024, 12, 10, 12);
      RawActivity track(double latOffset) => RawActivity(
        points: [
          for (var i = 0; i < 5; i++)
            GeoPoint(
              latitude: 40.0 + latOffset + i * 0.001,
              longitude: -105.0,
              time: base,
            ),
        ],
      );
      final activity = track(0).copyWith(additionalTracks: [track(10)]);

      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.tcx,
        normalize: false,
      );

      expect(result.activity.points, hasLength(10));
      expect(
        RegExp('<Trackpoint>').allMatches(result.asString()).length,
        equals(10),
      );
      expect(
        result.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'lossy.multi_track_flattened',
          ),
        ),
      );
    });

    test('export to GPX normalizes additionalTracks too, not just the '
        'primary track (GPX keeps multi-track sources unflattened)', () {
      final base = DateTime.utc(2024, 12, 10, 12);
      final primary = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.001,
            longitude: -105.001,
            time: base.add(const Duration(seconds: 1)),
          ),
        ],
      );
      final secondaryWithInvalidPoint = RawActivity(
        points: [
          GeoPoint(latitude: 41.0, longitude: -106.0, time: base),
          GeoPoint(
            latitude: 0.0,
            longitude: 0.0,
            time: base.add(const Duration(seconds: 1)),
          ),
          GeoPoint(
            latitude: 41.002,
            longitude: -106.002,
            time: base.add(const Duration(seconds: 2)),
          ),
        ],
      );
      final activity = primary.copyWith(
        additionalTracks: [secondaryWithInvalidPoint],
      );

      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.gpx,
      );

      expect(result.activity.additionalTracks.single.points, hasLength(2));
      expect(RegExp('<trkpt').allMatches(result.asString()).length, equals(4));
      expect(
        result.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'repaired.sentinel_coords_removed',
          ),
        ),
      );
    });
  });
}
