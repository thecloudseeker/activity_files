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
        // Computed activity_type from sport still present.
        expect(reparsed.metadata['activity_type'], 'cycling');
      },
    );
  });
}
