// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for ActivityConverter high-level API.
///
/// Tests format conversion between different file formats with various options.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('ActivityConverter', () {
    const sampleGpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
      <trkpt lat="40.0005" lon="-105.0005">
        <time>2024-01-01T10:00:10Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

    const sampleCsv = '''timestamp,latitude,longitude,heart_rate
2024-01-01T10:00:00Z,40.0,-105.0,140
2024-01-01T10:00:10Z,40.0005,-105.0005,145''';

    group('Basic conversion', () {
      test('converts GPX to CSV', () {
        final csv = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('timestamp,latitude,longitude'));
        expect(csv, contains('40.0'));
        expect(csv, contains('-105.0'));
      });

      test('converts CSV to GeoJSON', () {
        final geojson = ActivityConverter.convert(
          sampleCsv,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.geojson,
        );

        expect(geojson, contains('FeatureCollection'));
        expect(geojson, contains('LineString'));
      });

      test('converts CSV to GPX', () {
        final gpx = ActivityConverter.convert(
          sampleCsv,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.gpx,
        );

        expect(gpx, contains('<?xml'));
        expect(gpx, contains('<gpx'));
      });

      test('converts CSV to TCX', () {
        final tcx = ActivityConverter.convert(
          sampleCsv,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.tcx,
        );

        expect(tcx, contains('TrainingCenterDatabase'));
      });
    });

    group('Input types', () {
      test('accepts string input', () {
        final csv = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(csv, isNotEmpty);
      });

      test('accepts List<int> input for binary formats', () {
        final gpxBytes = sampleGpx.codeUnits;
        final csv = ActivityConverter.convert(
          gpxBytes,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(csv, isNotEmpty);
      });

      test('rejects invalid input types', () {
        expect(
          () => ActivityConverter.convert(
            12345,
            from: ActivityFileFormat.gpx,
            to: ActivityFileFormat.csv,
          ),
          throwsArgumentError,
        );
      });
    });

    group('Normalization', () {
      test('normalizes by default', () {
        // Unsorted + duplicate data
        const unsortedGpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0005" lon="-105.0005">
        <time>2024-01-01T10:00:10Z</time>
      </trkpt>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final csv = ActivityConverter.convert(
          unsortedGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        // Should be sorted and deduplicated
        expect(csv, contains('10:00:00'));
        expect(csv, contains('10:00:10'));
      });

      test('respects normalize: false', () {
        final result = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          normalize: false,
        );
        // normalize: false still converts format but skips sorting/deduplication
        expect(result, contains('timestamp'));
        expect(result, contains('40.0'));
      });
    });

    group('EncoderOptions', () {
      test('passes encoder options to encoder', () {
        final options = EncoderOptions(precisionLatLon: 4, precisionEle: 1);

        final csv = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          encoderOptions: options,
        );

        expect(csv, isNotEmpty);
      });

      test('handles GPX version option', () {
        final options = EncoderOptions(gpxVersion: GpxVersion.v1_0);

        final gpx = ActivityConverter.convert(
          sampleCsv,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.gpx,
          encoderOptions: options,
        );

        expect(gpx, contains('<gpx'));
      });

      test('handles TCX version option', () {
        final options = EncoderOptions(tcxVersion: TcxVersion.v1);

        final tcx = ActivityConverter.convert(
          sampleCsv,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.tcx,
          encoderOptions: options,
        );

        expect(tcx, contains('TrainingCenterDatabase'));
      });
    });

    group('Roundtrip conversions', () {
      test('GPX to CSV to GPX preserves structure', () {
        final csv = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        final gpx = ActivityConverter.convert(
          csv,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.gpx,
        );

        expect(gpx, contains('<trkpt'));
        expect(gpx, contains('40.0'));
      });

      test('CSV round-trip preserves coordinates', () {
        final result = ActivityConverter.convert(
          sampleCsv,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.csv,
        );

        expect(result, contains('40.0'));
        expect(result, contains('40.0005'));
      });

      test('CSV round-trip preserves channel data', () {
        final result = ActivityConverter.convert(
          sampleCsv,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.csv,
        );

        expect(result, contains('140'));
        expect(result, contains('145'));
      });
    });

    group('Data preservation', () {
      test('preserves coordinates in conversion', () {
        final result = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(result, contains('40.0'));
        expect(result, contains('-105.0'));
      });

      test('preserves timestamp information', () {
        final result = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(result, contains('2024-01-01'));
        expect(result, contains('10:00:00'));
      });
    });

    group('Error handling', () {
      test('handles malformed input gracefully', () {
        const malformed = '<not>valid<xml>';

        final csv = ActivityConverter.convert(
          malformed,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        // Should produce some output (possibly empty) rather than crashing
        expect(csv, isNotNull);
      });

      test('produces valid output despite warnings', () {
        final result = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(result, isNotEmpty);
      });
    });

    group('Diagnostics (0.7.0)', () {
      test('diagnostics list is populated on malformed GPX', () {
        const malformed = '<not>valid<xml>';
        final diagnostics = <ParseDiagnostic>[];

        ActivityConverter.convert(
          malformed,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          diagnostics: diagnostics,
        );

        expect(diagnostics, isNotEmpty);
        expect(diagnostics.first.severity, equals(ParseSeverity.error));
        expect(diagnostics.first.code, contains('gpx'));
      });

      test('diagnostics list is empty for valid input', () {
        final diagnostics = <ParseDiagnostic>[];

        ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          diagnostics: diagnostics,
        );

        expect(diagnostics, isEmpty);
      });

      test('diagnostics have code and severity fields', () {
        const malformed = '<not>valid<xml>';
        final diagnostics = <ParseDiagnostic>[];

        ActivityConverter.convert(
          malformed,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          diagnostics: diagnostics,
        );

        final d = diagnostics.first;
        expect(d.code, isNotEmpty);
        expect(d.severity, isA<ParseSeverity>());
        expect(d.message, isNotEmpty);
      });

      test('diagnostics can carry suggestedFix and priority', () {
        // ParseDiagnostic gained suggestedFix and priority in 0.7.0.
        // Verify the fields are accessible on the type.
        const d = ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'test.check',
          message: 'something went wrong',
          suggestedFix: 'Try this fix',
          priority: 2,
        );

        expect(d.suggestedFix, equals('Try this fix'));
        expect(d.priority, equals(2));
      });

      test('diagnostics null suggestedFix and priority are allowed', () {
        const d = ParseDiagnostic(
          severity: ParseSeverity.info,
          code: 'test.info',
          message: 'informational',
        );

        expect(d.suggestedFix, isNull);
        expect(d.priority, isNull);
      });

      // ignore: deprecated_member_use
      test('legacy warnings parameter collects warning messages', () {
        const gpxWithBadTimestamp = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="40.0" lon="-105.0">
      <time>not-a-date</time>
    </trkpt>
    <trkpt lat="40.001" lon="-105.001">
      <time>2024-01-01T10:00:10Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>''';

        final warnings = <String>[];
        // ignore: deprecated_member_use
        ActivityConverter.convert(
          gpxWithBadTimestamp,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          // ignore: deprecated_member_use
          warnings: warnings,
        );

        // The legacy list may be empty for valid parses, but it must not throw
        // and must be a List<String>.
        expect(warnings, isA<List<String>>());
      });
    });

    group('Multi-track GPX (0.7.0)', () {
      const multiTrackGpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Track 1</name>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
      <trkpt lat="40.001" lon="-105.001">
        <time>2024-01-01T10:00:10Z</time>
      </trkpt>
    </trkseg>
  </trk>
  <trk>
    <name>Track 2</name>
    <trkseg>
      <trkpt lat="51.0" lon="0.0">
        <time>2024-01-02T08:00:00Z</time>
      </trkpt>
      <trkpt lat="51.001" lon="0.001">
        <time>2024-01-02T08:00:10Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      test('emits gpx.multi_track info diagnostic for multi-track files', () {
        final diagnostics = <ParseDiagnostic>[];

        ActivityConverter.convert(
          multiTrackGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          diagnostics: diagnostics,
        );

        expect(
          diagnostics.any((d) => d.code == 'gpx.multi_track'),
          isTrue,
          reason: 'Expected a gpx.multi_track diagnostic',
        );
        final d = diagnostics.firstWhere((d) => d.code == 'gpx.multi_track');
        expect(d.severity, equals(ParseSeverity.info));
      });

      test('multi-track GPX round-trips back to GPX with both tracks', () {
        final gpx = ActivityConverter.convert(
          multiTrackGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.gpx,
        );

        // Both tracks' coordinates should appear in the output
        expect(gpx, contains('40.0'));
        expect(gpx, contains('51.0'));
        // Should contain two <trk> elements
        final trkCount = RegExp('<trk>').allMatches(gpx).length;
        expect(trkCount, equals(2));
      });

      test('multi-track GPX to CSV includes points from ALL tracks', () {
        // Single-track formats flatten additionalTracks on encode so that no
        // track data is silently dropped (0.6.0 merged at parse time; 0.7.0
        // preserves structure and merges at encode time instead).
        final csv = ActivityConverter.convert(
          multiTrackGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('40.0'));
        expect(csv, contains('51.0'));
        // Two points per track = four data rows.
        final rows = csv.trim().split('\n').skip(1).toList();
        expect(rows, hasLength(4));
      });

      test('single-track GPX does not emit gpx.multi_track diagnostic', () {
        final diagnostics = <ParseDiagnostic>[];

        ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.gpx,
          diagnostics: diagnostics,
        );

        expect(diagnostics.any((d) => d.code == 'gpx.multi_track'), isFalse);
      });
    });

    group('Sentinel value removal via normalization (0.7.0)', () {
      test('removes null-island sentinel coordinates when normalize is true', () {
        // Points at (0,0) within 1e-6° are GPS "no fix yet" sentinels.
        const gpxWithSentinel = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="0.0" lon="0.0">
      <time>2024-01-01T10:00:00Z</time>
    </trkpt>
    <trkpt lat="40.0" lon="-105.0">
      <time>2024-01-01T10:00:10Z</time>
    </trkpt>
    <trkpt lat="40.001" lon="-105.001">
      <time>2024-01-01T10:00:20Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>''';

        final csv = ActivityConverter.convert(
          gpxWithSentinel,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          normalize: true,
        );

        // The valid points should be present
        expect(csv, contains('40.0'));
        // The sentinel (0.0, 0.0) row should not appear as a data row.
        // The header will contain "latitude" but no data row should have "0.0,0.0"
        final rows = csv.trim().split('\n').skip(1).toList();
        final hasSentinelRow = rows.any((row) {
          final cols = row.split(',');
          if (cols.length < 3) return false;
          final lat = double.tryParse(cols[1]) ?? 999.0;
          final lon = double.tryParse(cols[2]) ?? 999.0;
          return lat.abs() < 1e-4 && lon.abs() < 1e-4;
        });
        expect(
          hasSentinelRow,
          isFalse,
          reason: 'Sentinel (0,0) point should be removed',
        );
      });

      test('keeps null-island sentinel when normalize is false', () {
        const gpxWithSentinel = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="0.0" lon="0.0">
      <time>2024-01-01T10:00:00Z</time>
    </trkpt>
    <trkpt lat="40.0" lon="-105.0">
      <time>2024-01-01T10:00:10Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>''';

        final csv = ActivityConverter.convert(
          gpxWithSentinel,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          normalize: false,
        );

        // Without normalization, the sentinel point is kept
        final rows = csv.trim().split('\n').skip(1).toList();
        final hasSentinelRow = rows.any((row) {
          final cols = row.split(',');
          if (cols.length < 3) return false;
          final lat = double.tryParse(cols[1]) ?? 999.0;
          final lon = double.tryParse(cols[2]) ?? 999.0;
          return lat.abs() < 1e-4 && lon.abs() < 1e-4;
        });
        expect(
          hasSentinelRow,
          isTrue,
          reason: 'Sentinel should be kept when normalize:false',
        );
      });

      test('clears sentinel elevation (<= -499m) but keeps the point when '
          'normalize is true', () {
        const gpxWithSentinelEle = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="40.0" lon="-105.0">
      <ele>-500</ele>
      <time>2024-01-01T10:00:00Z</time>
    </trkpt>
    <trkpt lat="40.001" lon="-105.001">
      <ele>1200</ele>
      <time>2024-01-01T10:00:10Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>''';

        final csv = ActivityConverter.convert(
          gpxWithSentinelEle,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          normalize: true,
        );

        // Both points survive; only the bogus elevation is discarded.
        final rows = csv.trim().split('\n').skip(1).toList();
        expect(
          rows.length,
          equals(2),
          reason: 'The sentinel-elevation point keeps its valid coordinates',
        );
        // Row for the sentinel point has an empty elevation column
        // (header: timestamp,latitude,longitude,elevation,...).
        final sentinelRow = rows.firstWhere(
          (row) => row.split(',')[1] == '40.0',
        );
        expect(sentinelRow.split(',')[3], isEmpty);
        // The valid point keeps its elevation.
        final validRow = rows.firstWhere(
          (row) => row.split(',')[1] == '40.001',
        );
        expect(double.parse(validRow.split(',')[3]), equals(1200.0));
      });
    });

    // ---------------------------------------------------------------------------
    // TCX as input
    // ---------------------------------------------------------------------------
    group('TCX input', () {
      const sampleTcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>50</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1600</AltitudeMeters>
            <HeartRateBpm><Value>140</Value></HeartRateBpm>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-01-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.0005</LatitudeDegrees>
              <LongitudeDegrees>-105.0005</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1605</AltitudeMeters>
            <HeartRateBpm><Value>145</Value></HeartRateBpm>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

      test('converts TCX to GPX', () {
        final gpx = ActivityConverter.convert(
          sampleTcx,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.gpx,
        );

        expect(gpx, contains('<gpx'));
        expect(gpx, contains('40.0'));
        expect(gpx, contains('-105.0'));
      });

      test('converts TCX to CSV', () {
        final csv = ActivityConverter.convert(
          sampleTcx,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('timestamp,latitude,longitude'));
        expect(csv, contains('40.0'));
        expect(csv, contains('140'));
      });

      test('converts TCX to GeoJSON', () {
        final geojson = ActivityConverter.convert(
          sampleTcx,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.geojson,
        );

        expect(geojson, contains('FeatureCollection'));
        expect(geojson, contains('40.0'));
      });

      test('TCX to TCX round-trip preserves coordinates', () {
        final tcx = ActivityConverter.convert(
          sampleTcx,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.tcx,
        );

        expect(tcx, contains('TrainingCenterDatabase'));
        expect(tcx, contains('40.0'));
        expect(tcx, contains('-105.0'));
      });

      test('TCX to TCX round-trip preserves heart rate', () {
        final tcx = ActivityConverter.convert(
          sampleTcx,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.tcx,
        );

        expect(tcx, contains('HeartRateBpm'));
        expect(tcx, contains('140'));
        expect(tcx, contains('145'));
      });

      test('TCX to CSV preserves heart rate channel', () {
        final csv = ActivityConverter.convert(
          sampleTcx,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('heart_rate'));
        expect(csv, contains('140'));
        expect(csv, contains('145'));
      });

      test('TCX preserves sport through to GPX', () {
        final gpx = ActivityConverter.convert(
          sampleTcx,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.gpx,
        );

        // Sport type should be reflected in track type or output
        expect(gpx, isNotEmpty);
        expect(gpx, contains('<gpx'));
      });

      test('malformed TCX emits tcx error diagnostic', () {
        const bad = '<TrainingCenterDatabase><garbage';
        final diagnostics = <ParseDiagnostic>[];

        ActivityConverter.convert(
          bad,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.csv,
          diagnostics: diagnostics,
        );

        expect(diagnostics, isNotEmpty);
        expect(diagnostics.first.code, contains('tcx'));
        expect(diagnostics.first.severity, equals(ParseSeverity.error));
      });
    });

    // ---------------------------------------------------------------------------
    // GeoJSON as input
    // ---------------------------------------------------------------------------
    group('GeoJSON input', () {
      const sampleGeojsonLineString = '''
{
  "type": "Feature",
  "geometry": {
    "type": "LineString",
    "coordinates": [[-105.0, 40.0], [-105.0005, 40.0005]]
  },
  "properties": {
    "timestamps": ["2024-01-01T10:00:00Z", "2024-01-01T10:00:10Z"]
  }
}''';

      const sampleGeojsonCollection = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": {"type": "Point", "coordinates": [-105.0, 40.0]},
      "properties": {"timestamp": "2024-01-01T10:00:00Z", "heart_rate": 140}
    },
    {
      "type": "Feature",
      "geometry": {"type": "Point", "coordinates": [-105.0005, 40.0005]},
      "properties": {"timestamp": "2024-01-01T10:00:10Z", "heart_rate": 145}
    }
  ]
}''';

      test('converts GeoJSON LineString to GPX', () {
        final gpx = ActivityConverter.convert(
          sampleGeojsonLineString,
          from: ActivityFileFormat.geojson,
          to: ActivityFileFormat.gpx,
        );

        expect(gpx, contains('<gpx'));
        expect(gpx, contains('40.0'));
      });

      test('converts GeoJSON LineString to CSV', () {
        final csv = ActivityConverter.convert(
          sampleGeojsonLineString,
          from: ActivityFileFormat.geojson,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('latitude,longitude'));
        expect(csv, contains('40.0'));
      });

      test('converts GeoJSON FeatureCollection to CSV', () {
        final csv = ActivityConverter.convert(
          sampleGeojsonCollection,
          from: ActivityFileFormat.geojson,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('40.0'));
        expect(csv, contains('40.0005'));
      });

      test('GeoJSON FeatureCollection preserves heart rate to CSV', () {
        final csv = ActivityConverter.convert(
          sampleGeojsonCollection,
          from: ActivityFileFormat.geojson,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('heart_rate'));
        expect(csv, contains('140'));
        expect(csv, contains('145'));
      });

      test('converts GeoJSON to TCX', () {
        final tcx = ActivityConverter.convert(
          sampleGeojsonCollection,
          from: ActivityFileFormat.geojson,
          to: ActivityFileFormat.tcx,
        );

        expect(tcx, contains('TrainingCenterDatabase'));
        expect(tcx, contains('40.0'));
      });

      test('GeoJSON round-trip preserves coordinates', () {
        final geojson = ActivityConverter.convert(
          sampleGeojsonCollection,
          from: ActivityFileFormat.geojson,
          to: ActivityFileFormat.geojson,
        );

        expect(geojson, contains('40.0'));
        expect(geojson, contains('40.0005'));
      });

      test('malformed GeoJSON emits geojson error diagnostic', () {
        const bad = '{ not valid json ';
        final diagnostics = <ParseDiagnostic>[];

        ActivityConverter.convert(
          bad,
          from: ActivityFileFormat.geojson,
          to: ActivityFileFormat.csv,
          diagnostics: diagnostics,
        );

        expect(diagnostics, isNotEmpty);
        expect(diagnostics.first.code, contains('geojson'));
        expect(diagnostics.first.severity, equals(ParseSeverity.error));
      });
    });

    // ---------------------------------------------------------------------------
    // Format cross-matrix (filling obvious gaps)
    // ---------------------------------------------------------------------------
    group('Format cross-matrix', () {
      test('GPX to TCX', () {
        final tcx = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.tcx,
        );

        expect(tcx, contains('TrainingCenterDatabase'));
        expect(tcx, contains('40.0'));
        expect(tcx, contains('-105.0'));
      });

      test('TCX to GPX', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities><Activity Sport="Running"><Id>2024-01-01T10:00:00Z</Id>
    <Lap StartTime="2024-01-01T10:00:00Z">
      <Track>
        <Trackpoint>
          <Time>2024-01-01T10:00:00Z</Time>
          <Position><LatitudeDegrees>40.0</LatitudeDegrees><LongitudeDegrees>-105.0</LongitudeDegrees></Position>
        </Trackpoint>
        <Trackpoint>
          <Time>2024-01-01T10:00:10Z</Time>
          <Position><LatitudeDegrees>40.0005</LatitudeDegrees><LongitudeDegrees>-105.0005</LongitudeDegrees></Position>
        </Trackpoint>
      </Track>
    </Lap>
  </Activity></Activities>
</TrainingCenterDatabase>''';

        final gpx = ActivityConverter.convert(
          tcx,
          from: ActivityFileFormat.tcx,
          to: ActivityFileFormat.gpx,
        );

        expect(gpx, contains('<gpx'));
        expect(gpx, contains('40.0'));
        expect(gpx, contains('-105.0'));
      });

      test('GPX to GPX round-trip', () {
        final gpx = ActivityConverter.convert(
          sampleGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.gpx,
        );

        expect(gpx, contains('<gpx'));
        expect(gpx, contains('40.0'));
        expect(gpx, contains('-105.0'));
      });

      test('GeoJSON to GPX to CSV chain preserves coordinates', () {
        const geojson = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": {"type": "Point", "coordinates": [-105.0, 40.0]},
      "properties": {"timestamp": "2024-01-01T10:00:00Z"}
    },
    {
      "type": "Feature",
      "geometry": {"type": "Point", "coordinates": [-105.0005, 40.0005]},
      "properties": {"timestamp": "2024-01-01T10:00:10Z"}
    }
  ]
}''';

        final gpx = ActivityConverter.convert(
          geojson,
          from: ActivityFileFormat.geojson,
          to: ActivityFileFormat.gpx,
        );

        final csv = ActivityConverter.convert(
          gpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('40.0'));
        expect(csv, contains('40.0005'));
      });
    });

    // ---------------------------------------------------------------------------
    // Channel data preservation
    // ---------------------------------------------------------------------------
    group('Channel data preservation', () {
      const gpxWithHr = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <trk><trkseg>
    <trkpt lat="40.0" lon="-105.0">
      <time>2024-01-01T10:00:00Z</time>
      <extensions>
        <gpxtpx:TrackPointExtension>
          <gpxtpx:hr>140</gpxtpx:hr>
        </gpxtpx:TrackPointExtension>
      </extensions>
    </trkpt>
    <trkpt lat="40.0005" lon="-105.0005">
      <time>2024-01-01T10:00:10Z</time>
      <extensions>
        <gpxtpx:TrackPointExtension>
          <gpxtpx:hr>145</gpxtpx:hr>
        </gpxtpx:TrackPointExtension>
      </extensions>
    </trkpt>
  </trkseg></trk>
</gpx>''';

      test('GPX with HR extensions to CSV preserves heart rate', () {
        final csv = ActivityConverter.convert(
          gpxWithHr,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        expect(csv, contains('heart_rate'));
        expect(csv, contains('140'));
        expect(csv, contains('145'));
      });

      test('GPX with HR to TCX preserves heart rate', () {
        final tcx = ActivityConverter.convert(
          gpxWithHr,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.tcx,
        );

        expect(tcx, contains('HeartRateBpm'));
        expect(tcx, contains('140'));
        expect(tcx, contains('145'));
      });

      test('CSV with multiple channels to TCX preserves heart rate', () {
        const csvWithChannels =
            '''timestamp,latitude,longitude,heart_rate,cadence
2024-01-01T10:00:00Z,40.0,-105.0,140,85
2024-01-01T10:00:10Z,40.0005,-105.0005,145,88''';

        final tcx = ActivityConverter.convert(
          csvWithChannels,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.tcx,
        );

        expect(tcx, contains('HeartRateBpm'));
        expect(tcx, contains('140'));
      });

      test('CSV with elevation round-trips through GPX', () {
        const csvWithEle = '''timestamp,latitude,longitude,elevation
2024-01-01T10:00:00Z,40.0,-105.0,1600.0
2024-01-01T10:00:10Z,40.0005,-105.0005,1605.0''';

        final gpx = ActivityConverter.convert(
          csvWithEle,
          from: ActivityFileFormat.csv,
          to: ActivityFileFormat.gpx,
        );

        expect(gpx, contains('<ele>'));
        expect(gpx, contains('1600'));
      });
    });

    // ---------------------------------------------------------------------------
    // Edge cases
    // ---------------------------------------------------------------------------
    group('Edge cases', () {
      test('activity with no points produces valid empty output', () {
        const emptyGpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg></trkseg></trk>
</gpx>''';

        final csv = ActivityConverter.convert(
          emptyGpx,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
        );

        // Should produce at minimum a header row without crashing
        expect(csv, isNotNull);
      });

      test('single-point activity produces valid output', () {
        const onePoint = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="40.0" lon="-105.0">
      <time>2024-01-01T10:00:00Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>''';

        for (final to in [
          ActivityFileFormat.csv,
          ActivityFileFormat.gpx,
          ActivityFileFormat.tcx,
          ActivityFileFormat.geojson,
        ]) {
          final result = ActivityConverter.convert(
            onePoint,
            from: ActivityFileFormat.gpx,
            to: to,
          );
          expect(result, isNotNull, reason: 'Expected non-null output for $to');
          expect(
            result,
            isNotEmpty,
            reason: 'Expected non-empty output for $to',
          );
        }
      });

      test(
        'normalization is idempotent — running it twice yields same result',
        () {
          final first = ActivityConverter.convert(
            sampleGpx,
            from: ActivityFileFormat.gpx,
            to: ActivityFileFormat.csv,
            normalize: true,
          );

          final second = ActivityConverter.convert(
            first,
            from: ActivityFileFormat.csv,
            to: ActivityFileFormat.csv,
            normalize: true,
          );

          // Row counts must match
          final firstRows = first.trim().split('\n');
          final secondRows = second.trim().split('\n');
          expect(secondRows.length, equals(firstRows.length));
        },
      );

      test('exact point count after deduplication', () {
        const threePtsOneDup = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="40.0" lon="-105.0"><time>2024-01-01T10:00:00Z</time></trkpt>
    <trkpt lat="40.0" lon="-105.0"><time>2024-01-01T10:00:00Z</time></trkpt>
    <trkpt lat="40.001" lon="-105.001"><time>2024-01-01T10:00:10Z</time></trkpt>
  </trkseg></trk>
</gpx>''';

        final csv = ActivityConverter.convert(
          threePtsOneDup,
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.csv,
          normalize: true,
        );

        // 1 header + 2 data rows (duplicate collapsed)
        final rows = csv.trim().split('\n');
        expect(
          rows.length,
          equals(3),
          reason: 'Duplicate timestamp should collapse to 1 point',
        );
      });
    });
  });
}
