// SPDX-License-Identifier: BSD-3-Clause
/// Every numeric field of an activity built in code, set to a non-finite or
/// extreme value, goes through every encoder: no export throws, no output
/// holds a literal `NaN` or `Infinity`, and every output reads back.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

const _nonFinite = [double.nan, double.infinity, double.negativeInfinity];
const _extreme = [1e308, -1e308, 5e-324, -0.0];

final _t0 = DateTime.utc(2024, 1, 1, 10);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

List<GeoPoint> _points({double? lat, double? lon, double? ele}) => [
  for (var i = 0; i < 3; i++)
    GeoPoint(
      latitude: i == 1 && lat != null ? lat : 46.0 + i * 0.001,
      longitude: i == 1 && lon != null ? lon : 13.0 + i * 0.001,
      elevation: i == 1 && ele != null ? ele : 500.0 + i,
      time: _at(i * 10),
    ),
];

Lap _lap({
  double? distance,
  double? calories,
  double? avgSpeed,
  double? maxSpeed,
  double? avgHr,
  double? maxHr,
  double? avgCadence,
  double? maxCadence,
  double? avgPower,
  double? maxPower,
  double? extra,
}) => Lap(
  startTime: _at(0),
  endTime: _at(20),
  distanceMeters: distance ?? 200,
  calories: calories ?? 10,
  avgSpeed: avgSpeed ?? 3,
  maxSpeed: maxSpeed ?? 4,
  avgHeartRate: avgHr ?? 140,
  maxHeartRate: maxHr ?? 150,
  avgCadence: avgCadence ?? 80,
  maxCadence: maxCadence ?? 90,
  avgPower: avgPower ?? 200,
  maxPower: maxPower ?? 300,
  extraFitFields: {200: extra ?? 1},
  extraFitArrays: {
    201: [1, extra ?? 2],
  },
);

ActivitySummary _summary({
  double? distance,
  double? avgSpeed,
  double? avgHr,
  double? calories,
  double? avgPower,
  double? pool,
  double? strokes,
  double? extra,
}) => ActivitySummary(
  totalDistanceMeters: distance ?? 200,
  avgSpeed: avgSpeed ?? 3,
  maxSpeed: 4,
  avgHeartRate: avgHr ?? 140,
  maxHeartRate: 150,
  avgCadence: 80,
  maxCadence: 90,
  avgPower: avgPower ?? 200,
  maxPower: 300,
  calories: calories ?? 10,
  poolLengthMeters: pool ?? 25,
  avgStrokeCount: strokes ?? 10,
  extraFitFields: {200: extra ?? 1},
  extraFitArrays: {
    201: [1, extra ?? 2],
  },
);

RawActivity _activity({
  List<GeoPoint>? points,
  double? sample,
  Channel channel = Channel.heartRate,
  Lap? lap,
  ActivitySummary? summary,
  double? weight,
  double? lengthSpeed,
  double? waypointEle,
  double? routeLat,
  double? trackLat,
  Object? metadataValue,
}) => RawActivity(
  points: points ?? _points(),
  channels: {
    Channel.heartRate: [
      for (var i = 0; i < 3; i++) Sample(time: _at(i * 10), value: 140.0 + i),
    ],
    if (sample != null)
      channel: [
        Sample(time: _at(0), value: 1),
        Sample(time: _at(10), value: sample),
      ],
  },
  laps: [lap ?? _lap()],
  summary: summary ?? _summary(),
  sets: [
    WorkoutSet(
      startTime: _at(0),
      endTime: _at(10),
      isRest: false,
      repetitions: 10,
      weightKg: weight ?? 20,
    ),
  ],
  lengths: [
    SwimLength(
      startTime: _at(0),
      endTime: _at(10),
      isActive: true,
      totalStrokes: 8,
      avgSpeed: lengthSpeed ?? 1.2,
    ),
  ],
  additionalSessions: [summary ?? _summary()],
  gpxWaypoints: [
    GeoPoint(
      latitude: 46.5,
      longitude: 13.5,
      elevation: waypointEle ?? 600,
      time: _at(0),
    ),
  ],
  gpxRoutes: [
    GpxRoute(
      name: 'route',
      points: [
        GeoPoint(latitude: routeLat ?? 46.6, longitude: 13.6, time: _at(0)),
      ],
    ),
  ],
  additionalTracks: [RawActivity(points: _points(lat: trackLat))],
  metadata: {'note': 'x', 'value': ?metadataValue},
);

/// One activity per numeric field, with that field set to [value].
Map<String, RawActivity> _cases(double value) => {
  'point latitude': _activity(points: _points(lat: value)),
  'point longitude': _activity(points: _points(lon: value)),
  'point elevation': _activity(points: _points(ele: value)),
  'heart rate sample': _activity(sample: value),
  'distance sample': _activity(sample: value, channel: Channel.distance),
  'speed sample': _activity(sample: value, channel: Channel.speed),
  'custom sample': _activity(sample: value, channel: Channel.custom('x')),
  'lap distance': _activity(lap: _lap(distance: value)),
  'lap calories': _activity(lap: _lap(calories: value)),
  'lap avg speed': _activity(lap: _lap(avgSpeed: value)),
  'lap max speed': _activity(lap: _lap(maxSpeed: value)),
  'lap avg heart rate': _activity(lap: _lap(avgHr: value)),
  'lap max heart rate': _activity(lap: _lap(maxHr: value)),
  'lap avg cadence': _activity(lap: _lap(avgCadence: value)),
  'lap max cadence': _activity(lap: _lap(maxCadence: value)),
  'lap avg power': _activity(lap: _lap(avgPower: value)),
  'lap max power': _activity(lap: _lap(maxPower: value)),
  'lap raw FIT field': _activity(lap: _lap(extra: value)),
  'summary distance': _activity(summary: _summary(distance: value)),
  'summary avg speed': _activity(summary: _summary(avgSpeed: value)),
  'summary avg heart rate': _activity(summary: _summary(avgHr: value)),
  'summary calories': _activity(summary: _summary(calories: value)),
  'summary avg power': _activity(summary: _summary(avgPower: value)),
  'summary pool length': _activity(summary: _summary(pool: value)),
  'summary stroke count': _activity(summary: _summary(strokes: value)),
  'summary raw FIT field': _activity(summary: _summary(extra: value)),
  'set weight': _activity(weight: value),
  'swim length speed': _activity(lengthSpeed: value),
  'waypoint elevation': _activity(waypointEle: value),
  'route point latitude': _activity(routeLat: value),
  'additional track latitude': _activity(trackLat: value),
  'metadata value': _activity(metadataValue: value),
};

const _targets = <(String, ActivityFileFormat, EncoderOptions)>[
  ('GPX 1.1', ActivityFileFormat.gpx, EncoderOptions()),
  (
    'GPX 1.0',
    ActivityFileFormat.gpx,
    EncoderOptions(gpxVersion: GpxVersion.v1_0),
  ),
  ('TCX', ActivityFileFormat.tcx, EncoderOptions()),
  ('FIT', ActivityFileFormat.fit, EncoderOptions()),
  ('CSV', ActivityFileFormat.csv, EncoderOptions()),
  ('GeoJSON line', ActivityFileFormat.geojson, EncoderOptions()),
  (
    'GeoJSON points',
    ActivityFileFormat.geojson,
    EncoderOptions(geojsonGeometry: GeojsonGeometry.points),
  ),
  (
    'GeoJSON points with channels',
    ActivityFileFormat.geojson,
    EncoderOptions(
      geojsonGeometry: GeojsonGeometry.points,
      geojsonIncludeChannels: true,
    ),
  ),
];

final _nonFiniteLiteral = RegExp(r'NaN|Infinity');

Future<void> _check(
  RawActivity activity,
  ActivityFileFormat to,
  EncoderOptions options, {
  required bool normalize,
  required bool expectReport,
}) async {
  final result = ActivityFiles.export(
    activity: activity,
    to: to,
    options: options,
    normalize: normalize,
  );
  if (to != ActivityFileFormat.fit) {
    expect(result.encoded, isNot(contains(_nonFiniteLiteral)));
  }
  if (expectReport && !normalize) {
    expect(
      result.diagnostics.map((d) => d.code),
      contains('repaired.non_finite_dropped'),
    );
  }
  final source = to == ActivityFileFormat.fit
      ? result.asBytes()
      : result.encoded;
  final back = await ActivityFiles.import(source, format: to);
  for (final point in back.activity.points) {
    expect(point.latitude.isFinite && point.longitude.isFinite, isTrue);
  }
}

void main() {
  test('a channel with an empty id exports to every format', () async {
    final activity = _activity(sample: 1, channel: Channel.custom(''));
    for (final (_, format, options) in _targets) {
      await _check(
        activity,
        format,
        options,
        normalize: false,
        expectReport: false,
      );
    }
  });

  test('a latitude of 1e308 without laps gives no NaN lap distance', () {
    final encoded = ActivityFiles.export(
      activity: RawActivity(points: _points(lat: 1e308)),
      to: ActivityFileFormat.tcx,
      normalize: false,
    ).encoded;
    expect(encoded, isNot(contains('NaN')));
    expect(encoded, isNot(contains('Infinity')));
  });

  test('metadata values JSON cannot hold are left out of GeoJSON', () async {
    final result = ActivityFiles.export(
      activity: RawActivity(
        points: _points(),
        metadata: {
          'date': DateTime.utc(2024),
          'nested': {'k': DateTime.utc(2024)},
          'note': 'kept',
        },
      ),
      to: ActivityFileFormat.geojson,
    );
    expect(
      result.diagnostics.map((d) => d.code),
      contains('lossy.metadata_values_dropped'),
    );
    final back = await ActivityFiles.import(
      result.encoded,
      format: ActivityFileFormat.geojson,
    );
    expect(back.activity.metadata['note'], 'kept');
    expect(back.activity.metadata, isNot(contains('date')));
    expect(back.activity.metadata, isNot(contains('nested')));
  });

  for (final (values, expectReport, label) in [
    (_nonFinite, true, 'non-finite'),
    (_extreme, false, 'extreme finite'),
  ]) {
    group('$label values', () {
      for (final value in values) {
        for (final MapEntry(key: field, value: activity) in _cases(
          value,
        ).entries) {
          for (final (name, format, options) in _targets) {
            for (final normalize in [true, false]) {
              test('$field = $value to $name '
                  '(normalize: $normalize)', () async {
                await _check(
                  activity,
                  format,
                  options,
                  normalize: normalize,
                  expectReport: expectReport,
                );
              });
            }
          }
        }
      }
    });
  }
}
