// SPDX-License-Identifier: BSD-3-Clause
/// Roundtrip tests for CSV and GeoJSON encoders/parsers.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/builders.dart';

void main() {
  group('CSV roundtrip', () {
    test('encode -> parse preserves points and channels', () async {
      final activity = buildSampleActivity();

      final csv = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.csv,
      ).encoded;
      final result = await ActivityFiles.import(
        csv,
        format: ActivityFileFormat.csv,
        useIsolate: false,
      );

      final errorDiagnostics = result.diagnostics
          .where((d) => d.severity == ParseSeverity.error)
          .toList();
      expect(
        errorDiagnostics,
        isEmpty,
        reason:
            'CSV diagnostics: ${errorDiagnostics.map((d) => d.code).toList()}\n'
            '${errorDiagnostics.map((d) => d.message).toList()}',
      );
      expect(result.activity.points.length, activity.points.length);
      expect(result.activity.sport, equals(activity.sport));

      final hr = result.activity.channel(Channel.heartRate);
      expect(hr.length, activity.channel(Channel.heartRate).length);
      expect(hr.first.value, activity.channel(Channel.heartRate).first.value);
    });
  });

  group('GeoJSON roundtrip', () {
    test('encode -> parse preserves points and sport', () async {
      final activity = buildSampleActivity();

      final geojson = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.geojson,
      ).encoded;
      final result = await ActivityFiles.import(
        geojson,
        format: ActivityFileFormat.geojson,
        useIsolate: false,
      );

      final errorDiagnostics = result.diagnostics
          .where((d) => d.severity == ParseSeverity.error)
          .toList();
      expect(
        errorDiagnostics,
        isEmpty,
        reason:
            'GeoJSON diagnostics: ${errorDiagnostics.map((d) => d.code).toList()}\n'
            '${errorDiagnostics.map((d) => d.message).toList()}',
      );
      expect(result.activity.points.length, activity.points.length);
      expect(result.activity.sport, equals(activity.sport));
    });

    test('point FeatureCollection roundtrip preserves channels', () async {
      final activity = buildSampleActivity();

      final geojson = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.geojson,
        options: const EncoderOptions(
          geojsonGeometry: GeojsonGeometry.points,
          geojsonIncludeChannels: true,
        ),
      ).encoded;
      final result = await ActivityFiles.import(
        geojson,
        format: ActivityFileFormat.geojson,
        useIsolate: false,
      );

      final errorDiagnostics = result.diagnostics
          .where((d) => d.severity == ParseSeverity.error)
          .toList();
      expect(
        errorDiagnostics,
        isEmpty,
        reason:
            'GeoJSON diagnostics: ${errorDiagnostics.map((d) => d.code).toList()}\n'
            '${errorDiagnostics.map((d) => d.message).toList()}',
      );
      expect(result.activity.points.length, activity.points.length);

      final hr = result.activity.channel(Channel.heartRate);
      expect(hr.length, activity.channel(Channel.heartRate).length);
      expect(hr.first.value, activity.channel(Channel.heartRate).first.value);
    });

    test('missing timestamp uses deterministic UTC epoch fallback', () async {
      const geojson =
          '{"type":"Feature","geometry":{"type":"Point","coordinates":[13.405,52.52]},"properties":{"heart_rate":140}}';

      final result = await ActivityFiles.import(
        geojson,
        format: ActivityFileFormat.geojson,
        useIsolate: false,
      );

      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
      );
      expect(result.activity.points, hasLength(1));
      expect(
        result.activity.points.first.time,
        equals(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)),
      );
    });
  });
}
