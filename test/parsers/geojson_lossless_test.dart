// SPDX-License-Identifier: BSD-3-Clause
import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// GeoJSON round-trip coverage for activity-level metadata properties (numeric
/// and non-numeric) and Polygon geometries.
void main() {
  RawActivity parse(String json) =>
      ActivityParser.parse(json, ActivityFileFormat.geojson).activity;

  group('GeoJSON lossless round-trip', () {
    test('activity-level properties survive with their JSON types', () {
      const json = '''
{"type":"Feature",
 "geometry":{"type":"LineString","coordinates":[[11.0,47.0,500],[11.001,47.001,501]]},
 "properties":{
   "activity_type":"running",
   "notes":"Morning loop",
   "weather_summary":"clear",
   "total_distance":"21849.097",
   "temperature":7,
   "wind_speed":3.5,
   "coordinateProperties":{"times":["2024-01-01T10:00:00Z","2024-01-01T10:00:10Z"]}
 }}''';

      final activity = parse(json);
      expect(activity.points, hasLength(2));
      expect(activity.metadata['notes'], 'Morning loop');
      expect(activity.metadata['weather_summary'], 'clear');
      expect(activity.metadata['total_distance'], '21849.097'); // String kept
      expect(activity.metadata['temperature'], 7); // int kept
      expect(activity.metadata['wind_speed'], 3.5); // double kept

      final encoded = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.geojson,
      );
      final reparsed = parse(encoded);
      expect(reparsed.metadata['notes'], 'Morning loop');
      expect(reparsed.metadata['weather_summary'], 'clear');
      expect(reparsed.metadata['total_distance'], '21849.097');
      expect(reparsed.metadata['temperature'], 7);
      expect(reparsed.metadata['wind_speed'], 3.5);
      // coordinateProperties is structural, never captured as metadata.
      expect(reparsed.metadata.containsKey('coordinateProperties'), isFalse);
    });

    test('computed properties do not go stale after an edit', () {
      const json = '''
{"type":"Feature",
 "geometry":{"type":"LineString","coordinates":[
   [11.0,47.0],[11.001,47.001],[11.002,47.002],[11.003,47.003]
 ]},
 "properties":{
   "activity_type":"running",
   "start_time":"2024-01-01T10:00:00.000Z",
   "duration":1800.0,
   "total_calories":500,
   "coordinateProperties":{"times":[
     "2024-01-01T10:00:00Z","2024-01-01T10:10:00Z",
     "2024-01-01T10:20:00Z","2024-01-01T10:30:00Z"
   ]}
 }}''';

      final activity = parse(json);
      final cropped = RawEditor(
        activity,
      ).crop(activity.points[0].time, activity.points[1].time).activity;
      final encoded = ActivityEncoder.encode(
        cropped,
        ActivityFileFormat.geojson,
      );
      final reparsed = parse(encoded);

      expect(reparsed.points, hasLength(2));
      expect(reparsed.metadata['duration'], isNot(1800.0));
      expect(reparsed.metadata['total_calories'], isNot(500));
    });

    test('Polygon exterior ring is parsed as the track', () {
      const json = '''
{"type":"Feature",
 "geometry":{"type":"Polygon","coordinates":[
   [[11.0,47.0],[11.001,47.0],[11.001,47.001],[11.0,47.0]],
   [[11.0005,47.0005],[11.0006,47.0005],[11.0005,47.0006]]
 ]},
 "properties":{"activity_type":"hiking"}}''';

      final result = ActivityParser.parse(json, ActivityFileFormat.geojson);
      expect(
        result.activity.points,
        hasLength(4),
        reason: 'exterior ring becomes the track',
      );
      expect(result.activity.sport, Sport.hiking);
      // Interior ring (hole) is reported, not silently dropped.
      expect(
        result.diagnostics.any(
          (d) => d.code == 'geojson.polygon_holes_dropped',
        ),
        isTrue,
      );
    });

    test(
      'Polygon exterior ring picks up per-point coordinateProperties.times',
      () {
        const json = '''
{"type":"Feature",
 "geometry":{"type":"Polygon","coordinates":[
   [[11.0,47.0],[11.001,47.0],[11.001,47.001],[11.0,47.0]]
 ]},
 "properties":{
   "activity_type":"hiking",
   "coordinateProperties":{"times":[
     "2024-01-01T10:00:00Z","2024-01-01T10:00:01Z",
     "2024-01-01T10:00:02Z","2024-01-01T10:00:03Z"
   ]}
 }}''';

        final result = ActivityParser.parse(json, ActivityFileFormat.geojson);
        expect(result.activity.points, hasLength(4));
        expect(
          result.activity.points[0].time,
          equals(DateTime.parse('2024-01-01T10:00:00Z')),
        );
        expect(
          result.activity.points[3].time,
          equals(DateTime.parse('2024-01-01T10:00:03Z')),
        );
      },
    );

    test(
      'non-GeoJSON-sourced activity keeps computed defaults (no metadata)',
      () {
        final activity = RawActivity(
          points: [
            GeoPoint(latitude: 47.0, longitude: 11.0, time: DateTime.utc(2024)),
            GeoPoint(
              latitude: 47.001,
              longitude: 11.001,
              time: DateTime.utc(2024, 1, 1, 0, 1),
            ),
          ],
          sport: Sport.cycling,
        );
        final encoded = ActivityEncoder.encode(
          activity,
          ActivityFileFormat.geojson,
        );
        final reparsed = parse(encoded);
        expect(reparsed.sport, Sport.cycling);
      },
    );
  });
}
