// SPDX-License-Identifier: BSD-3-Clause
/// Shared test data fixtures for activity file testing.
///
/// This file contains standard sample data in GPX, TCX, and FIT formats used
/// across multiple test files. All samples are designed to be compatible with
/// each other for cross-format conversion testing.
///
/// Standard samples contain:
/// - 3 trackpoints at 10-second intervals
/// - Location: 40.0-40.001 lat, -105.0 to -105.001 lon
/// - Elevation: 1600-1602m
/// - Heart rate: 140-145 bpm
/// - Cadence: 82-86 spm
/// - Timestamps: 2024-03-01T10:00:00Z + 0/10/20 seconds
library;

/// Standard GPX 1.1 sample with 3 trackpoints and basic channels (HR, cadence).
///
/// Uses Garmin TrackPointExtension v1 namespace for sensor data.
const String sampleGpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="TestDevice"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <trk>
    <name>Sample Run</name>
    <type>Running</type>
    <trkseg>
      <trkpt lat="40.000000" lon="-105.000000">
        <ele>1600.0</ele>
        <time>2024-03-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>140</gpxtpx:hr>
            <gpxtpx:cad>82</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="40.000500" lon="-105.000500">
        <ele>1601.0</ele>
        <time>2024-03-01T10:00:10Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>142</gpxtpx:hr>
            <gpxtpx:cad>84</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="40.001000" lon="-105.001000">
        <ele>1602.0</ele>
        <time>2024-03-01T10:00:20Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>145</gpxtpx:hr>
            <gpxtpx:cad>86</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
''';

/// Standard TCX v2 sample with 3 trackpoints and basic channels (HR, cadence).
///
/// Contains a single Activity with one Lap and Track segment.
const String sampleTcx = '''
<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-03-01T10:00:00Z</Id>
      <Lap StartTime="2024-03-01T10:00:00Z">
        <TotalTimeSeconds>20.0</TotalTimeSeconds>
        <DistanceMeters>140.0</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-03-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.000000</LatitudeDegrees>
              <LongitudeDegrees>-105.000000</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1600.0</AltitudeMeters>
            <DistanceMeters>0.0</DistanceMeters>
            <HeartRateBpm>
              <Value>140</Value>
            </HeartRateBpm>
            <Cadence>82</Cadence>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-03-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.000500</LatitudeDegrees>
              <LongitudeDegrees>-105.000500</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1601.0</AltitudeMeters>
            <DistanceMeters>70.0</DistanceMeters>
            <HeartRateBpm>
              <Value>142</Value>
            </HeartRateBpm>
            <Cadence>84</Cadence>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-03-01T10:00:20Z</Time>
            <Position>
              <LatitudeDegrees>40.001000</LatitudeDegrees>
              <LongitudeDegrees>-105.001000</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1602.0</AltitudeMeters>
            <DistanceMeters>140.0</DistanceMeters>
            <HeartRateBpm>
              <Value>145</Value>
            </HeartRateBpm>
            <Cadence>86</Cadence>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
''';

/// GPX 1.0 format sample for backward compatibility testing.
///
/// Uses the GPX 1.0 schema and includes Garmin v1 extensions.
const String gpx10Sample = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.0" creator="gpx-1-0" xmlns="http://www.topografix.com/GPX/1/0" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <trk>
    <name>Sample 1.0</name>
    <trkseg>
      <trkpt lat="40.0000" lon="-105.0000">
        <ele>1600.0</ele>
        <time>2024-05-01T00:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>140</gpxtpx:hr>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="40.0005" lon="-105.0005">
        <ele>1601.0</ele>
        <time>2024-05-01T00:00:05Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
''';

/// TCX v1 format sample for backward compatibility testing.
///
/// Uses the TrainingCenterDatabase v1 schema.
const String tcxV1Sample = '''
<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-05-01T00:00:00Z</Id>
      <Lap StartTime="2024-05-01T00:00:00Z">
        <TotalTimeSeconds>5.0</TotalTimeSeconds>
        <DistanceMeters>10.0</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-05-01T00:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0000</LatitudeDegrees>
              <LongitudeDegrees>-105.0000</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1600.0</AltitudeMeters>
            <DistanceMeters>0.0</DistanceMeters>
            <HeartRateBpm><Value>140</Value></HeartRateBpm>
            <Cadence>80</Cadence>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-05-01T00:00:05Z</Time>
            <Position>
              <LatitudeDegrees>40.0005</LatitudeDegrees>
              <LongitudeDegrees>-105.0005</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1601.0</AltitudeMeters>
            <DistanceMeters>10.0</DistanceMeters>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
''';
