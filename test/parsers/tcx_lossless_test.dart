// SPDX-License-Identifier: BSD-3-Clause
import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// TCX round-trip coverage for Notes, Author, lap Intensity/TriggerMethod, and
/// multi-sport activity structure.
void main() {
  RawActivity parse(String tcx) =>
      ActivityParser.parse(tcx, ActivityFileFormat.tcx).activity;
  String encode(RawActivity a) =>
      ActivityEncoder.encode(a, ActivityFileFormat.tcx);
  RawActivity roundTrip(String tcx) => parse(encode(parse(tcx)));

  group('TCX lossless round-trip', () {
    test('Notes, Author, and lap Intensity/TriggerMethod survive', () {
      const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-07-21T06:00:00Z</Id>
      <Lap StartTime="2024-07-21T06:00:00Z">
        <TotalTimeSeconds>60</TotalTimeSeconds>
        <DistanceMeters>200</DistanceMeters>
        <Intensity>Active</Intensity>
        <TriggerMethod>Manual</TriggerMethod>
        <Track>
          <Trackpoint>
            <Time>2024-07-21T06:00:00Z</Time>
            <Position><LatitudeDegrees>47.5</LatitudeDegrees><LongitudeDegrees>-122.2</LongitudeDegrees></Position>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-07-21T06:00:30Z</Time>
            <Position><LatitudeDegrees>47.501</LatitudeDegrees><LongitudeDegrees>-122.201</LongitudeDegrees></Position>
          </Trackpoint>
        </Track>
      </Lap>
      <Notes>Great morning run</Notes>
    </Activity>
  </Activities>
  <Author xsi:type="Application_t" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <Name>Garmin Connect</Name>
  </Author>
</TrainingCenterDatabase>''';

      final parsed = parse(tcx);
      expect(parsed.tcxNotes, 'Great morning run');
      expect(parsed.tcxAuthor, 'Garmin Connect');
      expect(parsed.laps.single.tcxIntensity, 'Active');
      expect(parsed.laps.single.tcxTriggerMethod, 'Manual');

      final again = roundTrip(tcx);
      expect(again.tcxNotes, 'Great morning run');
      expect(again.tcxAuthor, 'Garmin Connect');
      expect(again.laps.single.tcxIntensity, 'Active');
      expect(again.laps.single.tcxTriggerMethod, 'Manual');
    });

    test('multi-sport activity re-splits into one <Activity> per sport', () {
      // TCX's Sport attribute only supports Running/Biking/Other, so use a
      // run-bike-run sequence to exercise a 3-way split with valid sports.
      Lap lap(Sport s, int minute) => Lap(
        startTime: DateTime.utc(2024, 7, 21, 6, minute),
        endTime: DateTime.utc(2024, 7, 21, 6, minute + 5),
        sport: s,
        distanceMeters: 1000,
        tcxIntensity: 'Active',
      );
      final activity = RawActivity(
        points: [
          for (var i = 0; i < 4; i++)
            GeoPoint(
              latitude: 47.5 + i * 0.001,
              longitude: -122.2,
              time: DateTime.utc(2024, 7, 21, 6, i * 5),
            ),
        ],
        sport: Sport.running,
        laps: [
          lap(Sport.running, 0),
          lap(Sport.cycling, 5),
          lap(Sport.running, 10),
        ],
      );

      final encoded = encode(activity);
      // Three consecutive-sport groups → three <Activity> elements.
      expect('<Activity '.allMatches(encoded).length, 3);
      expect(encoded, contains('Sport="Biking"'));
      expect('Sport="Running"'.allMatches(encoded).length, 2);

      final reparsed = parse(encoded);
      // Merged back to one activity with three sport-specific laps.
      expect(reparsed.laps, hasLength(3));
      expect(reparsed.laps.map((l) => l.sport), [
        Sport.running,
        Sport.cycling,
        Sport.running,
      ]);
    });

    test('single-sport activity stays a single <Activity>', () {
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 47.5, longitude: -122.2, time: DateTime.utc(2024)),
          GeoPoint(
            latitude: 47.51,
            longitude: -122.21,
            time: DateTime.utc(2024, 1, 1, 0, 1),
          ),
        ],
        sport: Sport.running,
        laps: [
          Lap(
            startTime: DateTime.utc(2024),
            endTime: DateTime.utc(2024, 1, 1, 0, 1),
            sport: Sport.running,
          ),
        ],
      );
      final encoded = encode(activity);
      expect('<Activity '.allMatches(encoded).length, 1);
    });
  });
}
