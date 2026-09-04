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

      test('reads every Track in a Lap, not just the first', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>40</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.0</LatitudeDegrees>
              <LongitudeDegrees>-105.0</LongitudeDegrees>
            </Position>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-01-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.0001</LatitudeDegrees>
              <LongitudeDegrees>-105.0001</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:30Z</Time>
            <Position>
              <LatitudeDegrees>40.0002</LatitudeDegrees>
              <LongitudeDegrees>-105.0002</LongitudeDegrees>
            </Position>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-01-01T10:00:40Z</Time>
            <Position>
              <LatitudeDegrees>40.0003</LatitudeDegrees>
              <LongitudeDegrees>-105.0003</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.points.length, equals(4));
        expect(
          result.activity.laps.single.endTime,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 40)),
        );
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

      test(
        'treats a Trackpoint Time and Lap StartTime without a UTC offset as UTC',
        () {
          const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:00">
        <TotalTimeSeconds>20</TotalTimeSeconds>
        <DistanceMeters>100</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00</Time>
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

          expect(
            result.activity.points[0].time,
            equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
          );
          expect(
            result.activity.laps.single.startTime,
            equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
          );
        },
      );
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

      test('clamps startTime to the first trackpoint when the declared '
          'StartTime postdates it, so the point survives re-encoding', () {
        const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Lap StartTime="2024-01-01T10:00:05Z">
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
          <Trackpoint>
            <Time>2024-01-01T10:00:20Z</Time>
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

        expect(result.activity.points, hasLength(2));
        expect(
          result.activity.laps[0].startTime,
          equals(DateTime.utc(2024, 1, 1, 10, 0, 0)),
        );
      });
    });

    group('Multi-activity merge', () {
      String twoActivityTcx({
        required String firstNotes,
        required String secondNotes,
      }) =>
          '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-01-01T10:00:00Z</Id>
      <Notes>$firstNotes</Notes>
      <Lap StartTime="2024-01-01T10:00:00Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>50</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T10:00:00Z</Time>
            <Position><LatitudeDegrees>40.0</LatitudeDegrees><LongitudeDegrees>-105.0</LongitudeDegrees></Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
    <Activity Sport="Biking">
      <Id>2024-01-01T11:00:00Z</Id>
      <Notes>$secondNotes</Notes>
      <Lap StartTime="2024-01-01T11:00:00Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>50</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T11:00:00Z</Time>
            <Position><LatitudeDegrees>41.0</LatitudeDegrees><LongitudeDegrees>-106.0</LongitudeDegrees></Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

      test('a later activity with distinct Notes reports the drop instead '
          'of silently discarding it', () {
        final tcx = twoActivityTcx(
          firstNotes: 'Felt great',
          secondNotes: 'Legs were tired',
        );
        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.tcxNotes, equals('Felt great'));
        expect(
          result.diagnostics.map((d) => d.code),
          contains('lossy.tcx_activity_metadata_dropped'),
        );
      });

      test('identical Notes across activities (same watch, multi-sport '
          'session) does not spuriously report a drop', () {
        final tcx = twoActivityTcx(
          firstNotes: 'Brick workout',
          secondNotes: 'Brick workout',
        );
        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(
          result.diagnostics.map((d) => d.code),
          isNot(contains('lossy.tcx_activity_metadata_dropped')),
        );
      });

      test('a later activity with a distinct Creator reports the same drop '
          'code as distinct Notes, not a Notes-specific one', () {
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
            <Position><LatitudeDegrees>40.0</LatitudeDegrees><LongitudeDegrees>-105.0</LongitudeDegrees></Position>
          </Trackpoint>
        </Track>
      </Lap>
      <Creator xsi:type="Device_t">
        <Name>Forerunner 945</Name>
      </Creator>
    </Activity>
    <Activity Sport="Biking">
      <Id>2024-01-01T11:00:00Z</Id>
      <Lap StartTime="2024-01-01T11:00:00Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>50</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T11:00:00Z</Time>
            <Position><LatitudeDegrees>41.0</LatitudeDegrees><LongitudeDegrees>-106.0</LongitudeDegrees></Position>
          </Trackpoint>
        </Track>
      </Lap>
      <Creator xsi:type="Device_t">
        <Name>Edge 530</Name>
      </Creator>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';
        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.device?.model, equals('Forerunner 945'));
        expect(
          result.diagnostics.map((d) => d.code),
          contains('lossy.tcx_activity_metadata_dropped'),
        );
      });

      test('a later activity that simply omits Creator does not spuriously '
          'report a drop (absent is not distinct)', () {
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
            <Position><LatitudeDegrees>40.0</LatitudeDegrees><LongitudeDegrees>-105.0</LongitudeDegrees></Position>
          </Trackpoint>
        </Track>
      </Lap>
      <Creator xsi:type="Device_t">
        <Name>Forerunner 945</Name>
      </Creator>
    </Activity>
    <Activity Sport="Biking">
      <Id>2024-01-01T11:00:00Z</Id>
      <Lap StartTime="2024-01-01T11:00:00Z">
        <TotalTimeSeconds>10</TotalTimeSeconds>
        <DistanceMeters>50</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-01-01T11:00:00Z</Time>
            <Position><LatitudeDegrees>41.0</LatitudeDegrees><LongitudeDegrees>-106.0</LongitudeDegrees></Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';
        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        expect(result.activity.device?.model, equals('Forerunner 945'));
        expect(
          result.diagnostics.map((d) => d.code),
          isNot(contains('lossy.tcx_activity_metadata_dropped')),
        );
      });
    });
  });
}
