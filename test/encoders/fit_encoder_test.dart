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

    test('a point timestamped on/after the FIT uint32 rollover (2106) does '
        'not throw, and clamps instead of wrapping to a garbage date', () {
      final farFuture = DateTime.utc(2106, 3, 1);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: farFuture),
          GeoPoint(
            latitude: 40.0005,
            longitude: -105.0005,
            time: farFuture.add(const Duration(seconds: 10)),
          ),
        ],
      );

      expect(
        () => ActivityEncoder.encode(activity, ActivityFileFormat.fit),
        returnsNormally,
      );

      final fitPayload = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
      );
      final parsed = ActivityParser.parseBytes(
        base64Decode(fitPayload),
        ActivityFileFormat.fit,
      );
      // Clamped to the max representable FIT timestamp, not wrapped back to
      // a small/negative delta that would decode as a date near 1989.
      expect(parsed.activity.points.first.time.year, greaterThan(2100));
    });

    test('a uint16 channel value of 65535 (the type sentinel minus 0) is '
        'clamped, not written as the "absent" sentinel itself', () {
      final start = DateTime.utc(2024, 1, 3, 8);
      final activity = RawActivity(
        points: [GeoPoint(latitude: 41.0, longitude: -106.0, time: start)],
        channels: {
          Channel.power: [Sample(time: start, value: 65535)],
        },
      );
      final fitPayload = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
      );
      final parsed = ActivityParser.parseBytes(
        base64Decode(fitPayload),
        ActivityFileFormat.fit,
      );
      final power = parsed.activity.channel(Channel.power);
      expect(power, hasLength(1));
      expect(power.first.value, equals(65534.0));
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

    test('keeps record order when many points share one timestamp', () {
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

    test('keeps a real point from a flattened second track even when it lands '
        'at the edge of the group, spatially far from its only neighbor', () {
      final base = DateTime.utc(2024, 1, 1, 10);
      final activity = RawActivity(
        // A single-point primary track (e.g. a lone waypoint-style
        // recording).
        points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: base)],
        // A geographically-unrelated 14-point secondary track that shares
        // the primary's degenerate timestamp (both defaulted to the same
        // base time, e.g. neither source had per-point time data).
        additionalTracks: [
          RawActivity(
            points: [
              for (var i = 0; i < 14; i++)
                GeoPoint(
                  latitude: 40.7 + i * 0.001,
                  longitude: -74.0,
                  time: base,
                ),
            ],
          ),
        ],
      );

      final exportResult = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.fit,
        normalize: false,
      );
      final parsed = ActivityParser.parseBytes(
        exportResult.asBytes(),
        ActivityFileFormat.fit,
      );

      expect(parsed.activity.points, hasLength(15));
      expect(
        parsed.activity.points.where((p) => p.longitude < -90),
        hasLength(1),
      );
      expect(
        parsed.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'fit.points.spatial_edge_anomaly',
          ),
        ),
      );
      expect(
        parsed.diagnostics,
        isNot(
          contains(
            isA<ParseDiagnostic>().having(
              (d) => d.code,
              'code',
              'fit.points.filtered_outliers',
            ),
          ),
        ),
      );
    });

    test('flags a spatial edge anomaly even when the surviving group is '
        'only 2 points, not just groups of 3+', () {
      // 9 mutually-isolated (>24h gap) single-point "noise" groups, followed
      // by a 2-point group whose two points are close in time but >100km
      // apart in space. None of the 10 groups exceeds this function's own
      // >10-points-to-keep threshold, so the survivor-selection fallback
      // (largest group) picks the 2-point group -- the smallest size that
      // can still have two points each be the other's "only neighbor".
      final base = DateTime.utc(2024, 1, 1);
      final activity = RawActivity(
        points: [
          for (var i = 0; i < 9; i++)
            GeoPoint(
              latitude: 10.0 + i,
              longitude: 10.0 + i,
              time: base.add(Duration(days: 2 * i)),
            ),
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: base.add(const Duration(days: 18)),
          ),
          GeoPoint(
            latitude: 41.0,
            longitude: 10.0,
            time: base.add(const Duration(days: 18, seconds: 10)),
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
      expect(
        parsed.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'fit.points.spatial_edge_anomaly',
          ),
        ),
      );
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

    test('clamps a lap whose inferred start lands after its own end '
        'instead of writing a negative duration', () {
      final bytes = buildFitFileWithOutOfOrderLapTimestamps(
        recordTimestamp: 1000,
        firstLapTimestamp: 1010,
        secondLapTimestamp: 1005,
      );
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      final fitEpoch = DateTime.utc(1989, 12, 31);
      expect(result.activity.laps, hasLength(2));
      final secondLap = result.activity.laps[1];
      expect(secondLap.startTime, equals(secondLap.endTime));
      expect(
        secondLap.endTime,
        equals(fitEpoch.add(const Duration(seconds: 1005))),
      );
      expect(
        result.diagnostics,
        contains(
          isA<ParseDiagnostic>().having(
            (d) => d.code,
            'code',
            'fit.lap.negative_duration_clamped',
          ),
        ),
      );
    });
  });
}
