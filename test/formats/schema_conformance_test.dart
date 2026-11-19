// SPDX-License-Identifier: BSD-3-Clause
/// GPX and TCX output follows the official schemas without losing data: what
/// a schema cannot hold goes into the extension areas under the library's
/// namespace, and a value written only to satisfy the schema reads back as
/// absent.
///
/// When `dev/fixtures/schemas/` holds `gpx11.xsd` and `tcx2.xsd` and
/// `xmllint` is installed, the written files are also validated against
/// them; otherwise that part is skipped.
@TestOn('vm')
library;

import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2024, 1, 1, 10);

final _trackTag = GpxExtensionNode(
  name: 'trackTag',
  namespacePrefix: 'ex',
  namespaceUri: 'https://example.com/ext',
  value: 'v',
);

const _device = ActivityDeviceMetadata(
  manufacturer: 'Garmin',
  model: 'Fenix 7',
  product: '3906',
  serialNumber: '3412345678',
  softwareVersion: '12.3',
  fitManufacturerId: 1,
  fitProductId: 3906,
);

RawActivity _activity({
  Sport sport = Sport.running,
  ActivityDeviceMetadata? device = _device,
  String? creator = 'My App',
  List<Lap>? laps,
  double zeroHeartRateAt = -1,
}) => RawActivity(
  sport: sport,
  creator: creator,
  device: device,
  points: [
    for (var i = 0; i < 4; i++)
      GeoPoint(
        latitude: 46 + i / 1e3,
        longitude: 13,
        elevation: 500,
        time: _t0.add(Duration(seconds: i * 10)),
      ),
  ],
  channels: {
    Channel.heartRate: [
      for (var i = 0; i < 4; i++)
        Sample(
          time: _t0.add(Duration(seconds: i * 10)),
          value: i == zeroHeartRateAt ? 0 : 140,
        ),
    ],
  },
  laps: laps,
);

Future<RawActivity> _roundTrip(
  RawActivity activity,
  ActivityFileFormat format, {
  EncoderOptions options = const EncoderOptions(),
}) async {
  final encoded = ActivityFiles.export(
    activity: activity,
    to: format,
    options: options,
  ).encoded;
  return (await ActivityFiles.import(encoded, format: format)).activity;
}

void main() {
  group('device and creator', () {
    for (final (label, format, options) in [
      ('GPX 1.1', ActivityFileFormat.gpx, const EncoderOptions()),
      (
        'GPX 1.0',
        ActivityFileFormat.gpx,
        const EncoderOptions(gpxVersion: GpxVersion.v1_0),
      ),
      ('TCX', ActivityFileFormat.tcx, const EncoderOptions()),
    ]) {
      test('every device field survives $label', () async {
        final back = await _roundTrip(_activity(), format, options: options);
        final device = back.device!;
        expect(device.manufacturer, _device.manufacturer);
        expect(device.model, _device.model);
        expect(device.product, _device.product);
        expect(device.serialNumber, _device.serialNumber);
        expect(device.softwareVersion, _device.softwareVersion);
        expect(device.fitManufacturerId, _device.fitManufacturerId);
        expect(device.fitProductId, _device.fitProductId);
      });
    }

    test('a TCX creator label without a device survives', () async {
      final back = await _roundTrip(
        _activity(device: null),
        ActivityFileFormat.tcx,
      );
      expect(back.creator, 'My App');
      expect(back.device, isNull);
    });

    test(
      'TCX writes a Device_t creator only when all its fields are known',
      () {
        String tcx(ActivityDeviceMetadata device) => ActivityFiles.export(
          activity: _activity(device: device),
          to: ActivityFileFormat.tcx,
        ).encoded;
        expect(tcx(_device), contains('<Creator xsi:type="Device_t">'));
        expect(
          tcx(const ActivityDeviceMetadata(manufacturer: 'Garmin')),
          isNot(contains('<Creator')),
        );
      },
    );

    test(
      'a GPX device in the earlier form, without a namespace, is read',
      () async {
        const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" creator="old" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata><extensions><device><manufacturer>Garmin</manufacturer>
    <model>Edge</model></device></extensions></metadata>
  <trk><trkseg><trkpt lat="46" lon="13"><time>2024-01-01T10:00:00Z</time></trkpt></trkseg></trk>
</gpx>''';
        final back = await ActivityFiles.import(
          gpx,
          format: ActivityFileFormat.gpx,
        );
        expect(back.activity.device?.manufacturer, 'Garmin');
        expect(back.activity.device?.model, 'Edge');
        expect(back.activity.gpxMetadataExtensions, isEmpty);
      },
    );

    test('a deviceNode() among the metadata extensions is written once', () {
      final activity = _activity().copyWith(
        gpxMetadataExtensions: [RawActivityBuilder.deviceNode(_device)],
      );
      final gpx = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.gpx,
      ).encoded;
      expect(RegExp('<manufacturer>').allMatches(gpx), hasLength(1));
    });
  });

  test('TCX keeps track extensions outside <Track>', () async {
    final activity = _activity().copyWith(gpxTrackExtensions: [_trackTag]);
    final encoded = ActivityFiles.export(
      activity: activity,
      to: ActivityFileFormat.tcx,
    ).encoded;
    expect(encoded, isNot(contains(RegExp(r'<Track>\s*<Extensions>'))));
    final back = (await ActivityFiles.import(
      encoded,
      format: ActivityFileFormat.tcx,
    )).activity;
    expect(back.gpxTrackExtensions.single.value, 'v');
  });

  test('a TCX lap without points gets no empty <Track>', () {
    final activity = _activity(
      laps: [
        Lap(startTime: _t0, endTime: _t0.add(const Duration(seconds: 30))),
        Lap(
          startTime: _t0.add(const Duration(hours: 1)),
          endTime: _t0.add(const Duration(hours: 2)),
        ),
      ],
    );
    final encoded = ActivityFiles.export(
      activity: activity,
      to: ActivityFileFormat.tcx,
      normalize: false,
    ).encoded;
    expect(encoded, isNot(contains(RegExp(r'<Track>\s*</Track>|<Track/>'))));
    expect(RegExp('<Lap ').allMatches(encoded), hasLength(2));
  });

  group('TCX laps', () {
    test('defaults written for the schema read back as absent', () async {
      final back = await _roundTrip(
        _activity(
          laps: [
            Lap(startTime: _t0, endTime: _t0.add(const Duration(seconds: 30))),
          ],
        ),
        ActivityFileFormat.tcx,
      );
      final lap = back.laps.single;
      expect(lap.calories, isNull);
      expect(lap.tcxIntensity, isNull);
      expect(lap.tcxTriggerMethod, isNull);
    });

    test('real values, including 0 calories, read back', () async {
      final back = await _roundTrip(
        _activity(
          laps: [
            Lap(
              startTime: _t0,
              endTime: _t0.add(const Duration(seconds: 30)),
              calories: 0,
              tcxIntensity: 'Resting',
              tcxTriggerMethod: 'Distance',
            ),
          ],
        ),
        ActivityFileFormat.tcx,
      );
      final lap = back.laps.single;
      expect(lap.calories, 0);
      expect(lap.tcxIntensity, 'Resting');
      expect(lap.tcxTriggerMethod, 'Distance');
    });
  });

  group('TCX sport and heart rate', () {
    test('a sport TCX cannot name is written as Other and reported', () {
      final result = ActivityFiles.export(
        activity: _activity(sport: Sport.walking),
        to: ActivityFileFormat.tcx,
      );
      expect(result.encoded, contains('Sport="Other"'));
      expect(
        result.diagnostics.map((d) => d.code),
        contains('lossy.sport_generalized'),
      );
    });

    test('FIT reports that it cannot hold Sport.other', () {
      final result = ActivityFiles.export(
        activity: _activity(sport: Sport.other),
        to: ActivityFileFormat.fit,
      );
      expect(
        result.diagnostics.map((d) => d.code),
        contains('lossy.sport_generalized'),
      );
    });

    test('a heart rate of 0 is left out and reported', () {
      final result = ActivityFiles.export(
        activity: _activity(zeroHeartRateAt: 1),
        to: ActivityFileFormat.tcx,
        normalize: false,
      );
      expect(result.encoded, isNot(contains('<Value>0</Value>')));
      expect(
        result.diagnostics.map((d) => d.code),
        contains('lossy.heart_rate_zero_dropped'),
      );
    });
  });

  test('GPX 1.0 extension content reads back without an <extensions> '
      'element', () async {
    final activity = _activity().copyWith(gpxTrackType: 'Trail');
    final encoded = ActivityFiles.export(
      activity: activity,
      to: ActivityFileFormat.gpx,
      options: const EncoderOptions(gpxVersion: GpxVersion.v1_0),
    ).encoded;
    expect(encoded, isNot(contains('<extensions>')));
    final back = (await ActivityFiles.import(
      encoded,
      format: ActivityFileFormat.gpx,
    )).activity;
    expect(back.channel(Channel.heartRate), hasLength(4));
    expect(back.gpxTrackType, 'Trail');
    expect(back.gpxTrackExtensions, isEmpty);
  });

  group('official schemas', () {
    final schemas = Directory('dev/fixtures/schemas');
    final hasXmllint = Process.runSync('which', ['xmllint']).exitCode == 0;
    final skip = !schemas.existsSync() || !hasXmllint
        ? 'needs dev/fixtures/schemas and xmllint'
        : false;

    for (final (label, format, schema) in [
      ('GPX 1.1', ActivityFileFormat.gpx, 'gpx11.xsd'),
      ('TCX v2', ActivityFileFormat.tcx, 'tcx2.xsd'),
    ]) {
      test('a fully populated $label export validates', () {
        final activity =
            _activity(
              laps: [
                Lap(
                  startTime: _t0,
                  endTime: _t0.add(const Duration(seconds: 30)),
                ),
              ],
            ).copyWith(
              tcxNotes: 'note',
              gpxTrackExtensions: [_trackTag],
              gpxWaypoints: [
                GeoPoint(
                  latitude: 46.5,
                  longitude: 13.5,
                  elevation: 600,
                  time: _t0,
                  gpxAttributes: {'name': 'Hut', 'sym': 'Flag'},
                ),
              ],
              gpxRoutes: [
                GpxRoute(
                  name: 'r',
                  points: [
                    GeoPoint(latitude: 46.6, longitude: 13.6, time: _t0),
                  ],
                ),
              ],
            );
        final dir = Directory.systemTemp.createTempSync('schema');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/out.${format.name}')
          ..writeAsStringSync(
            ActivityFiles.export(activity: activity, to: format).encoded,
          );
        final result = Process.runSync('xmllint', [
          '--noout',
          '--schema',
          '${schemas.path}/$schema',
          file.path,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }, skip: skip);
    }
  });
}
