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
import '../helpers/fit_helpers.dart';

void main() {
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

    test('merge supports custom creator and inherits first activity sport', () {
      final base = DateTime.utc(2024, 12, 1, 9);
      final a1 = ActivityFiles.builder()
        ..creator = 'device1'
        ..sport = Sport.running
        ..addPoint(latitude: 40.0, longitude: -105.0, time: base);
      final a2 = ActivityFiles.builder()
        ..creator = 'device2'
        ..sport = Sport.cycling
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
      expect(merged.sport, equals(Sport.running)); // First activity's sport
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
          avgHeartRate: 130,
          event: 1,
        ),
        Lap(
          startTime: base.add(const Duration(minutes: 15)),
          endTime: base.add(const Duration(minutes: 20)),
          sport: Sport.cycling,
          name: 'Bike',
          avgPower: 260,
          eventType: 2,
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
      expect(swim.laps.first.avgHeartRate, equals(130));
      expect(swim.laps.first.event, equals(1));
      expect(swim.channel(Channel.heartRate).length, equals(2));

      final bike = splits[Sport.cycling]!;
      expect(bike.points.length, equals(2));
      expect(
        bike.points.first.time,
        equals(base.add(const Duration(minutes: 15))),
      );
      expect(bike.laps.length, equals(1));
      expect(bike.laps.first.name, equals('Bike'));
      expect(bike.laps.first.avgPower, equals(260));
      expect(bike.laps.first.eventType, equals(2));
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
    test('detectFormat identifies CSV from string content', () {
      const csv =
          'timestamp,latitude,longitude\n2025-01-01T10:00:00Z,52.52,13.405';
      final format = ActivityFiles.detectFormat(csv);
      expect(format, equals(ActivityFileFormat.csv));
    });

    test('detectFormat identifies GeoJSON from string content', () {
      const geojson =
          '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[13.405,52.52]},"properties":{"timestamp":"2025-01-01T10:00:00Z"}}]}';
      final format = ActivityFiles.detectFormat(geojson);
      expect(format, equals(ActivityFileFormat.geojson));
    });

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

    test('a UTF-32 document keeps characters outside the BMP', () async {
      // U+1F600 encodes as 00 F6 01 00 in UTF-32LE; read as UTF-16LE those
      // bytes are 0xF600 and 0x0001 rather than a surrogate pair, so the
      // four-byte BOM has to win over the two-byte one for it to survive.
      const label = 'Run \u{1F600} \u{4E2D}\u{6587}';
      final gpx =
          '<?xml version="1.0"?><gpx version="1.1"><metadata>'
          '<name>$label</name></metadata><trk><trkseg>'
          '<trkpt lat="47.0" lon="11.0"><time>2026-01-01T00:00:00Z</time>'
          '</trkpt></trkseg></trk></gpx>';

      Uint8List asUtf32(Endian endian) {
        final codePoints = gpx.runes.toList();
        final bytes = Uint8List((codePoints.length + 1) * 4);
        final view = bytes.buffer.asByteData();
        view.setUint32(0, 0xFEFF, endian);
        var offset = 4;
        for (final codePoint in codePoints) {
          view.setUint32(offset, codePoint, endian);
          offset += 4;
        }
        return bytes;
      }

      for (final endian in [Endian.little, Endian.big]) {
        final bytes = asUtf32(endian);
        expect(
          ActivityFiles.detectFormat(bytes),
          equals(ActivityFileFormat.gpx),
          reason: 'detection failed for $endian',
        );
        final result = await ActivityFiles.import(bytes, useIsolate: false);
        expect(
          result.activity.gpxMetadataName,
          equals(label),
          reason: 'metadata name lost characters for $endian',
        );
        expect(result.activity.points, hasLength(1));
      }
    });

    test('a UTF-16 stream chunk that is a view into a larger buffer '
        'decodes from the view offset', () async {
      const gpx =
          '<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>'
          '<trkpt lat="47.0" lon="11.0"><time>2026-01-01T00:00:00Z</time>'
          '</trkpt></trkseg></trk></gpx>';
      const leading = 6;
      final backing = Uint8List(leading + 2 + gpx.length * 2);
      final data = ByteData.sublistView(backing, leading);
      data.setUint16(0, 0xFEFF, Endian.little);
      for (var i = 0; i < gpx.length; i++) {
        data.setUint16(2 + i * 2, gpx.codeUnitAt(i), Endian.little);
      }
      final chunk = Uint8List.sublistView(backing, leading);

      final result = await ActivityFiles.import(
        Stream.value(chunk),
        format: ActivityFileFormat.gpx,
        useIsolate: false,
      );

      expect(result.hasErrors, isFalse);
      expect(result.activity.points, hasLength(1));
    });

    test('load infers CSV format from inline content', () async {
      const csv =
          'timestamp,latitude,longitude,heart_rate\n2025-01-01T10:00:00Z,52.52,13.405,140';
      final result = await ActivityFiles.load(csv, useIsolate: false);
      expect(result.format, equals(ActivityFileFormat.csv));
      expect(result.activity.points.length, equals(1));
      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
      );
    });

    test('load infers GeoJSON format from inline content', () async {
      const geojson =
          '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[13.405,52.52]},"properties":{"timestamp":"2025-01-01T10:00:00Z"}}]}';
      final result = await ActivityFiles.load(geojson, useIsolate: false);
      expect(result.format, equals(ActivityFileFormat.geojson));
      expect(result.activity.points.length, equals(1));
      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
      );
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

    test(
      'load with strict fitCorruptionHandling rejects corrupted FIT files',
      () async {
        final bytes = await File('example/assets/sample.fit').readAsBytes();
        final corrupted = Uint8List.fromList(bytes);
        corrupted[corrupted.length - 1] ^= 0xFF;

        await expectLater(
          () => ActivityFiles.load(
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
      'load with bestEffort fitCorruptionHandling keeps parse result',
      () async {
        final bytes = await File('example/assets/sample.fit').readAsBytes();
        final corrupted = Uint8List.fromList(bytes);
        corrupted[corrupted.length - 1] ^= 0xFF;

        final result = await ActivityFiles.load(
          corrupted,
          format: ActivityFileFormat.fit,
          useIsolate: false,
          fitCorruptionHandling: FitCorruptionHandling.bestEffort,
        );

        expect(result.hasErrors, isTrue);
        expect(result.activity.points, isNotEmpty);
      },
    );

    test('convert applies auto-fix for invalid gps, drift, and gaps', () async {
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
        channels: {
          Channel.heartRate: [
            Sample(time: base.subtract(const Duration(minutes: 1)), value: 140),
            Sample(time: base.add(const Duration(minutes: 11)), value: 142),
          ],
        },
      );

      final source = ActivityEncoder.encode(activity, ActivityFileFormat.gpx);
      final result = await ActivityFiles.convert(
        source: source,
        from: ActivityFileFormat.gpx,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
        autoFix: const ActivityAutoFixOptions(
          fixInvalidGps: true,
          fixChannelDrift: true,
          fixDistanceDrift: true,
          fixTimestampGaps: true,
          gapThreshold: Duration(minutes: 3),
          maxInsertedGapPoints: 20,
        ),
      );

      expect(result.activity.points.any((p) => p.latitude.abs() > 90), isFalse);
      expect(result.activity.channel(Channel.heartRate), isEmpty);
      expect(result.activity.channel(Channel.distance), isNotEmpty);
      expect(result.activity.points.length, greaterThan(2));
      expect(
        result.diagnostics.any((d) => d.code.startsWith('autofix.')),
        isTrue,
      );
    });

    test('convert auto-fix can auto-generate laps by distance', () async {
      final base = DateTime.utc(2025, 1, 2, 8);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0000, longitude: -105.0000, time: base),
          GeoPoint(
            latitude: 40.0090,
            longitude: -105.0000,
            time: base.add(const Duration(minutes: 5)),
          ),
          GeoPoint(
            latitude: 40.0180,
            longitude: -105.0000,
            time: base.add(const Duration(minutes: 10)),
          ),
          GeoPoint(
            latitude: 40.0240,
            longitude: -105.0000,
            time: base.add(const Duration(minutes: 15)),
          ),
        ],
      );

      final source = ActivityEncoder.encode(activity, ActivityFileFormat.gpx);
      final result = await ActivityFiles.convert(
        source: source,
        from: ActivityFileFormat.gpx,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
        autoFix: const ActivityAutoFixOptions(
          fixInvalidGps: false,
          fixChannelDrift: false,
          fixDistanceDrift: false,
          fixTimestampGaps: false,
          autoLapByDistance: true,
          autoLapDistanceMeters: 100,
        ),
      );

      expect(result.activity.laps.length, greaterThanOrEqualTo(2));
      expect(
        result.diagnostics.any((d) => d.code == 'autofix.laps.auto_generated'),
        isTrue,
      );
    });

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
}
