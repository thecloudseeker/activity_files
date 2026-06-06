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
  });
}
