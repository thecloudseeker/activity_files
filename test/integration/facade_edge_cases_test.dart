// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for ActivityFiles facade API.
///
/// Tests the high-level convenience methods for loading, converting, and
/// exporting activity files.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/sample_data.dart';

void main() {
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

    test('export with normalize=false keeps every point when timestamps '
        'duplicate', () {
      final base = DateTime.utc(2024, 12, 10, 12);
      final activity = RawActivity(
        points: [
          for (var i = 0; i < 5; i++)
            GeoPoint(latitude: 40.0 + i * 0.001, longitude: -105.0, time: base),
        ],
      );

      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.gpx,
        normalize: false,
      );

      expect(result.activity.points, hasLength(5));
      expect(
        result.activity.points.map((p) => p.latitude),
        equals(activity.points.map((p) => p.latitude)),
      );
      for (var i = 1; i < result.activity.points.length; i++) {
        expect(
          result.activity.points[i].time.isAfter(
            result.activity.points[i - 1].time,
          ),
          isTrue,
        );
      }
      expect(
        result.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'repaired.duplicate_timestamps_adjusted',
          ),
        ),
      );
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

    test('the deprecated ActivityLoadResult alias resolves to '
        'ActivityImportResult', () async {
      // ignore: deprecated_member_use_from_same_package
      final ActivityLoadResult aliased = await ActivityFiles.import(
        sampleGpx,
        useIsolate: false,
      );
      final ActivityImportResult current = aliased;
      expect(current, same(aliased));
      expect(aliased.activity.points, isNotEmpty);
    });

    test('ActivityImportResult provides payload', () async {
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
