// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:activity_files/src/encode/geojson_encoder.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

/// Round-trip fidelity coverage for TCX (power/speed channels, lap
/// statistics) and GeoJSON (elevation, per-point timestamps).
void main() {
  final t0 = DateTime.utc(2024, 4, 2, 7, 0, 0);

  List<GeoPoint> pointsAt(DateTime start, int count) => [
    for (var i = 0; i < count; i++)
      GeoPoint(
        latitude: 48.0 + i * 0.0001,
        longitude: 9.0 + i * 0.0001,
        elevation: 300.0 + i,
        time: start.add(Duration(seconds: i * 10)),
      ),
  ];

  RawActivity roundTrip(RawActivity activity, ActivityFileFormat format) {
    final encoded = ActivityEncoder.encode(activity, format);
    final result = ActivityParser.parseBytes(
      Uint8List.fromList(utf8.encode(encoded)),
      format,
    );
    expect(
      result.diagnostics.where((d) => d.severity == ParseSeverity.error),
      isEmpty,
      reason: 'encoded ${format.name} must parse without errors',
    );
    return result.activity;
  }

  group('TCX round-trip', () {
    test('power and speed survive via TPX extensions', () {
      final points = pointsAt(t0, 4);
      final activity = RawActivity(
        points: points,
        channels: {
          Channel.power: [
            for (final p in points) Sample(time: p.time, value: 250.0),
          ],
          Channel.speed: [
            for (final p in points) Sample(time: p.time, value: 3.5),
          ],
        },
        sport: Sport.cycling,
      );

      final parsed = roundTrip(activity, ActivityFileFormat.tcx);
      final power = parsed.channel(Channel.power);
      final speed = parsed.channel(Channel.speed);
      expect(power, hasLength(4));
      expect(power.every((s) => s.value == 250.0), isTrue);
      expect(speed, hasLength(4));
      expect(speed.every((s) => (s.value - 3.5).abs() < 0.001), isTrue);
    });

    test('lap statistics survive', () {
      final points = pointsAt(t0, 4);
      final activity = RawActivity(
        points: points,
        laps: [
          Lap(
            startTime: points.first.time,
            endTime: points.last.time,
            distanceMeters: 1200.0,
            calories: 45.0,
            maxSpeed: 4.2,
            avgHeartRate: 140.0,
            maxHeartRate: 168.0,
            avgCadence: 85.0,
            maxCadence: 102.0,
            avgSpeed: 3.4,
            avgPower: 205.0,
            maxPower: 480.0,
          ),
        ],
        sport: Sport.cycling,
      );

      final lap = roundTrip(activity, ActivityFileFormat.tcx).laps.single;
      expect(lap.distanceMeters, closeTo(1200.0, 0.1));
      expect(lap.calories, 45.0);
      expect(lap.maxSpeed, closeTo(4.2, 0.001));
      expect(lap.avgHeartRate, 140.0);
      expect(lap.maxHeartRate, 168.0);
      expect(lap.avgCadence, 85.0);
      expect(lap.maxCadence, 102.0);
      expect(lap.avgSpeed, closeTo(3.4, 0.001));
      expect(lap.avgPower, 205.0);
      expect(lap.maxPower, 480.0);
    });

    test('RunCadence TPX extension parses when plain Cadence is absent', () {
      const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
    xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-04-02T07:00:00Z</Id>
      <Lap StartTime="2024-04-02T07:00:00Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>50</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-04-02T07:00:00Z</Time>
            <Position>
              <LatitudeDegrees>48.0</LatitudeDegrees>
              <LongitudeDegrees>9.0</LongitudeDegrees>
            </Position>
            <Extensions>
              <ns3:TPX><ns3:RunCadence>88</ns3:RunCadence></ns3:TPX>
            </Extensions>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-04-02T07:00:10Z</Time>
            <Position>
              <LatitudeDegrees>48.001</LatitudeDegrees>
              <LongitudeDegrees>9.001</LongitudeDegrees>
            </Position>
            <Extensions>
              <ns3:TPX><ns3:RunCadence>90</ns3:RunCadence></ns3:TPX>
            </Extensions>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

      final result = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(tcx)),
        ActivityFileFormat.tcx,
      );
      final cadence = result.activity.channel(Channel.cadence);
      expect(cadence, hasLength(2));
      expect(cadence[0].value, 88.0);
      expect(cadence[1].value, 90.0);
    });
  });

  group('GeoJSON round-trip', () {
    test('elevation and per-point timestamps survive', () {
      final points = pointsAt(t0, 4);
      final activity = RawActivity(points: points, sport: Sport.hiking);

      final parsed = roundTrip(activity, ActivityFileFormat.geojson);
      expect(parsed.points, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(parsed.points[i].elevation, closeTo(300.0 + i, 0.001));
        expect(parsed.points[i].time, points[i].time);
      }
    });

    test('points without elevation stay elevation-less', () {
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 48.0, longitude: 9.0, time: t0),
          GeoPoint(
            latitude: 48.001,
            longitude: 9.001,
            time: t0.add(const Duration(seconds: 10)),
          ),
        ],
        sport: Sport.walking,
      );

      final parsed = roundTrip(activity, ActivityFileFormat.geojson);
      expect(parsed.points, hasLength(2));
      expect(parsed.points.every((p) => p.elevation == null), isTrue);
    });

    test('unknown numeric properties parse as custom channels', () {
      const geojson =
          '{"type":"FeatureCollection","features":[{"type":"Feature",'
          '"geometry":{"type":"Point","coordinates":[9.0,48.0,300.0]},'
          '"properties":{"timestamp":"2024-04-02T07:00:00Z","altitude":300.0,'
          '"heart_rate":140,"core_temp":37.2}}]}';
      final parsed = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(geojson)),
        ActivityFileFormat.geojson,
      ).activity;
      expect(parsed.channel(Channel.heartRate).single.value, 140.0);
      expect(parsed.channel(Channel.custom('core_temp')).single.value, 37.2);
    });

    test('point features carry every channel including custom ones', () {
      final points = pointsAt(t0, 2);
      final activity = RawActivity(
        points: points,
        channels: {
          Channel.custom('core_temp'): [
            for (final p in points) Sample(time: p.time, value: 37.2),
          ],
          Channel.heartRate: [
            for (final p in points) Sample(time: p.time, value: 133.0),
          ],
        },
        sport: Sport.running,
      );
      final encoded = GeojsonEncoder.encodeAsPointsWithChannels(activity);
      final parsed = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(encoded)),
        ActivityFileFormat.geojson,
      ).activity;
      expect(parsed.channel(Channel.custom('core_temp')), hasLength(2));
      expect(parsed.channel(Channel.custom('core_temp')).first.value, 37.2);
      expect(parsed.channel(Channel.heartRate).first.value, 133.0);
    });
  });

  group('CSV round-trip', () {
    test('extra and custom channels survive as columns', () {
      final points = pointsAt(t0, 3);
      final activity = RawActivity(
        points: points,
        channels: {
          Channel.waterTemperature: [
            for (final p in points) Sample(time: p.time, value: 18.5),
          ],
          Channel.custom('core_temp'): [
            for (final p in points) Sample(time: p.time, value: 37.2),
          ],
        },
        sport: Sport.swimming,
      );
      final encoded = ActivityEncoder.encode(activity, ActivityFileFormat.csv);
      expect(encoded.split('\n').first, contains('core_temp'));
      expect(encoded.split('\n').first, contains('water_temperature'));

      final parsed = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(encoded)),
        ActivityFileFormat.csv,
      ).activity;
      expect(parsed.channel(Channel.waterTemperature), hasLength(3));
      expect(parsed.channel(Channel.waterTemperature).first.value, 18.5);
      expect(parsed.channel(Channel.custom('core_temp')), hasLength(3));
      expect(parsed.channel(Channel.custom('core_temp')).first.value, 37.2);
    });
  });

  group('GPX point extensions', () {
    const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2"
     xmlns:myext="http://example.com/ext/v1">
  <trk>
    <trkseg>
      <trkpt lat="47.0" lon="11.0">
        <ele>500</ele>
        <time>2024-01-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>140</gpxtpx:hr>
            <gpxtpx:vertical_osc>8.5</gpxtpx:vertical_osc>
          </gpxtpx:TrackPointExtension>
          <myext:sensor quality="good">42</myext:sensor>
        </extensions>
      </trkpt>
      <trkpt lat="47.001" lon="11.001"><time>2024-01-01T10:00:10Z</time></trkpt>
    </trkseg>
  </trk>
</gpx>''';

    test('unknown TPX tags become custom channels', () {
      final parsed = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(gpx)),
        ActivityFileFormat.gpx,
      ).activity;
      expect(parsed.channel(Channel.heartRate).single.value, 140.0);
      expect(
        parsed.channel(Channel.custom('vertical_osc')).single.value,
        closeTo(8.5, 0.001),
      );
    });

    test('foreign point extension nodes are preserved and re-encoded', () {
      final parsed = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(gpx)),
        ActivityFileFormat.gpx,
      ).activity;
      final extensions = parsed.points.first.gpxExtensions;
      expect(extensions, isNotNull);
      expect(extensions!.single.name, 'sensor');
      expect(extensions.single.value, '42');
      expect(extensions.single.attributes['quality'], 'good');
      expect(parsed.points[1].gpxExtensions, isNull);

      final encoded = ActivityEncoder.encode(parsed, ActivityFileFormat.gpx);
      expect(encoded, contains('myext:sensor'));
      expect(encoded, contains('xmlns:myext'));

      final reparsed = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(encoded)),
        ActivityFileFormat.gpx,
      ).activity;
      final roundTripped = reparsed.points.first.gpxExtensions;
      expect(roundTripped, isNotNull);
      expect(roundTripped!.single.name, 'sensor');
      expect(roundTripped.single.value, '42');
      expect(roundTripped.single.attributes['quality'], 'good');
    });
  });

  group('FIT unknown record fields', () {
    test('unknown native record field becomes a fit_field_<n> channel', () {
      final bytes = _buildFitWithUnknownRecordField();
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      final samples = result.activity.channel(Channel.custom('fit_field_39'));
      expect(samples, hasLength(1));
      expect(samples.single.value, 85.0);
    });
  });

  group('GPX → FIT → GPX', () {
    test('foreign TPX channels survive FIT via developer fields', () {
      const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
  <trk><trkseg>
    <trkpt lat="47.0" lon="11.0"><ele>500</ele>
      <time>2024-04-02T07:00:00Z</time>
      <extensions><gpxtpx:TrackPointExtension>
        <gpxtpx:wtemp>18.5</gpxtpx:wtemp>
        <gpxtpx:depth>3.2</gpxtpx:depth>
      </gpxtpx:TrackPointExtension></extensions>
    </trkpt>
    <trkpt lat="47.001" lon="11.001"><ele>501</ele>
      <time>2024-04-02T07:00:10Z</time>
      <extensions><gpxtpx:TrackPointExtension>
        <gpxtpx:wtemp>18.7</gpxtpx:wtemp>
        <gpxtpx:depth>2.9</gpxtpx:depth>
      </gpxtpx:TrackPointExtension></extensions>
    </trkpt>
  </trkseg></trk>
</gpx>''';

      final fromGpx = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(gpx)),
        ActivityFileFormat.gpx,
      ).activity;
      expect(fromGpx.channel(Channel.waterTemperature), hasLength(2));

      final fitEncoded = ActivityEncoder.encode(
        fromGpx,
        ActivityFileFormat.fit,
      );
      final fromFit = ActivityParser.parseBytes(
        base64Decode(fitEncoded),
        ActivityFileFormat.fit,
      ).activity;

      List<double> values(RawActivity activity, Channel channel) =>
          activity.channel(channel).map((s) => s.value).toList();

      expect(values(fromFit, Channel.waterTemperature), [18.5, 18.7]);
      expect(values(fromFit, Channel.depth), [3.2, 2.9]);

      final gpxAgain = ActivityEncoder.encode(fromFit, ActivityFileFormat.gpx);
      final reparsed = ActivityParser.parseBytes(
        Uint8List.fromList(utf8.encode(gpxAgain)),
        ActivityFileFormat.gpx,
      ).activity;

      expect(values(reparsed, Channel.waterTemperature), [18.5, 18.7]);
      expect(values(reparsed, Channel.depth), [3.2, 2.9]);
    });
  });
}

/// Builds a FIT file whose record definition contains an unhandled native
/// field (39, uint16) alongside timestamp/lat/lon.
Uint8List _buildFitWithUnknownRecordField() {
  final data = BytesBuilder();
  data.add([
    0x40, 0x00, 0x00, 0x14, 0x00, 0x04, // def local 0, global 20, 4 fields
    0xFD, 0x04, 0x86, // timestamp (uint32)
    0x00, 0x04, 0x85, // position_lat (sint32)
    0x01, 0x04, 0x85, // position_long (sint32)
    0x27, 0x02, 0x84, // field 39 (uint16) — not handled explicitly
  ]);
  data.add([
    0x00,
    ...uint32LeBytes(1000),
    ...int32LeBytes(encodeSemicircles(47.0)),
    ...int32LeBytes(encodeSemicircles(11.0)),
    ...uint16LeBytes(85),
  ]);
  final payload = data.toBytes();
  final header = buildFitHeader(payload.length);
  final crc = fitCrc(payload);
  return Uint8List.fromList([
    ...header,
    ...payload,
    crc & 0xFF,
    (crc >> 8) & 0xFF,
  ]);
}
