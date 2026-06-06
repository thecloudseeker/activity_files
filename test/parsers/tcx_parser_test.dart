// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for TCX parser.
///
/// Tests TCX v2 and multi-activity parsing with various elements
/// like trackpoints, laps, and heart rate data.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('TCX Parser', () {
    group('Basic TCX v2 parsing', () {
      test('parses simple TCX activity', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1600</AltitudeMeters>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isEmpty,
        );
        expect(result.activity.points.length, equals(1));
        expect(result.activity.points[0].latitude, equals(40.0));
        expect(result.activity.points[0].longitude, equals(-105.0));
      });

      test('parses TCX with heart rate data', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
            <HeartRateBpm>
              <Value>140</Value>
            </HeartRateBpm>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-01-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.0005</LatitudeDegrees>
              <LongitudeDegrees>-105.0005</LongitudeDegrees>
            </Position>
            <HeartRateBpm>
              <Value>145</Value>
            </HeartRateBpm>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        final hrChannel = result.activity.channel(Channel.heartRate);
        expect(hrChannel.length, equals(2));
        expect(hrChannel[0].value, equals(140));
        expect(hrChannel[1].value, equals(145));
      });

      test('parses TCX with cadence data', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Biking">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
            <Cadence>80</Cadence>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-01-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.0005</LatitudeDegrees>
              <LongitudeDegrees>-105.0005</LongitudeDegrees>
            </Position>
            <Cadence>84</Cadence>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        final cadChannel = result.activity.channel(Channel.cadence);
        expect(cadChannel.length, equals(2));
        expect(cadChannel[0].value, equals(80));
        expect(cadChannel[1].value, equals(84));
      });

      test('parses TCX with multiple laps', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
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
          </Trackpoint>
        </Track>
      </Lap>
      <Lap StartTime="2024-01-01T10:00:10Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>50</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.0005</LatitudeDegrees>
              <LongitudeDegrees>-105.0005</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.laps.length, equals(2));
        expect(result.activity.points.length, equals(2));
      });
    });

    group('Sport type parsing', () {
      test('parses running sport', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.sport, equals(Sport.running));
      });

      test('parses cycling sport variants', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Biking">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.sport, equals(Sport.cycling));
      });

      test('parses swimming sport', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Swimming">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.sport, equals(Sport.swimming));
      });
    });

    group('Multi-activity (triathlon) parsing', () {
      test('merges multiple activities into single activity', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Swimming">
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
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
    <Activity Sport="Biking">
      <Id>2024-01-01T10:00:30Z</Id>
      <Lap StartTime="2024-01-01T10:00:30Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:30Z</Time>
            <Position>
              <LatitudeDegrees>40.0005</LatitudeDegrees>
              <LongitudeDegrees>-105.0005</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
    <Activity Sport="Running">
      <Id>2024-01-01T10:01:00Z</Id>
      <Lap StartTime="2024-01-01T10:01:00Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:01:00Z</Time>
            <Position>
              <LatitudeDegrees>40.001</LatitudeDegrees>
              <LongitudeDegrees>-105.001</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.points.length, equals(3));
        expect(result.activity.laps.length, equals(3));
        expect(
          result.diagnostics.any((d) => d.code == 'tcx.multi_activity'),
          isTrue,
        );
      });
    });

    group('Error handling', () {
      test('reports error for malformed XML', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
      </Lap>
    </Activity>
  </Activities>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isNotEmpty,
        );
      });

      test('handles empty Activities gracefully', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.points, isEmpty);
      });

      test('handles Lap without Track', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.points, isEmpty);
      });

      test('skips trackpoint with missing coordinates', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-01-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.0005</LatitudeDegrees>
              <LongitudeDegrees>-105.0005</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.points.length, equals(1));
      });
    });

    group('Timestamp handling', () {
      test('parses ISO 8601 timestamps', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.points[0].time.isUtc, isTrue);
      });
    });

    group('Lap information', () {
      test('preserves lap distance information', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>1000</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.laps[0].distanceMeters, equals(1000));
      });
    });
  });
}
