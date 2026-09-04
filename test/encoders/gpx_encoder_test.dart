// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for GPX encoder.
///
/// Tests GPX v1.0/v1.1 output with tracks, extensions, and metadata.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  group('GPX Encoder', () {
    group('Basic GPX encoding', () {
      test('encodes activity as GPX 1.1 track', () {
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
          creator: 'test-device',
        );

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('<?xml'));
        expect(gpxString, contains('<gpx'));
        expect(gpxString, contains('version="1.1"'));
        expect(gpxString, contains('<trk>'));
        expect(gpxString, contains('<trkpt'));
      });

      test('encodes trackpoints with coordinates', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );
        final doc = XmlDocument.parse(gpxString);
        final trkpts = doc.findAllElements('trkpt').toList();

        expect(trkpts.length, equals(1));
        expect(
          double.parse(trkpts[0].getAttribute('lat')!),
          closeTo(40.0, 1e-6),
        );
        expect(
          double.parse(trkpts[0].getAttribute('lon')!),
          closeTo(-105.0, 1e-6),
        );
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

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );
        final doc = XmlDocument.parse(gpxString);
        final eleElement = doc.findAllElements('ele').first;

        expect(eleElement.innerText, isNotEmpty);
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

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );
        final doc = XmlDocument.parse(gpxString);
        final timeElement = doc.findAllElements('time').first;

        expect(timeElement.innerText, contains('2024-01-01'));
      });
    });

    group('GPX version support', () {
      test('encodes as GPX 1.0 with option', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );
        final options = EncoderOptions(gpxVersion: GpxVersion.v1_0);

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
          options: options,
        );

        expect(gpxString, contains('version="1.0"'));
        expect(gpxString, contains('http://www.topografix.com/GPX/1/0'));
      });

      test('defaults to GPX 1.1', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('version="1.1"'));
      });
    });

    group('Garmin TrackPointExtension', () {
      test('includes TrackPointExtension for heart rate', () {
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

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('gpxtpx'));
        expect(gpxString, contains('<gpxtpx:hr>'));
      });

      test('includes cadence in TrackPointExtension', () {
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

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('gpxtpx'));
        expect(gpxString, contains('<gpxtpx:cad>'));
      });

      test('writes a channel outside the fixed whitelist as an extra tag', () {
        final time = DateTime.utc(2024, 1, 1, 10, 0, 0);
        final activity = RawActivity(
          points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: time)],
          channels: {
            Channel.custom('grade'): [Sample(time: time, value: 3.2)],
            Channel.distance: [Sample(time: time, value: 100.0)],
          },
        );

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('<gpxtpx:grade>3.2</gpxtpx:grade>'));
        expect(gpxString, contains('<gpxtpx:distance>100.0</gpxtpx:distance>'));
      });

      test('sanitizes a channel id that is not a valid XML element name', () {
        final time = DateTime.utc(2024, 1, 1, 10, 0, 0);
        final activity = RawActivity(
          points: [GeoPoint(latitude: 40.0, longitude: -105.0, time: time)],
          channels: {
            Channel.custom('left leg power'): [Sample(time: time, value: 210)],
          },
        );

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('<gpxtpx:left_leg_power>210.0'));
        // Must still be well-formed XML.
        expect(() => XmlDocument.parse(gpxString), returnsNormally);
      });
    });

    group('Metadata', () {
      test('includes creator attribute', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          creator: 'Garmin BaseCamp',
        );

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('creator="Garmin BaseCamp"'));
      });

      test('defaults to activity_files creator if not provided', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
        );

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('creator="activity_files"'));
      });

      test('includes metadata with name and description', () {
        final activity = RawActivity(
          points: [
            GeoPoint(
              latitude: 40.0,
              longitude: -105.0,
              time: DateTime.utc(2024, 1, 1, 10, 0, 0),
            ),
          ],
          gpxMetadataName: 'Morning Run',
          gpxMetadataDescription: 'Sample activity',
        );

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        expect(gpxString, contains('<metadata>'));
        expect(gpxString, contains('Morning Run'));
        expect(gpxString, contains('Sample activity'));
      });
    });

    group('Empty activities', () {
      test('encodes empty activity as valid GPX', () {
        final activity = RawActivity();

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );

        // Should parse without error
        final doc = XmlDocument.parse(gpxString);
        expect(doc.rootElement.name.local, equals('gpx'));
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

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );
        final doc = XmlDocument.parse(gpxString);
        final trkpts = doc.findAllElements('trkpt').toList();

        // Check precision is maintained
        final lat = double.parse(trkpts[0].getAttribute('lat')!);
        final lon = double.parse(trkpts[0].getAttribute('lon')!);
        expect(lat, closeTo(40.123456, 1e-6));
        expect(lon, closeTo(-105.654321, 1e-6));
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

        final gpxString = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.gpx,
        );
        final doc = XmlDocument.parse(gpxString);
        final eleText = doc.findAllElements('ele').first.innerText;

        expect(eleText, contains('1600'));
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
        );

        final gpxString = ActivityEncoder.encode(
          original,
          ActivityFileFormat.gpx,
        );
        final parsed = ActivityParser.parse(gpxString, ActivityFileFormat.gpx);

        expect(parsed.activity.points.length, equals(original.points.length));
      });
    });

    group('Track segments', () {
      test('overlapping-in-time segments keep their own points on re-encode '
          'instead of getting scrambled by a global time sort', () {
        const gpx = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>Workout</name>
    <trkseg>
      <trkpt lat="10.0" lon="10.0"><time>2024-01-01T10:00:00Z</time></trkpt>
      <trkpt lat="10.1" lon="10.1"><time>2024-01-01T10:10:00Z</time></trkpt>
    </trkseg>
    <trkseg>
      <trkpt lat="20.0" lon="20.0"><time>2024-01-01T10:05:00Z</time></trkpt>
      <trkpt lat="20.1" lon="20.1"><time>2024-01-01T10:15:00Z</time></trkpt>
    </trkseg>
  </trk>
</gpx>''';
        final parsed = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
        final reencoded = ActivityEncoder.encode(
          parsed.activity,
          ActivityFileFormat.gpx,
        );
        final doc = XmlDocument.parse(reencoded);
        final segments = doc.findAllElements('trkseg').toList();

        expect(segments, hasLength(2));
        final firstSegLats = segments[0]
            .findElements('trkpt')
            .map((e) => double.parse(e.getAttribute('lat')!))
            .toList();
        final secondSegLats = segments[1]
            .findElements('trkpt')
            .map((e) => double.parse(e.getAttribute('lat')!))
            .toList();
        expect(firstSegLats, everyElement(closeTo(10.0, 0.2)));
        expect(secondSegLats, everyElement(closeTo(20.0, 0.2)));
      });
    });

    group('Route metadata', () {
      test('a non-standard <rte> child element (e.g. <link>) survives a '
          'parse -> encode round trip', () {
        const gpx = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <rte>
    <name>Planned Loop</name>
    <cmt>scenic</cmt>
    <link href="https://example.com"><text>More info</text></link>
    <rtept lat="47.0" lon="11.0"></rtept>
  </rte>
</gpx>''';
        final parsed = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
        expect(parsed.activity.gpxRoutes.single.metadata['link'], isNotNull);

        final reencoded = ActivityEncoder.encode(
          parsed.activity,
          ActivityFileFormat.gpx,
        );
        final doc = XmlDocument.parse(reencoded);
        final route = doc.findAllElements('rte').single;

        expect(route.findElements('cmt').single.innerText, equals('scenic'));
        expect(
          route.findElements('link').single.innerText,
          equals('More info'),
        );
      });
    });
  });
}
