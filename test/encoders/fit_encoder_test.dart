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
  });
}
