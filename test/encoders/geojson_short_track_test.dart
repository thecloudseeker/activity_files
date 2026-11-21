// SPDX-License-Identifier: BSD-3-Clause
/// GeoJSON needs two positions for a LineString (RFC 7946): a track with one
/// point is written as a Point and one with none as a null geometry, and
/// both read back.
library;

import 'dart:convert';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2024, 1, 1, 10);

Map<String, Object?> _geometry(String geojson) {
  final collection = jsonDecode(geojson) as Map<String, Object?>;
  final feature = (collection['features'] as List).single as Map;
  return {'geometry': feature['geometry']};
}

void main() {
  test(
    'one point is a Point and reads back with its time and channels',
    () async {
      final activity = RawActivity(
        sport: Sport.running,
        points: [
          GeoPoint(latitude: 46, longitude: 13, elevation: 500, time: _t0),
        ],
        channels: {
          Channel.heartRate: [Sample(time: _t0, value: 140)],
        },
      );
      final geojson = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.geojson,
      ).encoded;
      final geometry = _geometry(geojson)['geometry'] as Map;
      expect(geometry['type'], 'Point');
      expect(geometry['coordinates'], [13.0, 46.0, 500.0]);

      final back = await ActivityFiles.import(
        geojson,
        format: ActivityFileFormat.geojson,
      );
      expect(back.hasErrors, isFalse);
      expect(back.activity.points.single.time, _t0);
      expect(back.activity.channel(Channel.heartRate).single.value, 140);
      expect(back.activity.sport, Sport.running);
    },
  );

  test('no points is a null geometry and keeps the properties', () async {
    final activity = RawActivity(
      sport: Sport.cycling,
      summary: const ActivitySummary(calories: 300),
    );
    final geojson = ActivityFiles.export(
      activity: activity,
      to: ActivityFileFormat.geojson,
    ).encoded;
    expect(_geometry(geojson)['geometry'], isNull);

    final back = await ActivityFiles.import(
      geojson,
      format: ActivityFileFormat.geojson,
    );
    expect(back.activity.sport, Sport.cycling);
    expect(back.activity.summary?.calories, 300);
    expect(
      back.diagnostics.map((d) => d.code),
      contains('geojson.null_geometry'),
    );
  });

  for (final options in [
    const EncoderOptions(geojsonGeometry: GeojsonGeometry.points),
    const EncoderOptions(
      geojsonGeometry: GeojsonGeometry.points,
      geojsonIncludeChannels: true,
    ),
  ]) {
    test('no points in the point-feature form reads back without an error '
        '(channels: ${options.geojsonIncludeChannels})', () async {
      final geojson = ActivityFiles.export(
        activity: RawActivity(sport: Sport.swimming),
        to: ActivityFileFormat.geojson,
        options: options,
      ).encoded;
      final back = await ActivityFiles.import(
        geojson,
        format: ActivityFileFormat.geojson,
      );
      expect(back.hasErrors, isFalse);
      expect(back.activity.sport, Sport.swimming);
    });
  }

  test('two or more points stay a LineString', () {
    final activity = RawActivity(
      points: [
        GeoPoint(latitude: 46, longitude: 13, time: _t0),
        GeoPoint(
          latitude: 46.001,
          longitude: 13.001,
          time: _t0.add(const Duration(seconds: 10)),
        ),
      ],
    );
    final geojson = ActivityFiles.export(
      activity: activity,
      to: ActivityFileFormat.geojson,
    ).encoded;
    expect((_geometry(geojson)['geometry'] as Map)['type'], 'LineString');
  });
}
