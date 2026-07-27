// SPDX-License-Identifier: BSD-3-Clause
import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// GPX round-trip coverage for waypoints, routes, per-point GPS attributes,
/// and multi-segment tracks — the structures that used to be dropped.
void main() {
  RawActivity roundTrip(String gpx) {
    final activity = ActivityParser.parse(gpx, ActivityFileFormat.gpx).activity;
    final encoded = ActivityEncoder.encode(activity, ActivityFileFormat.gpx);
    return ActivityParser.parse(encoded, ActivityFileFormat.gpx).activity;
  }

  group('GPX lossless round-trip', () {
    test('per-point GPS attributes (hdop/sat/fix) survive', () {
      const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="40.0" lon="-105.0">
      <ele>1600</ele>
      <time>2024-01-01T10:00:00Z</time>
      <hdop>0.9</hdop>
      <sat>11</sat>
      <fix>3d</fix>
    </trkpt>
    <trkpt lat="40.001" lon="-105.001">
      <time>2024-01-01T10:00:10Z</time>
      <hdop>1.2</hdop>
    </trkpt>
  </trkseg></trk>
</gpx>''';
      final activity = roundTrip(gpx);
      expect(activity.points, hasLength(2));
      expect(activity.points[0].gpxAttributes?['hdop'], '0.9');
      expect(activity.points[0].gpxAttributes?['sat'], '11');
      expect(activity.points[0].gpxAttributes?['fix'], '3d');
      expect(activity.points[1].gpxAttributes?['hdop'], '1.2');
      expect(activity.points[1].gpxAttributes?['fix'], isNull);
    });

    test('waypoints with name/sym survive and stay out of the track', () {
      const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="40.5" lon="-105.5">
    <ele>2000</ele>
    <name>Trailhead</name>
    <sym>Parking</sym>
    <desc>Start here</desc>
  </wpt>
  <trk><trkseg>
    <trkpt lat="40.0" lon="-105.0"><time>2024-01-01T10:00:00Z</time></trkpt>
  </trkseg></trk>
</gpx>''';
      final activity = roundTrip(gpx);
      expect(activity.points, hasLength(1), reason: 'waypoint not in track');
      expect(activity.gpxWaypoints, hasLength(1));
      final wpt = activity.gpxWaypoints.single;
      expect(wpt.latitude, closeTo(40.5, 1e-9));
      expect(wpt.elevation, closeTo(2000, 1e-9));
      expect(wpt.gpxAttributes?['name'], 'Trailhead');
      expect(wpt.gpxAttributes?['sym'], 'Parking');
      expect(wpt.gpxAttributes?['desc'], 'Start here');
    });

    test('routes survive with name and route points', () {
      const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <rte>
    <name>Planned loop</name>
    <rtept lat="40.0" lon="-105.0"><name>WP1</name></rtept>
    <rtept lat="40.01" lon="-105.01"><name>WP2</name></rtept>
  </rte>
</gpx>''';
      final activity = roundTrip(gpx);
      expect(activity.gpxRoutes, hasLength(1));
      final route = activity.gpxRoutes.single;
      expect(route.name, 'Planned loop');
      expect(route.points, hasLength(2));
      expect(route.points[0].gpxAttributes?['name'], 'WP1');
      expect(route.points[1].latitude, closeTo(40.01, 1e-9));
    });

    test('multi-segment track re-emits its segment boundaries', () {
      const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0"><time>2024-01-01T10:00:00Z</time></trkpt>
      <trkpt lat="40.001" lon="-105.001"><time>2024-01-01T10:00:10Z</time></trkpt>
    </trkseg>
    <trkseg>
      <trkpt lat="40.01" lon="-105.01"><time>2024-01-01T10:05:00Z</time></trkpt>
      <trkpt lat="40.011" lon="-105.011"><time>2024-01-01T10:05:10Z</time></trkpt>
    </trkseg>
  </trk>
</gpx>''';
      final activity = ActivityParser.parse(
        gpx,
        ActivityFileFormat.gpx,
      ).activity;
      expect(activity.points, hasLength(4));
      expect(activity.gpxTrackSegments, [0, 2]);

      final encoded = ActivityEncoder.encode(activity, ActivityFileFormat.gpx);
      expect(
        '<trkseg>'.allMatches(encoded).length,
        2,
        reason: 'two segments must round-trip to two <trkseg> elements',
      );
      final reparsed = ActivityParser.parse(
        encoded,
        ActivityFileFormat.gpx,
      ).activity;
      expect(reparsed.gpxTrackSegments, [0, 2]);
    });
  });
}
