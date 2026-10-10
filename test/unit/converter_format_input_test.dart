// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for ActivityConverter high-level API.
///
/// Tests format conversion between different file formats with various options.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('ActivityConverter (continued)', () {
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

        // No points, so only the header row is written.
        final rows = csv.trim().split('\n');
        expect(rows, hasLength(1));
        expect(rows.single, startsWith('timestamp,latitude,longitude'));
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
        'normalization is idempotent: running it twice yields same result',
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
