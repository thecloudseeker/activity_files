// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for FIT encoder.
///
/// Tests specific regressions and edge cases in FIT binary encoding.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

void main() {
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
      final bytes = buildFitFileWithDeveloperData();
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
      expect(result.activity.points, isNotEmpty);
    });

    test('clamps pre-FIT-epoch timestamps instead of wrapping around', () {
      final start = DateTime.utc(1901, 12, 13);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: start),
          GeoPoint(
            latitude: 40.0005,
            longitude: -105.0005,
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
      expect(parsed.activity.points, hasLength(2));
      for (final point in parsed.activity.points) {
        expect(point.time, equals(DateTime.utc(1989, 12, 31)));
      }
    });

    test('keeps record order when many points share one timestamp '
        '(regression: unstable sort in outlier filtering)', () {
      final time = DateTime.utc(2024, 1, 1, 6);
      final activity = RawActivity(
        points: [
          for (var i = 0; i < 20; i++)
            GeoPoint(
              latitude: 40.0 + i * 0.0001,
              longitude: -105.0,
              time: time,
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
      expect(parsed.activity.points, hasLength(activity.points.length));
      for (var i = 0; i < activity.points.length; i++) {
        expect(
          parsed.activity.points[i].latitude,
          closeTo(activity.points[i].latitude, 1e-5),
        );
      }
    });

    test('keeps every point from multiple recording sessions flattened into '
        'one file, days apart', () {
      DateTime dayStart(int day) => DateTime.utc(2024, 1, day, 8);
      final activity = RawActivity(
        points: [
          for (var i = 0; i < 20; i++)
            GeoPoint(
              latitude: 40.0 + i * 0.0001,
              longitude: -105.0,
              time: dayStart(1).add(Duration(seconds: i)),
            ),
          for (var i = 0; i < 20; i++)
            GeoPoint(
              latitude: 41.0 + i * 0.0001,
              longitude: -106.0,
              time: dayStart(5).add(Duration(seconds: i)),
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
      expect(parsed.activity.points, hasLength(40));
    });

    test('still filters a lone stray point with a wildly wrong timestamp', () {
      final start = DateTime.utc(2024, 1, 1, 8);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 10.0, longitude: 10.0, time: DateTime.utc(1995)),
          for (var i = 0; i < 20; i++)
            GeoPoint(
              latitude: 40.0 + i * 0.0001,
              longitude: -105.0,
              time: start.add(Duration(seconds: i)),
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
      expect(parsed.activity.points, hasLength(20));
      expect(
        parsed.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'fit.points.filtered_outliers',
          ),
        ),
      );
    });

    test('keeps a lap whose message omits start_time/total_elapsed_time, '
        'inferring start from the first point', () {
      final bytes = buildFitFileWithLapMissingStartTime(
        recordTimestamp: 1000,
        lapTimestamp: 1010,
      );
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      final fitEpoch = DateTime.utc(1989, 12, 31);
      expect(result.activity.laps, hasLength(1));
      final lap = result.activity.laps.single;
      expect(
        lap.startTime,
        equals(fitEpoch.add(const Duration(seconds: 1000))),
      );
      expect(lap.endTime, equals(fitEpoch.add(const Duration(seconds: 1010))));
      expect(
        result.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'fit.lap.start_time_inferred',
          ),
        ),
      );
    });
  });
}
