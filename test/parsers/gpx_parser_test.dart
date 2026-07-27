// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for GPX parser.
///
/// Tests GPX 1.0/1.1 parsing with various elements, extensions,
/// and error conditions.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('GPX Parser', () {
    group('Basic GPX 1.1 parsing', () {
      test('parses simple GPX with trackpoint', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <ele>1600</ele>
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isEmpty,
        );
        expect(result.activity.points.length, equals(1));
        expect(result.activity.points[0].latitude, equals(40.0));
        expect(result.activity.points[0].longitude, equals(-105.0));
        expect(result.activity.points[0].elevation, equals(1600));
      });

      test('parses multiple trackpoints', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <ele>1600</ele>
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
      <trkpt lat="40.0005" lon="-105.0005">
        <ele>1605</ele>
        <time>2024-01-01T10:00:10Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.points.length, equals(2));
      });

      test('parses track with metadata', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>Sample Activity</name>
    <desc>Test description</desc>
  </metadata>
  <trk>
    <name>Track Name</name>
    <type>running</type>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.points.length, equals(1));
        expect(result.activity.sport, equals(Sport.running));
      });
    });

    group('GPX 1.0 parsing', () {
      test('parses GPX 1.0 format', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.0" xmlns="http://www.topografix.com/GPX/1/0">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <ele>1600</ele>
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.points.length, equals(1));
      });

      test('parses GPX 1.0 with root-level name/desc', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.0" xmlns="http://www.topografix.com/GPX/1/0">
  <name>Activity Name</name>
  <desc>Activity Description</desc>
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.points.length, equals(1));
      });
    });

    group('Garmin TrackPointExtension parsing', () {
      test('parses GPX with v1 TrackPointExtension', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>140</gpxtpx:hr>
            <gpxtpx:cad>82</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.channel(Channel.heartRate).length, equals(1));
        expect(
          result.activity.channel(Channel.heartRate)[0].value,
          equals(140),
        );
        expect(result.activity.channel(Channel.cadence).length, equals(1));
        expect(result.activity.channel(Channel.cadence)[0].value, equals(82));
      });

      test('parses GPX with v2 TrackPointExtension', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>140</gpxtpx:hr>
            <gpxtpx:cad>82</gpxtpx:cad>
            <gpxtpx:temp>21</gpxtpx:temp>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.channel(Channel.heartRate).length, equals(1));
        expect(result.activity.channel(Channel.cadence).length, equals(1));
        expect(result.activity.channel(Channel.temperature).length, equals(1));
      });
    });

    group('Sport type detection', () {
      test('parses running sport', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <type>running</type>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.sport, equals(Sport.running));
      });

      test('parses cycling sport', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <type>cycling</type>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.sport, equals(Sport.cycling));
      });

      test('parses swimming sport', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <type>swimming</type>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.sport, equals(Sport.swimming));
      });

      test('defaults to unknown for unrecognized sport', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <type>unknown_sport</type>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.sport, equals(Sport.unknown));
      });
    });

    group('Error handling', () {
      test('reports error for malformed XML', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test('reports error for empty GPX', () {
        const gpx = '';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test('handles GPX with no trackpoints gracefully', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.points, isEmpty);
      });

      test('skips trackpoint with missing coordinates', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
      <trkpt lat="40.0005" lon="-105.0005">
        <time>2024-01-01T10:00:10Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.points.length, equals(1));
      });
    });

    group('Timestamp handling', () {
      test('parses ISO 8601 timestamps', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.points[0].time.isUtc, isTrue);
      });

      test('converts timestamps to UTC', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00+02:00</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.points[0].time.isUtc, isTrue);
      });
    });

    group('Waypoint parsing', () {
      test('parses GPX waypoints as structured data (not track points)', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="40.0" lon="-105.0">
    <ele>1600</ele>
    <time>2024-01-01T10:00:00Z</time>
    <name>Summit</name>
    <sym>Flag</sym>
  </wpt>
</gpx>''';

        final activity = ActivityParser.parse(
          gpx,
          ActivityFileFormat.gpx,
        ).activity;

        // Waypoints are preserved separately, not folded into the track.
        expect(activity.points, isEmpty);
        expect(activity.gpxWaypoints.length, equals(1));
        final wpt = activity.gpxWaypoints.single;
        expect(wpt.latitude, closeTo(40.0, 1e-9));
        expect(wpt.elevation, closeTo(1600, 1e-9));
        expect(wpt.gpxAttributes?['name'], 'Summit');
        expect(wpt.gpxAttributes?['sym'], 'Flag');
      });

      test('parses GPX routes as structured data', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <rte>
    <name>Planned loop</name>
    <rtept lat="40.0" lon="-105.0">
      <time>2024-01-01T10:00:00Z</time>
    </rtept>
    <rtept lat="40.0005" lon="-105.0005">
      <time>2024-01-01T10:00:10Z</time>
    </rtept>
  </rte>
</gpx>''';

        final activity = ActivityParser.parse(
          gpx,
          ActivityFileFormat.gpx,
        ).activity;

        expect(activity.points, isEmpty);
        expect(activity.gpxRoutes.length, equals(1));
        final route = activity.gpxRoutes.single;
        expect(route.name, 'Planned loop');
        expect(route.points.length, equals(2));
      });
    });

    group('Creator attribute', () {
      test('extracts creator attribute', () {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1" creator="Garmin BaseCamp">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

        final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

        expect(result.activity.creator, equals('Garmin BaseCamp'));
      });
    });
  });
}
