// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for TCX encoder.
///
/// Tests TCX v1/v2 output with activities, laps, trackpoints, and HR/cadence.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  group('TCX Encoder', () {
    group('Basic TCX encoding', () {
      test('encodes activity as TCX v2', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              elevation: 1600,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              elevation: 1605,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
          sport: Sport.running,
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );

        expect(tcxString, contains('<?xml'));
        expect(tcxString, contains('<TrainingCenterDatabase'));
        expect(tcxString, contains('v2'));
        expect(tcxString, contains('<Activities>'));
        expect(tcxString, contains('<Activity'));
      });

      test('encodes trackpoints with coordinates', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              elevation: 1600,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final trkpts = doc.findAllElements('Trackpoint').toList();

        expect(trkpts.length, equals(1));

        final latElement = trkpts[0].findAllElements('LatitudeDegrees').first;
        final lonElement = trkpts[0].findAllElements('LongitudeDegrees').first;

        expect(double.parse(latElement.innerText), equals(40.0));
        expect(double.parse(lonElement.innerText), equals(-105.0));
      });

      test('encodes elevation in trackpoint', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              elevation: 1600.5,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final eleElements = doc.findAllElements('AltitudeMeters').toList();

        expect(eleElements.isNotEmpty, isTrue);
      });

      test('encodes timestamp in trackpoint', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final timeElements = doc.findAllElements('Time').toList();

        expect(timeElements.isNotEmpty, isTrue);
        expect(timeElements[0].innerText, contains('2024-01-01'));
      });
    });

    group('TCX version support', () {
      test('encodes as TCX v1 with option', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );
        final options = EncoderOptions(tcxVersion: TcxVersion.v1);

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
          options: options,
        );

        expect(tcxString, contains('v1'));
      });

      test('defaults to TCX v2', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );

        expect(tcxString, contains('v2'));
      });
    });

    group('Sport type', () {
      test('encodes running sport', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          sport: Sport.running,
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final activityElement = doc.findAllElements('Activity').first;

        expect(activityElement.getAttribute('Sport'), equals('Running'));
      });

      test('encodes cycling sport', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          sport: Sport.cycling,
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final activityElement = doc.findAllElements('Activity').first;

        expect(activityElement.getAttribute('Sport'), equals('Biking'));
      });

      test('encodes swimming sport as Other', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          sport: Sport.swimming,
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final activityElement = doc.findAllElements('Activity').first;

        // TCX only supports Running, Biking, Walking - others map to Other
        expect(activityElement.getAttribute('Sport'), equals('Other'));
      });
    });

    group('Heart rate encoding', () {
      test('includes heart rate in trackpoint', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
            ],
          },
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final hrElements = doc.findAllElements('HeartRateBpm').toList();

        expect(hrElements.isNotEmpty, isTrue);
      });

      test('includes cadence in trackpoint', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {
            Channel.cadence: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 82),
            ],
          },
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final cadElements = doc.findAllElements('Cadence').toList();

        expect(cadElements.isNotEmpty, isTrue);
      });
    });

    group('Lap encoding', () {
      test('creates lap for single activity', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final lapElements = doc.findAllElements('Lap').toList();

        expect(lapElements.isNotEmpty, isTrue);
      });

      test('encodes provided laps', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              time: DateTime.utc(2024, 1, 1, 10, 0, 5),
            ),
            GeoPoint(
              latitude: 40.001,
              longitude: -105.001,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
              endTime: DateTime.utc(2024, 1, 1, 10, 0, 5),
            ),
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 5),
              endTime: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final lapElements = doc.findAllElements('Lap').toList();

        expect(lapElements.length, equals(2));
      });

      test(
        'does not duplicate a trackpoint into two laps with overlapping ranges',
        () {
          final activity = RawActivity(
            points: [
              GeoPoint(
                latitude: 40.0,
                longitude: -105.0,
                time: DateTime.utc(2024, 1, 1, 10, 0, 0),
              ),
              GeoPoint(
                latitude: 40.0001,
                longitude: -105.0001,
                time: DateTime.utc(2024, 1, 1, 10, 0, 10),
              ),
              GeoPoint(
                latitude: 40.0002,
                longitude: -105.0002,
                time: DateTime.utc(2024, 1, 1, 10, 0, 15),
              ),
              GeoPoint(
                latitude: 40.0003,
                longitude: -105.0003,
                time: DateTime.utc(2024, 1, 1, 10, 0, 20),
              ),
            ],
            laps: [
              Lap(
                startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
                endTime: DateTime.utc(2024, 1, 1, 10, 0, 10),
              ),
              Lap(
                startTime: DateTime.utc(2024, 1, 1, 10, 0, 5),
                endTime: DateTime.utc(2024, 1, 1, 10, 0, 20),
              ),
            ],
          );

          final tcxString = ActivityEncoder.encode(
            activity,
            ActivityFileFormat.tcx,
          );
          final doc = XmlDocument.parse(tcxString);
          final times = doc.findAllElements('Time').toList();

          expect(times, hasLength(4));
        },
      );

      test('encodes lap distance', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          laps: [
            Lap(
              startTime: DateTime.utc(2024, 1, 1, 10, 0, 0),
              endTime: DateTime.utc(2024, 1, 1, 10, 0, 10),
              distanceMeters: 100,
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final distElements = doc.findAllElements('DistanceMeters').toList();

        expect(distElements.isNotEmpty, isTrue);
      });

      test('encodes lap start time', () {
        final startTime = DateTime.utc(2024, 1, 1, 10, 0, 0);
        final activity = RawActivity(
          points: [
            GeoPoint(latitude: 40.0, longitude: -105.0, time: startTime),
          ],
          laps: [
            Lap(
              startTime: startTime,
              endTime: startTime.add(const Duration(seconds: 10)),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final lapElement = doc.findAllElements('Lap').first;

        expect(lapElement.getAttribute('StartTime'), contains('2024-01-01'));
      });
    });

    group('Multi-sport Activity splitting', () {
      test('a point sitting exactly on a sport-to-sport boundary is written '
          'to both <Activity> Tracks, not dropped from the second', () {
        final base = DateTime.utc(2024, 1, 1, 10);
        final points = [
          for (var i = 0; i <= 4; i++)
            GeoPoint(
              latitude: 40.0 + i * 0.001,
              longitude: -105.0,
              time: base.add(Duration(seconds: i)),
            ),
        ];
        final laps = [
          Lap(
            startTime: base,
            endTime: base.add(const Duration(seconds: 2)),
            sport: Sport.swimming,
            name: 'Lap 1',
          ),
          Lap(
            startTime: base.add(const Duration(seconds: 2)),
            endTime: base.add(const Duration(seconds: 4)),
            sport: Sport.cycling,
            name: 'Lap 2',
          ),
        ];
        final activity = RawActivity(
          points: points,
          laps: laps,
          sport: Sport.swimming,
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final activityElements = doc.findAllElements('Activity').toList();

        expect(activityElements, hasLength(2));
        final cyclingTrackpoints = activityElements
            .firstWhere((e) => e.getAttribute('Sport') == 'Biking')
            .findAllElements('Trackpoint');
        expect(
          cyclingTrackpoints.first.findElements('Time').first.innerText,
          equals(base.add(const Duration(seconds: 2)).toIso8601String()),
        );
        expect(cyclingTrackpoints, hasLength(3));
      });
    });

    group('Empty activities', () {
      test('encodes empty activity as valid TCX', () {
        final activity = RawActivity();

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );

        // Should parse without error
        final doc = XmlDocument.parse(tcxString);
        expect(doc.rootElement.name.local, equals('TrainingCenterDatabase'));
      });
    });

    group('Precision', () {
      test('preserves coordinate precision', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.123456,
              longitude: -105.654321,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final latElement = doc.findAllElements('LatitudeDegrees').first;
        final lonElement = doc.findAllElements('LongitudeDegrees').first;

        expect(double.parse(latElement.innerText), closeTo(40.123456, 1e-6));
        expect(double.parse(lonElement.innerText), closeTo(-105.654321, 1e-6));
      });

      test('preserves elevation precision', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              elevation: 1600.123,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final eleElement = doc.findAllElements('AltitudeMeters').first;

        expect(double.parse(eleElement.innerText), closeTo(1600.123, 1e-2));
      });

      test('encodes heart rate as integer', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140.7),
            ],
          },
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final valueElements = doc.findAllElements('Value').toList();

        expect(valueElements.isNotEmpty, isTrue);
      });
    });

    group('Activity ID', () {
      test('includes activity ID based on first trackpoint time', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final idElements = doc.findAllElements('Id').toList();

        expect(idElements.isNotEmpty, isTrue);
        expect(idElements[0].innerText, contains('2024-01-01'));
      });
    });

    group('Roundtrip', () {
      test('encode/decode roundtrip preserves trackpoints', () {
        final original = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              elevation: 1600,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
            GeoPoint(
              latitude: 40.0005,
              longitude: -105.0005,
              elevation: 1605,
              time: DateTime.utc(2024, 1, 1, 10, 0, 10),
            ),
          ],
          sport: Sport.running,
        );

        final tcxString = ActivityEncoder.encode(
          original,
          ActivityFileFormat.tcx,
        );
        final parsed = ActivityParser.parse(tcxString, ActivityFileFormat.tcx);

        expect(parsed.activity.points.length, equals(original.points.length));
        expect(parsed.activity.sport, equals(Sport.running));
      });

      test('encode/decode roundtrip preserves heart rate', () {
        final original = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          channels: {
            Channel.heartRate: [
              Sample(time: DateTime.utc(2024, 1, 1, 10, 0, 0), value: 140),
            ],
          },
        );

        final tcxString = ActivityEncoder.encode(
          original,
          ActivityFileFormat.tcx,
        );
        final parsed = ActivityParser.parse(tcxString, ActivityFileFormat.tcx);

        expect(parsed.activity.channel(Channel.heartRate).length, equals(1));
        expect(
          parsed.activity.channel(Channel.heartRate)[0].value,
          equals(140),
        );
      });
    });

    group('Foreign extension namespaces', () {
      test(
        'a source ns3 prefix bound to a foreign schema is moved to a '
        'free prefix instead of being silently rebound to ActivityExtension',
        () {
          const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:ns3="http://example.com/CustomSchema/v1">
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
      <Extensions>
        <ns3:CustomStat>42</ns3:CustomStat>
      </Extensions>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';
          final parsed = ActivityParser.parse(tcx, ActivityFileFormat.tcx);
          final reencoded = ActivityEncoder.encode(
            parsed.activity,
            ActivityFileFormat.tcx,
          );
          final doc = XmlDocument.parse(reencoded);
          final root = doc.rootElement;

          // ns3 must still resolve to Garmin's own ActivityExtension schema
          // (TPX/LX writing elsewhere hardcodes the `ns3:` prefix literally).
          expect(
            root.getAttribute('xmlns:ns3'),
            equals('http://www.garmin.com/xmlschemas/ActivityExtension/v2'),
          );
          // The foreign schema must still be declared, just under a different,
          // free prefix, with its element re-tagged to match.
          final foreignPrefix = root.attributes
              .firstWhere(
                (a) => a.value == 'http://example.com/CustomSchema/v1',
              )
              .name
              .local
              .split(':')
              .last;
          expect(foreignPrefix, isNot(equals('ns3')));
          expect(
            doc.findAllElements('$foreignPrefix:CustomStat'),
            hasLength(1),
          );
        },
      );
    });

    group('Creator vs. device metadata', () {
      test('a distinct activity.creator survives a round trip instead of '
          'being overwritten by device.model', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 47.0,
              longitude: 8.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          creator: 'ActivityFilesTestSuite',
          device: const ActivityDeviceMetadata(
            manufacturer: 'Garmin',
            model: 'Fenix 7',
          ),
        );

        final tcxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.tcx,
        );
        final doc = XmlDocument.parse(tcxString);
        final parsed = ActivityParser.parse(tcxString, ActivityFileFormat.tcx);

        // TCX's Device_t <Creator> has only one <Name> slot, shared between
        // "creator" and "device model" -- so the two can't both survive when
        // they differ; the fix is specifically that creator wins that slot
        // rather than being silently replaced by the device model.
        expect(
          doc
              .findAllElements('Creator')
              .single
              .findElements('Name')
              .single
              .innerText,
          equals('ActivityFilesTestSuite'),
        );
        expect(parsed.activity.creator, equals('ActivityFilesTestSuite'));
      });
    });
  });
}
