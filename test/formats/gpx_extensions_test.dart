// SPDX-License-Identifier: BSD-3-Clause
/// Tests for Garmin GPX TrackPointExtension support (v1 and v2).
///
/// Tests parsing, encoding, and round-trip conversion of GPX files with
/// Garmin-specific extensions including water temperature, depth, course,
/// bearing, and other v2-specific fields.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Garmin TrackPointExtension v2 Support', () {
    test('parses GPX with all v2 extension fields', () {
      const gpx = '''
<?xml version="1.0"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
  <trk>
    <name>Test Track</name>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <ele>1600</ele>
        <time>2024-01-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>140</gpxtpx:hr>
            <gpxtpx:cad>80</gpxtpx:cad>
            <gpxtpx:power>250</gpxtpx:power>
            <gpxtpx:atemp>20</gpxtpx:atemp>
            <gpxtpx:wtemp>15</gpxtpx:wtemp>
            <gpxtpx:depth>5.5</gpxtpx:depth>
            <gpxtpx:speed>3.5</gpxtpx:speed>
            <gpxtpx:course>45.0</gpxtpx:course>
            <gpxtpx:bearing>90.0</gpxtpx:bearing>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
      expect(result.activity.points.length, 1);

      final channels = result.activity.channels;
      expect(channels[Channel.heartRate]?.first.value, 140);
      expect(channels[Channel.cadence]?.first.value, 80);
      expect(channels[Channel.power]?.first.value, 250);
      expect(channels[Channel.temperature]?.first.value, 20);
      expect(channels[Channel.waterTemperature]?.first.value, 15);
      expect(channels[Channel.depth]?.first.value, 5.5);
      expect(channels[Channel.speed]?.first.value, 3.5);
      expect(channels[Channel.course]?.first.value, 45.0);
      expect(channels[Channel.bearing]?.first.value, 90.0);
    });

    test('encodes GPX with all v2 extension fields', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            elevation: 1600,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
          ],
          Channel.waterTemperature: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 15),
          ],
          Channel.depth: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 5.5),
          ],
          Channel.course: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 45.0),
          ],
          Channel.bearing: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 90.0),
          ],
        },
      );

      final gpx = ActivityEncoder.encode(activity, ActivityFileFormat.gpx);

      expect(gpx, contains('gpxtpx:hr'));
      expect(gpx, contains('gpxtpx:wtemp'));
      expect(gpx, contains('gpxtpx:depth'));
      expect(gpx, contains('gpxtpx:course'));
      expect(gpx, contains('gpxtpx:bearing'));
      expect(
        gpx,
        contains('http://www.garmin.com/xmlschemas/TrackPointExtension/v2'),
      );
    });

    test('ChannelSnapshot provides accessors for v2 channels', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            time: DateTime.utc(2024, 1, 1, 10, 0, 0),
          ),
        ],
        channels: {
          Channel.waterTemperature: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 15.5),
          ],
          Channel.depth: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 10.2),
          ],
          Channel.course: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 270.0),
          ],
          Channel.bearing: [
            Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 180.0),
          ],
        },
      );

      final snapshot = ActivityFiles.channelSnapshot(
        DateTime.utc(2024, 1, 1, 10, 0, 0),
        activity,
      );

      expect(snapshot.waterTemperature, 15.5);
      expect(snapshot.waterTemperatureDelta, Duration.zero);
      expect(snapshot.depth, 10.2);
      expect(snapshot.depthDelta, Duration.zero);
      expect(snapshot.course, 270.0);
      expect(snapshot.courseDelta, Duration.zero);
      expect(snapshot.bearing, 180.0);
      expect(snapshot.bearingDelta, Duration.zero);
    });

    test('round-trips GPX with v2 fields', () {
      const original = '''
<?xml version="1.0"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
  <trk>
    <name>Swimming Activity</name>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:wtemp>18</gpxtpx:wtemp>
            <gpxtpx:depth>2.5</gpxtpx:depth>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final parsed = ActivityParser.parse(original, ActivityFileFormat.gpx);
      final encoded = ActivityEncoder.encode(
        parsed.activity,
        ActivityFileFormat.gpx,
      );
      final reparsed = ActivityParser.parse(encoded, ActivityFileFormat.gpx);

      expect(
        reparsed.activity.channels[Channel.waterTemperature]?.first.value,
        18,
      );
      expect(reparsed.activity.channels[Channel.depth]?.first.value, 2.5);
    });

    test('handles GPX with partial v2 fields', () {
      const gpx = '''
<?xml version="1.0"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
  <trk>
    <trkseg>
      <trkpt lat="40.0" lon="-105.0">
        <time>2024-01-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:wtemp>18</gpxtpx:wtemp>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
      expect(
        result.activity.channels[Channel.waterTemperature]?.first.value,
        18,
      );
      expect(result.activity.channels[Channel.depth], isNull);
    });
  });

  group('Real-world Garmin GPX Files', () {
    test('parses Garmin cycling activity with v2 extensions', () {
      // Realistic Garmin Edge cycling export with comprehensive sensor data
      const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="Garmin Connect" version="1.1"
  xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd http://www.garmin.com/xmlschemas/TrackPointExtension/v2 http://www8.garmin.com/xmlschemas/TrackPointExtensionv2.xsd"
  xmlns="http://www.topografix.com/GPX/1/1"
  xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <metadata>
    <link href="connect.garmin.com">
      <text>Garmin Connect</text>
    </link>
    <time>2024-06-15T08:30:00Z</time>
  </metadata>
  <trk>
    <name>Morning Ride</name>
    <type>cycling</type>
    <trkseg>
      <trkpt lat="47.6062" lon="-122.3321">
        <ele>15.0</ele>
        <time>2024-06-15T08:30:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>95</gpxtpx:hr>
            <gpxtpx:cad>0</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="47.6063" lon="-122.3320">
        <ele>15.5</ele>
        <time>2024-06-15T08:30:05Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>105</gpxtpx:hr>
            <gpxtpx:cad>75</gpxtpx:cad>
            <gpxtpx:atemp>22</gpxtpx:atemp>
            <gpxtpx:speed>5.2</gpxtpx:speed>
            <gpxtpx:course>45.0</gpxtpx:course>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="47.6065" lon="-122.3318">
        <ele>16.2</ele>
        <time>2024-06-15T08:30:10Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>118</gpxtpx:hr>
            <gpxtpx:cad>82</gpxtpx:cad>
            <gpxtpx:atemp>22</gpxtpx:atemp>
            <gpxtpx:speed>7.8</gpxtpx:speed>
            <gpxtpx:course>48.5</gpxtpx:course>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

      expect(result.activity.points.length, 3);
      expect(result.activity.points.first.latitude, closeTo(47.6062, 0.0001));
      expect(
        result.activity.points.first.longitude,
        closeTo(-122.3321, 0.0001),
      );

      final hr = result.activity.channels[Channel.heartRate];
      expect(hr, isNotNull);
      expect(hr!.length, 3);
      expect(hr[0].value, 95);
      expect(hr[1].value, 105);
      expect(hr[2].value, 118);

      final cad = result.activity.channels[Channel.cadence];
      expect(cad, isNotNull);
      expect(cad!.length, 3);
      expect(cad[0].value, 0);
      expect(cad[1].value, 75);
      expect(cad[2].value, 82);

      final speed = result.activity.channels[Channel.speed];
      expect(speed, isNotNull);
      expect(speed!.length, 2);
      expect(speed[0].value, 5.2);
      expect(speed[1].value, 7.8);
    });

    test('parses Garmin swim activity with water sensors', () {
      // Realistic Garmin swim watch export with water temperature and depth
      const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="Garmin Swim" version="1.1"
  xmlns="http://www.topografix.com/GPX/1/1"
  xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
  <trk>
    <name>Open Water Swim</name>
    <type>swimming</type>
    <trkseg>
      <trkpt lat="47.5500" lon="-122.2800">
        <ele>0.0</ele>
        <time>2024-07-20T14:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>125</gpxtpx:hr>
            <gpxtpx:wtemp>18</gpxtpx:wtemp>
            <gpxtpx:depth>0.5</gpxtpx:depth>
            <gpxtpx:speed>1.2</gpxtpx:speed>
            <gpxtpx:course>270.0</gpxtpx:course>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="47.5501" lon="-122.2802">
        <ele>0.0</ele>
        <time>2024-07-20T14:00:10Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>132</gpxtpx:hr>
            <gpxtpx:wtemp>18</gpxtpx:wtemp>
            <gpxtpx:depth>1.8</gpxtpx:depth>
            <gpxtpx:speed>1.5</gpxtpx:speed>
            <gpxtpx:course>268.5</gpxtpx:course>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="47.5502" lon="-122.2804">
        <ele>0.0</ele>
        <time>2024-07-20T14:00:20Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>138</gpxtpx:hr>
            <gpxtpx:wtemp>17</gpxtpx:wtemp>
            <gpxtpx:depth>2.5</gpxtpx:depth>
            <gpxtpx:speed>1.4</gpxtpx:speed>
            <gpxtpx:course>265.0</gpxtpx:course>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

      expect(result.activity.points.length, 3);

      final waterTemp = result.activity.channels[Channel.waterTemperature];
      expect(waterTemp, isNotNull);
      expect(waterTemp!.length, 3);
      expect(waterTemp[0].value, 18);
      expect(waterTemp[1].value, 18);
      expect(waterTemp[2].value, 17);

      final depth = result.activity.channels[Channel.depth];
      expect(depth, isNotNull);
      expect(depth!.length, 3);
      expect(depth[0].value, 0.5);
      expect(depth[1].value, 1.8);
      expect(depth[2].value, 2.5);

      final course = result.activity.channels[Channel.course];
      expect(course, isNotNull);
      expect(course!.length, 3);
      expect(course[0].value, 270.0);
      expect(course[1].value, 268.5);
      expect(course[2].value, 265.0);
    });

    test('preserves Garmin metadata in round-trip conversion', () {
      const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="Garmin Edge 1030" version="1.1"
  xmlns="http://www.topografix.com/GPX/1/1"
  xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
  <metadata>
    <time>2024-08-01T12:00:00Z</time>
  </metadata>
  <trk>
    <name>Lunch Ride</name>
    <trkseg>
      <trkpt lat="40.7128" lon="-74.0060">
        <ele>10.0</ele>
        <time>2024-08-01T12:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>145</gpxtpx:hr>
            <gpxtpx:cad>90</gpxtpx:cad>
            <gpxtpx:atemp>28</gpxtpx:atemp>
            <gpxtpx:speed>8.5</gpxtpx:speed>
            <gpxtpx:course>180.0</gpxtpx:course>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final parsed = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
      final encoded = ActivityEncoder.encode(
        parsed.activity,
        ActivityFileFormat.gpx,
      );

      // Verify v2 namespace is used
      expect(
        encoded,
        contains('http://www.garmin.com/xmlschemas/TrackPointExtension/v2'),
      );
      expect(encoded, contains('TrackPointExtensionv2.xsd'));

      // Verify all channels are preserved
      expect(encoded, contains('<gpxtpx:hr>145</gpxtpx:hr>'));
      expect(encoded, contains('<gpxtpx:cad>90</gpxtpx:cad>'));
      expect(encoded, contains('<gpxtpx:atemp>28</gpxtpx:atemp>'));
      expect(encoded, contains('<gpxtpx:speed>'));
      expect(encoded, contains('<gpxtpx:course>'));

      // Re-parse to verify data integrity
      final reparsed = ActivityParser.parse(encoded, ActivityFileFormat.gpx);
      expect(reparsed.activity.points.length, 1);
      expect(reparsed.activity.channels[Channel.heartRate]?.first.value, 145);
      expect(reparsed.activity.channels[Channel.cadence]?.first.value, 90);
      expect(reparsed.activity.channels[Channel.temperature]?.first.value, 28);
    });

    test('handles Garmin v1 extension format (backward compatibility)', () {
      // Test v1 schema to ensure we're backward compatible
      const gpxV1 = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Garmin"
  xmlns="http://www.topografix.com/GPX/1/1"
  xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <trk>
    <name>Old Format Track</name>
    <trkseg>
      <trkpt lat="51.5074" lon="-0.1278">
        <ele>11.0</ele>
        <time>2024-01-15T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>130</gpxtpx:hr>
            <gpxtpx:cad>85</gpxtpx:cad>
            <gpxtpx:atemp>15</gpxtpx:atemp>
            <gpxtpx:wtemp>12</gpxtpx:wtemp>
            <gpxtpx:depth>3.2</gpxtpx:depth>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final result = ActivityParser.parse(gpxV1, ActivityFileFormat.gpx);

      expect(result.activity.points.length, 1);

      // Verify v1 fields are parsed correctly
      expect(result.activity.channels[Channel.heartRate]?.first.value, 130);
      expect(result.activity.channels[Channel.cadence]?.first.value, 85);
      expect(result.activity.channels[Channel.temperature]?.first.value, 15);

      // Verify v1 also had wtemp and depth (contrary to documentation)
      expect(
        result.activity.channels[Channel.waterTemperature]?.first.value,
        12,
      );
      expect(result.activity.channels[Channel.depth]?.first.value, 3.2);
    });

    test('handles mixed sensor availability across points', () {
      // Real-world scenario: sensors may connect/disconnect during activity
      const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Garmin"
  xmlns="http://www.topografix.com/GPX/1/1"
  xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
  <trk>
    <name>Sensor Test</name>
    <trkseg>
      <trkpt lat="37.7749" lon="-122.4194">
        <time>2024-09-01T16:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>120</gpxtpx:hr>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="37.7750" lon="-122.4193">
        <time>2024-09-01T16:00:05Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>125</gpxtpx:hr>
            <gpxtpx:cad>80</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="37.7751" lon="-122.4192">
        <time>2024-09-01T16:00:10Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>130</gpxtpx:hr>
            <gpxtpx:cad>85</gpxtpx:cad>
            <gpxtpx:atemp>25</gpxtpx:atemp>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="37.7752" lon="-122.4191">
        <time>2024-09-01T16:00:15Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>128</gpxtpx:hr>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';

      final result = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

      expect(result.activity.points.length, 4);

      // HR present in all points
      final hr = result.activity.channels[Channel.heartRate];
      expect(hr!.length, 4);

      // Cadence only in points 2-3
      final cad = result.activity.channels[Channel.cadence];
      expect(cad!.length, 2);
      expect(cad.first.time, DateTime.utc(2024, 9, 1, 16, 0, 5));

      // Temperature only in point 3
      final temp = result.activity.channels[Channel.temperature];
      expect(temp!.length, 1);
      expect(temp.first.value, 25);
    });

    test('encodes realistic Garmin activity with all sensor types', () {
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 48.8566,
            longitude: 2.3522,
            elevation: 35.0,
            time: DateTime.utc(2024, 10, 15, 9, 0, 0),
          ),
          GeoPoint(
            latitude: 48.8567,
            longitude: 2.3523,
            elevation: 35.5,
            time: DateTime.utc(2024, 10, 15, 9, 0, 5),
          ),
          GeoPoint(
            latitude: 48.8568,
            longitude: 2.3524,
            elevation: 36.0,
            time: DateTime.utc(2024, 10, 15, 9, 0, 10),
          ),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 0), value: 142),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 5), value: 145),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 10), value: 148),
          ],
          Channel.cadence: [
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 0), value: 88),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 5), value: 90),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 10), value: 92),
          ],
          Channel.power: [
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 0), value: 215),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 5), value: 220),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 10), value: 225),
          ],
          Channel.temperature: [
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 0), value: 18),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 5), value: 18),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 10), value: 19),
          ],
          Channel.speed: [
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 0), value: 6.5),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 5), value: 6.8),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 10), value: 7.1),
          ],
          Channel.course: [
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 0), value: 45.0),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 5), value: 46.5),
            Sample(time: DateTime.utc(2024, 10, 15, 9, 0, 10), value: 48.0),
          ],
        },
      );

      final gpx = ActivityEncoder.encode(activity, ActivityFileFormat.gpx);

      // Verify GPX structure
      expect(gpx, contains('<?xml version="1.0"'));
      expect(gpx, contains('<gpx'));
      expect(gpx, contains('<trk>'));
      expect(gpx, contains('<trkseg>'));

      // Verify v2 schema
      expect(
        gpx,
        contains('http://www.garmin.com/xmlschemas/TrackPointExtension/v2'),
      );

      // Verify all sensor data is encoded
      expect(gpx, contains('<gpxtpx:hr>'));
      expect(gpx, contains('<gpxtpx:cad>'));
      expect(gpx, contains('<gpxtpx:power>'));
      expect(gpx, contains('<gpxtpx:atemp>'));
      expect(gpx, contains('<gpxtpx:speed>'));
      expect(gpx, contains('<gpxtpx:course>'));

      // Verify coordinates are present (GPX uses 6 decimal places)
      expect(gpx, contains('lat="48.856600"'));
      expect(gpx, contains('lon="2.352200"'));

      // Parse back to verify data integrity
      final reparsed = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
      expect(reparsed.activity.points.length, 3);
      expect(reparsed.activity.channels[Channel.heartRate]?.length, 3);
      expect(reparsed.activity.channels[Channel.cadence]?.length, 3);
      expect(reparsed.activity.channels[Channel.power]?.length, 3);
      expect(reparsed.activity.channels[Channel.speed]?.length, 3);
      expect(reparsed.activity.channels[Channel.course]?.length, 3);
    });
  });
}
