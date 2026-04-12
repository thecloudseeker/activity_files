// SPDX-License-Identifier: BSD-3-Clause
/// Roundtrip tests for CSV and GeoJSON encoders/parsers.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/builders.dart';

void main() {
  group('CSV roundtrip', () {
    test('encode -> parse preserves points and channels', () {
      final activity = buildSampleActivity();

      final csv = ActivityFiles.exportToCsv(activity);
      final result = ActivityFiles.importFromCsv(csv);

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
    test('encode -> parse preserves points and sport', () {
      final activity = buildSampleActivity();

      final geojson = ActivityFiles.exportToGeojson(activity);
      final result = ActivityFiles.importFromGeojson(geojson);

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

    test('point FeatureCollection roundtrip preserves channels', () {
      final activity = buildSampleActivity();

      final geojson = ActivityFiles.exportToGeojsonPoints(
        activity,
        includeChannels: true,
      );
      final result = ActivityFiles.importFromGeojson(geojson);

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
  });
}
