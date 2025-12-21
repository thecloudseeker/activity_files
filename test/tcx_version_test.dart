// SPDX-License-Identifier: BSD-3-Clause
import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  const tcxV1Sample = '''
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

  test('parses TCX v1 payloads', () {
    final result = ActivityParser.parse(tcxV1Sample, ActivityFileFormat.tcx);
    expect(
      result.diagnostics.where((d) => d.severity == ParseSeverity.error),
      isEmpty,
    );
    expect(result.activity.points, hasLength(2));
    expect(result.activity.channel(Channel.heartRate), hasLength(1));
    expect(result.activity.channel(Channel.cadence), hasLength(1));
  });

  test('encodes TCX v1 when requested', () {
    final activity = RawActivity(
      points: [
        GeoPoint(
          latitude: 40.0,
          longitude: -105.0,
          elevation: 1600,
          time: DateTime.utc(2024, 5, 1),
        ),
        GeoPoint(
          latitude: 40.0005,
          longitude: -105.0005,
          elevation: 1601,
          time: DateTime.utc(2024, 5, 1, 0, 0, 5),
        ),
      ],
      channels: {
        Channel.heartRate: [Sample(time: DateTime.utc(2024, 5, 1), value: 140)],
      },
      sport: Sport.running,
    );
    final xml = ActivityEncoder.encode(
      activity,
      ActivityFileFormat.tcx,
      options: const EncoderOptions(tcxVersion: TcxVersion.v1),
    );
    expect(xml, contains('TrainingCenterDatabase/v1'));
    expect(xml, contains('TrainingCenterDatabasev1.xsd'));
  });

  test('conversion can target TCX v1', () async {
    final conversion = await ActivityFiles.convert(
      source: tcxV1Sample,
      from: ActivityFileFormat.tcx,
      to: ActivityFileFormat.tcx,
      options: const EncoderOptions(tcxVersion: TcxVersion.v1),
      useIsolate: false,
    );
    final output = conversion.asString();
    expect(output, contains('TrainingCenterDatabase/v1'));

    final roundTrip = ActivityParser.parse(
      output,
      ActivityFileFormat.tcx,
    ).activity;
    expect(roundTrip.points, hasLength(2));
  });
}
