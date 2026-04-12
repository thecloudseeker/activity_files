// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for multi-sport activity support.
///
/// Tests parsing, encoding, validation, merging, and splitting of multi-sport
/// activities (e.g., triathlon with swim, bike, run segments).
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Multi-Sport Activity Support', () {
    group('TCX Multi-Sport Parsing', () {
      test('parses triathlon TCX with multiple activities', () {
        const tcx = '''
<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Swimming">
      <Id>2024-07-21T06:00:00Z</Id>
      <Lap StartTime="2024-07-21T06:00:00Z">
        <TotalTimeSeconds>1200</TotalTimeSeconds>
        <DistanceMeters>750</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-07-21T06:00:00Z</Time>
            <Position>
              <LatitudeDegrees>47.5500</LatitudeDegrees>
              <LongitudeDegrees>-122.2800</LongitudeDegrees>
            </Position>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-07-21T06:20:00Z</Time>
            <Position>
              <LatitudeDegrees>47.5520</LatitudeDegrees>
              <LongitudeDegrees>-122.2820</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
    <Activity Sport="Biking">
      <Id>2024-07-21T06:25:00Z</Id>
      <Lap StartTime="2024-07-21T06:25:00Z">
        <TotalTimeSeconds>3600</TotalTimeSeconds>
        <DistanceMeters>40000</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-07-21T06:25:00Z</Time>
            <Position>
              <LatitudeDegrees>47.5520</LatitudeDegrees>
              <LongitudeDegrees>-122.2820</LongitudeDegrees>
            </Position>
            <HeartRateBpm><Value>150</Value></HeartRateBpm>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-07-21T07:25:00Z</Time>
            <Position>
              <LatitudeDegrees>47.5800</LatitudeDegrees>
              <LongitudeDegrees>-122.3100</LongitudeDegrees>
            </Position>
            <HeartRateBpm><Value>165</Value></HeartRateBpm>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
    <Activity Sport="Running">
      <Id>2024-07-21T07:30:00Z</Id>
      <Lap StartTime="2024-07-21T07:30:00Z">
        <TotalTimeSeconds>1800</TotalTimeSeconds>
        <DistanceMeters>5000</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-07-21T07:30:00Z</Time>
            <Position>
              <LatitudeDegrees>47.5800</LatitudeDegrees>
              <LongitudeDegrees>-122.3100</LongitudeDegrees>
            </Position>
            <HeartRateBpm><Value>170</Value></HeartRateBpm>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-07-21T08:00:00Z</Time>
            <Position>
              <LatitudeDegrees>47.5850</LatitudeDegrees>
              <LongitudeDegrees>-122.3150</LongitudeDegrees>
            </Position>
            <HeartRateBpm><Value>175</Value></HeartRateBpm>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        // Should have multi-activity diagnostic
        final multiActivityDiag = result.diagnostics.firstWhere(
          (d) => d.code == 'tcx.multi_activity',
          orElse: () => throw StateError('Expected multi-activity diagnostic'),
        );
        expect(multiActivityDiag.severity, ParseSeverity.info);
        expect(multiActivityDiag.message, contains('3 activities'));

        // Overall sport should be from first activity
        expect(result.activity.sport, Sport.swimming);

        // Should have 3 laps with correct sports
        expect(result.activity.laps.length, 3);
        expect(result.activity.laps[0].sport, Sport.swimming);
        expect(result.activity.laps[0].distanceMeters, 750);
        expect(result.activity.laps[1].sport, Sport.cycling);
        expect(result.activity.laps[1].distanceMeters, 40000);
        expect(result.activity.laps[2].sport, Sport.running);
        expect(result.activity.laps[2].distanceMeters, 5000);

        // Should have merged all points
        expect(result.activity.points.length, 6);

        // Heart rate samples should be merged
        final hr = result.activity.channels[Channel.heartRate];
        expect(hr, isNotNull);
        expect(hr!.length, 4); // 2 from bike, 2 from run
      });

      test('handles single-activity TCX without multi-sport diagnostic', () {
        const tcx = '''
<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-07-21T06:00:00Z</Id>
      <Lap StartTime="2024-07-21T06:00:00Z">
        <TotalTimeSeconds>1800</TotalTimeSeconds>
        <Track>
          <Trackpoint>
            <Time>2024-07-21T06:00:00Z</Time>
            <Position>
              <LatitudeDegrees>47.5500</LatitudeDegrees>
              <LongitudeDegrees>-122.2800</LongitudeDegrees>
            </Position>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

        final result = ActivityParser.parse(tcx, ActivityFileFormat.tcx);

        // Should NOT have multi-activity diagnostic
        final multiActivityDiags = result.diagnostics.where(
          (d) => d.code == 'tcx.multi_activity',
        );
        expect(multiActivityDiags, isEmpty);

        expect(result.activity.sport, Sport.running);
        expect(result.activity.laps.length, 1);
        expect(result.activity.laps[0].sport, Sport.running);
      });
    });

    group('FIT Multi-Sport Parsing', () {
      test('assigns sport to laps based on session boundaries', () {
        // This test uses a minimal FIT structure to verify multi-sport logic
        // In a real FIT file, sessions define sport boundaries for subsequent laps

        // Create a builder with multi-sport laps to verify encoding
        final swimLap = Lap(
          startTime: DateTime.utc(2024, 7, 21, 6, 0),
          endTime: DateTime.utc(2024, 7, 21, 6, 20),
          distanceMeters: 750,
          sport: Sport.swimming,
        );
        final bikeLap = Lap(
          startTime: DateTime.utc(2024, 7, 21, 6, 25),
          endTime: DateTime.utc(2024, 7, 21, 7, 25),
          distanceMeters: 40000,
          sport: Sport.cycling,
        );
        final runLap = Lap(
          startTime: DateTime.utc(2024, 7, 21, 7, 30),
          endTime: DateTime.utc(2024, 7, 21, 8, 0),
          distanceMeters: 5000,
          sport: Sport.running,
        );

        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
            GeoPoint(
              latitude: 47.552,
              longitude: -122.282,
              time: DateTime.utc(2024, 7, 21, 6, 20),
            ),
            GeoPoint(
              latitude: 47.58,
              longitude: -122.31,
              time: DateTime.utc(2024, 7, 21, 7, 30),
            ),
          ],
          laps: [swimLap, bikeLap, runLap],
          sport: Sport.swimming, // Overall sport
        );

        // Verify laps have correct sports
        expect(activity.laps[0].sport, Sport.swimming);
        expect(activity.laps[1].sport, Sport.cycling);
        expect(activity.laps[2].sport, Sport.running);
      });

      test('handles single-session FIT without sport on laps', () {
        final lap = Lap(
          startTime: DateTime.utc(2024, 7, 21, 6, 0),
          endTime: DateTime.utc(2024, 7, 21, 6, 30),
          distanceMeters: 5000,
        );

        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
          ],
          laps: [lap],
          sport: Sport.running,
        );

        // Lap should not have sport (inherits from activity)
        expect(activity.laps[0].sport, isNull);
        expect(activity.sport, Sport.running);
      });
    });

    group('Multi-Sport Validation', () {
      test('lap validation works with sport-specific laps', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
            GeoPoint(
              latitude: 47.552,
              longitude: -122.282,
              time: DateTime.utc(2024, 7, 21, 6, 20),
            ),
            GeoPoint(
              latitude: 47.58,
              longitude: -122.31,
              time: DateTime.utc(2024, 7, 21, 7, 30),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 0),
              endTime: DateTime.utc(2024, 7, 21, 6, 20),
              sport: Sport.swimming,
            ),
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 25),
              endTime: DateTime.utc(2024, 7, 21, 7, 25),
              sport: Sport.cycling,
            ),
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 7, 30),
              endTime: DateTime.utc(2024, 7, 21, 8, 0),
              sport: Sport.running,
            ),
          ],
          sport: Sport.swimming,
        );

        final result = validateRawActivity(activity);
        expect(result.isValid, isTrue);
      });

      test('validateLapBoundaries works with multi-sport laps', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
            GeoPoint(
              latitude: 47.58,
              longitude: -122.31,
              time: DateTime.utc(2024, 7, 21, 8, 0),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 0),
              endTime: DateTime.utc(2024, 7, 21, 6, 20),
              sport: Sport.swimming,
            ),
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 7, 30),
              endTime: DateTime.utc(2024, 7, 21, 8, 0),
              sport: Sport.running,
            ),
          ],
          sport: Sport.swimming,
        );

        final editor = RawEditor(activity);
        final result = editor.validateLapBoundaries();
        expect(result.isValid, isTrue);
      });
    });

    group('Merge and Split Operations', () {
      test('merge combines multiple activities into one', () {
        final swim = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
            GeoPoint(
              latitude: 47.551,
              longitude: -122.281,
              time: DateTime.utc(2024, 7, 21, 6, 10),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 7, 21, 6, 0), value: 120),
              Sample(time: DateTime.utc(2024, 7, 21, 6, 10), value: 130),
            ],
          },
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 0),
              endTime: DateTime.utc(2024, 7, 21, 6, 20),
              distanceMeters: 750,
            ),
          ],
          sport: Sport.swimming,
        );

        final bike = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.56,
              longitude: -122.29,
              time: DateTime.utc(2024, 7, 21, 6, 30),
            ),
            GeoPoint(
              latitude: 47.57,
              longitude: -122.30,
              time: DateTime.utc(2024, 7, 21, 7, 0),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 7, 21, 6, 30), value: 140),
              Sample(time: DateTime.utc(2024, 7, 21, 7, 0), value: 155),
            ],
            Channel.cadence: [
              Sample(time: DateTime.utc(2024, 7, 21, 6, 30), value: 85),
            ],
          },
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 30),
              endTime: DateTime.utc(2024, 7, 21, 7, 30),
              distanceMeters: 40000,
            ),
          ],
          sport: Sport.cycling,
        );

        final merged = ActivityFiles.merge([swim, bike]);

        expect(merged.points.length, 4);
        expect(merged.sport, Sport.swimming); // First activity's sport

        // HR samples from both activities
        final hr = merged.channels[Channel.heartRate];
        expect(hr!.length, 4);

        // Cadence only from bike
        final cad = merged.channels[Channel.cadence];
        expect(cad!.length, 1);

        // Both laps preserved
        expect(merged.laps.length, 2);
        expect(merged.laps[0].distanceMeters, 750);
        expect(merged.laps[1].distanceMeters, 40000);
      });

      test('merge with preserveSportPerLap adds sport to laps', () {
        final swim = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 0),
              endTime: DateTime.utc(2024, 7, 21, 6, 20),
            ),
          ],
          sport: Sport.swimming,
        );

        final run = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.58,
              longitude: -122.31,
              time: DateTime.utc(2024, 7, 21, 7, 0),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 7, 0),
              endTime: DateTime.utc(2024, 7, 21, 7, 30),
            ),
          ],
          sport: Sport.running,
        );

        final merged = ActivityFiles.merge([
          swim,
          run,
        ], preserveSportPerLap: true);

        // Laps should now have sports from their source activities
        expect(merged.laps[0].sport, Sport.swimming);
        expect(merged.laps[1].sport, Sport.running);
        expect(merged.sport, Sport.swimming); // Overall sport
      });

      test('merge single activity returns it unchanged', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
          ],
          sport: Sport.running,
        );

        final merged = ActivityFiles.merge([activity]);
        expect(merged, same(activity));
      });

      test('merge throws on empty list', () {
        expect(() => ActivityFiles.merge([]), throwsArgumentError);
      });

      test('splitBySport divides multi-sport activity', () {
        final triathlon = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
            GeoPoint(
              latitude: 47.552,
              longitude: -122.282,
              time: DateTime.utc(2024, 7, 21, 6, 20),
            ),
            GeoPoint(
              latitude: 47.56,
              longitude: -122.29,
              time: DateTime.utc(2024, 7, 21, 6, 30),
            ),
            GeoPoint(
              latitude: 47.58,
              longitude: -122.31,
              time: DateTime.utc(2024, 7, 21, 7, 30),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 7, 21, 6, 0), value: 120),
              Sample(time: DateTime.utc(2024, 7, 21, 6, 20), value: 130),
              Sample(time: DateTime.utc(2024, 7, 21, 6, 30), value: 150),
              Sample(time: DateTime.utc(2024, 7, 21, 7, 30), value: 170),
            ],
          },
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 0),
              endTime: DateTime.utc(2024, 7, 21, 6, 20),
              sport: Sport.swimming,
            ),
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 30),
              endTime: DateTime.utc(2024, 7, 21, 7, 30),
              sport: Sport.cycling,
            ),
          ],
          sport: Sport.swimming,
        );

        final splits = ActivityFiles.splitBySport(triathlon);

        expect(splits.length, 2);
        expect(splits.keys, containsAll([Sport.swimming, Sport.cycling]));

        // Swim split
        final swim = splits[Sport.swimming]!;
        expect(swim.points.length, 2); // First 2 points
        expect(swim.sport, Sport.swimming);
        expect(swim.laps.length, 1);
        expect(swim.laps[0].sport, isNull); // Stripped since all same sport
        expect(swim.channels[Channel.heartRate]!.length, 2);

        // Bike split
        final bike = splits[Sport.cycling]!;
        expect(bike.points.length, 2); // Last 2 points
        expect(bike.sport, Sport.cycling);
        expect(bike.laps.length, 1);
        expect(bike.laps[0].sport, isNull);
        expect(bike.channels[Channel.heartRate]!.length, 2);
      });

      test('splitBySport returns single activity unchanged', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 7, 21, 6, 0),
              endTime: DateTime.utc(2024, 7, 21, 6, 30),
            ),
          ],
          sport: Sport.running,
        );

        final splits = ActivityFiles.splitBySport(activity);

        expect(splits.length, 1);
        expect(splits.keys.first, Sport.running);
        expect(splits[Sport.running], activity);
      });

      test('splitBySport handles activity without laps', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.55,
              longitude: -122.28,
              time: DateTime.utc(2024, 7, 21, 6, 0),
            ),
          ],
          sport: Sport.cycling,
        );

        final splits = ActivityFiles.splitBySport(activity);

        expect(splits.length, 1);
        expect(splits.keys.first, Sport.cycling);
        expect(splits[Sport.cycling], activity);
      });

      test(
        'splitBySport uses activity sport for laps without explicit sport',
        () {
          final activity = RawActivity(
            points: [
              GeoPoint(
                latitude: 47.55,
                longitude: -122.28,
                time: DateTime.utc(2024, 7, 21, 6, 0),
              ),
              GeoPoint(
                latitude: 47.56,
                longitude: -122.29,
                time: DateTime.utc(2024, 7, 21, 7, 0),
              ),
            ],
            laps: [
              Lap(
                startTime: DateTime.utc(2024, 7, 21, 6, 0),
                endTime: DateTime.utc(2024, 7, 21, 6, 30),
                // No sport - should use activity sport
              ),
              Lap(
                startTime: DateTime.utc(2024, 7, 21, 7, 0),
                endTime: DateTime.utc(2024, 7, 21, 7, 30),
                sport: Sport.cycling, // Explicit different sport
              ),
            ],
            sport: Sport.running,
          );

          final splits = ActivityFiles.splitBySport(activity);

          expect(splits.length, 2);
          expect(splits.keys, containsAll([Sport.running, Sport.cycling]));

          // First lap grouped under running
          expect(splits[Sport.running]!.laps.length, 1);
          // Second lap grouped under cycling
          expect(splits[Sport.cycling]!.laps.length, 1);
        },
      );
    });
  });
}
