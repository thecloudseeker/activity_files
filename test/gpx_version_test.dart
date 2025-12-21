// SPDX-License-Identifier: BSD-3-Clause
import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  const gpx10Sample = '''
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

  test('parses GPX 1.0 trackpoints and extensions', () {
    final result = ActivityParser.parse(gpx10Sample, ActivityFileFormat.gpx);
    expect(
      result.diagnostics.where((d) => d.severity == ParseSeverity.error),
      isEmpty,
    );
    expect(result.activity.points, hasLength(2));
    expect(result.activity.gpxTrackName, equals('Sample 1.0'));
    expect(
      result.activity.channel(Channel.heartRate),
      hasLength(1),
      reason: 'HR extension should be captured from GPX 1.0 payload',
    );
  });

  test('encodes GPX 1.0 when requested', () {
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
      sport: Sport.running,
      gpxMetadataName: 'Meta 1.0',
      gpxMetadataDescription: 'Desc 1.0',
      gpxTrackName: 'Track 1.0',
    );
    final xml = ActivityEncoder.encode(
      activity,
      ActivityFileFormat.gpx,
      options: const EncoderOptions(gpxVersion: GpxVersion.v1_0),
    );
    expect(xml, contains('version="1.0"'));
    expect(xml, contains('http://www.topografix.com/GPX/1/0'));
    expect(xml, contains('GPX/1/0/gpx.xsd'));
    expect(xml, isNot(contains('<metadata>')));
    expect(xml, contains('<name>Meta 1.0</name>'));
    expect(xml, contains('<name>Track 1.0</name>'));
  });

  test('conversion can target GPX 1.0', () async {
    final conversion = await ActivityFiles.convert(
      source: gpx10Sample,
      from: ActivityFileFormat.gpx,
      to: ActivityFileFormat.gpx,
      options: const EncoderOptions(gpxVersion: GpxVersion.v1_0),
      useIsolate: false,
    );
    final output = conversion.asString();
    expect(output, contains('version="1.0"'));

    final roundTrip = ActivityParser.parse(
      output,
      ActivityFileFormat.gpx,
    ).activity;
    expect(roundTrip.points, hasLength(2));
  });
}
