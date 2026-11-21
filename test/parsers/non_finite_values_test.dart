// SPDX-License-Identifier: BSD-3-Clause
/// Tests that a number a file holds as `NaN`, `Infinity` or an overflowing
/// literal never reaches the model: the value is left out with a warning.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

const _nonFinite = ['NaN', 'Infinity', '-Infinity', '1e999'];

Future<ActivityImportResult> _import(String text, ActivityFileFormat format) =>
    ActivityFiles.import(text, format: format);

void _expectAllFinite(RawActivity activity) {
  for (final point in activity.points) {
    expect(point.latitude.isFinite, isTrue);
    expect(point.longitude.isFinite, isTrue);
    expect(point.elevation?.isFinite ?? true, isTrue);
  }
  for (final channel in activity.channels.keys) {
    for (final sample in activity.channel(channel)) {
      expect(sample.value.isFinite, isTrue, reason: channel.id);
    }
  }
  for (final lap in activity.laps) {
    for (final value in [
      lap.distanceMeters,
      lap.calories,
      lap.maxSpeed,
      lap.avgSpeed,
      lap.avgHeartRate,
      lap.maxHeartRate,
      lap.avgCadence,
      lap.maxCadence,
    ]) {
      expect(value?.isFinite ?? true, isTrue);
    }
  }
  for (final waypoint in activity.gpxWaypoints) {
    expect(waypoint.latitude.isFinite, isTrue);
    expect(waypoint.elevation?.isFinite ?? true, isTrue);
  }
}

Iterable<String> _warningCodes(ActivityImportResult result) => result
    .diagnostics
    .where((d) => d.severity == ParseSeverity.warning)
    .map((d) => d.code);

String _gpx({
  String lat = '46.0',
  String ele = '500',
  String hr = '140',
  String wptEle = '600',
}) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1"
  xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <wpt lat="46.5" lon="13.5"><ele>$wptEle</ele></wpt>
  <trk><trkseg>
    <trkpt lat="$lat" lon="13.0"><ele>$ele</ele><time>2024-01-01T10:00:00Z</time>
      <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>$hr</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
    </trkpt>
    <trkpt lat="46.001" lon="13.001"><ele>501</ele><time>2024-01-01T10:00:10Z</time></trkpt>
  </trkseg></trk>
</gpx>''';

String _tcx({
  String lapDistance = '100',
  String calories = '10',
  String altitude = '500',
  String hr = '140',
  String watts = '200',
}) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
  xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
  <Activities><Activity Sport="Running">
    <Id>2024-01-01T10:00:00Z</Id>
    <Lap StartTime="2024-01-01T10:00:00Z">
      <TotalTimeSeconds>10</TotalTimeSeconds>
      <DistanceMeters>$lapDistance</DistanceMeters>
      <Calories>$calories</Calories>
      <Track>
        <Trackpoint><Time>2024-01-01T10:00:00Z</Time>
          <Position><LatitudeDegrees>46.0</LatitudeDegrees><LongitudeDegrees>13.0</LongitudeDegrees></Position>
          <AltitudeMeters>$altitude</AltitudeMeters>
          <HeartRateBpm><Value>$hr</Value></HeartRateBpm>
          <Extensions><ns3:TPX><ns3:Watts>$watts</ns3:Watts></ns3:TPX></Extensions>
        </Trackpoint>
        <Trackpoint><Time>2024-01-01T10:00:10Z</Time>
          <Position><LatitudeDegrees>46.001</LatitudeDegrees><LongitudeDegrees>13.001</LongitudeDegrees></Position>
        </Trackpoint>
      </Track>
    </Lap>
  </Activity></Activities>
</TrainingCenterDatabase>''';

String _geojson(String value) =>
    '''
{"type":"Feature","geometry":{"type":"LineString","coordinates":[[13.0,46.0,$value],[13.001,46.001,501]]},
 "properties":{"activity_type":"running","total_calories":$value,"stride":$value,
  "coordinateProperties":{"times":["2024-01-01T10:00:00Z","2024-01-01T10:00:10Z"],
   "channels":{"heart_rate":[$value,141]}}}}''';

void main() {
  group('GPX', () {
    for (final value in _nonFinite) {
      test('"$value" in a trackpoint coordinate skips the point', () async {
        final result = await _import(_gpx(lat: value), ActivityFileFormat.gpx);
        expect(result.activity.points, hasLength(1));
        expect(
          _warningCodes(result),
          contains('gpx.trackpoint.missing_coordinates'),
        );
        _expectAllFinite(result.activity);
      });

      test('"$value" as elevation, extension and waypoint elevation is '
          'left out with warnings', () async {
        final result = await _import(
          _gpx(ele: value, hr: value, wptEle: value),
          ActivityFileFormat.gpx,
        );
        expect(result.activity.points, hasLength(2));
        expect(result.activity.points.first.elevation, isNull);
        expect(result.activity.channel(Channel.heartRate), isEmpty);
        expect(result.activity.gpxWaypoints.single.elevation, isNull);
        expect(
          _warningCodes(result),
          containsAll([
            'gpx.trackpoint.invalid_elevation',
            'gpx.extension.invalid_number',
            'gpx.wpt.invalid_elevation',
          ]),
        );
        _expectAllFinite(result.activity);
      });
    }

    test('a waypoint with unreadable coordinates is reported', () async {
      final gpx = _gpx().replaceFirst('lat="46.5"', 'lat="NaN"');
      final result = await _import(gpx, ActivityFileFormat.gpx);
      expect(result.activity.gpxWaypoints, isEmpty);
      expect(_warningCodes(result), contains('gpx.wpt.invalid_coordinates'));
    });
  });

  group('TCX', () {
    for (final value in _nonFinite) {
      test('"$value" in trackpoint and lap values is left out with '
          'warnings', () async {
        final result = await _import(
          _tcx(
            lapDistance: value,
            calories: value,
            altitude: value,
            hr: value,
            watts: value,
          ),
          ActivityFileFormat.tcx,
        );
        final lap = result.activity.laps.single;
        expect(lap.distanceMeters, isNull);
        expect(lap.calories, isNull);
        expect(result.activity.points.first.elevation, isNull);
        expect(result.activity.channel(Channel.heartRate), isEmpty);
        expect(result.activity.channel(Channel.power), isEmpty);
        expect(
          _warningCodes(result),
          containsAll([
            'tcx.lap.invalid_number',
            'tcx.trackpoint.invalid_altitude',
            'tcx.trackpoint.invalid_heartrate',
            'tcx.trackpoint.invalid_extension_value',
          ]),
        );
        _expectAllFinite(result.activity);
      });
    }

    test('readable values raise no new warnings', () async {
      final result = await _import(_tcx(), ActivityFileFormat.tcx);
      expect(result.activity.laps.single.distanceMeters, 100);
      expect(result.activity.channel(Channel.power).single.value, 200);
      expect(_warningCodes(result), isNot(contains('tcx.lap.invalid_number')));
    });
  });

  group('CSV', () {
    for (final value in _nonFinite) {
      test('"$value" in elevation, a channel and a custom column is left out '
          'with warnings', () async {
        final csv =
            'timestamp,latitude,longitude,elevation,heart_rate,stride\n'
            '2024-01-01T10:00:00Z,46.0,13.0,$value,$value,$value\n'
            '2024-01-01T10:00:10Z,46.001,13.001,501,141,1.2\n';
        final result = await _import(csv, ActivityFileFormat.csv);
        expect(result.activity.points, hasLength(2));
        expect(result.activity.points.first.elevation, isNull);
        expect(result.activity.channel(Channel.heartRate), hasLength(1));
        expect(result.activity.channel(Channel.custom('stride')), hasLength(1));
        expect(
          _warningCodes(result).where((c) => c == 'csv.row.invalid_value'),
          hasLength(3),
        );
        _expectAllFinite(result.activity);
      });
    }

    test('free text in a custom column stays quiet', () async {
      const csv =
          'timestamp,latitude,longitude,note\n'
          '2024-01-01T10:00:00Z,46.0,13.0,easy run\n';
      final result = await _import(csv, ActivityFileFormat.csv);
      expect(_warningCodes(result), isNot(contains('csv.row.invalid_value')));
    });
  });

  group('GeoJSON', () {
    for (final value in ['1e999', '-1e999']) {
      test('$value in elevation, properties and coordinate channels is left '
          'out with warnings', () async {
        final result = await _import(
          _geojson(value),
          ActivityFileFormat.geojson,
        );
        expect(result.activity.points, hasLength(2));
        expect(result.activity.points.first.elevation, isNull);
        expect(result.activity.summary?.calories, isNull);
        expect(result.activity.channel(Channel.custom('stride')), isEmpty);
        expect(result.activity.channel(Channel.heartRate), hasLength(1));
        expect(
          _warningCodes(result),
          containsAll([
            'geojson.point.invalid_elevation',
            'geojson.property.invalid_number',
          ]),
        );
        _expectAllFinite(result.activity);
      });
    }
  });
}
