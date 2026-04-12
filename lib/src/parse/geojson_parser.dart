import 'dart:convert';

import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

/// Parser for GeoJSON format activity files
/// Supports single Feature and FeatureCollection geometries
class GeojsonParser implements ActivityFormatParser {
  const GeojsonParser();

  @override
  ActivityParseResult parse(String input) {
    final diagnostics = <ParseDiagnostic>[];

    try {
      final json = jsonDecode(input);
      return _parseJson(json, diagnostics);
    } catch (e) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.parse_error',
          message: 'Failed to parse GeoJSON: $e',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }
  }

  ActivityParseResult _parseJson(
    dynamic json,
    List<ParseDiagnostic> diagnostics,
  ) {
    if (json is! Map) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.invalid_type',
          message: 'GeoJSON must be a JSON object',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }

    final type = json['type'] as String?;

    if (type == 'FeatureCollection') {
      return _parseFeatureCollection(json, diagnostics);
    } else if (type == 'Feature') {
      return _parseFeature(json, diagnostics);
    } else {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.unsupported_type',
          message: 'Expected GeoJSON Feature or FeatureCollection, got: $type',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }
  }

  ActivityParseResult _parseFeatureCollection(
    dynamic json,
    List<ParseDiagnostic> diagnostics,
  ) {
    final features = json['features'] as List?;
    if (features == null || features.isEmpty) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.empty_collection',
          message: 'FeatureCollection has no features',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }

    if (features.length == 1) {
      return _parseFeature(features[0], diagnostics);
    }

    final pointFeatures = features.whereType<Map>().where((feature) {
      final geometry = feature['geometry'] as Map?;
      return geometry != null && geometry['type'] == 'Point';
    }).toList();

    if (pointFeatures.length == features.length) {
      final points = <GeoPoint>[];
      final channelMap = <Channel, List<Sample>>{};
      Sport? sport;

      for (final feature in pointFeatures) {
        final geometry = feature['geometry'] as Map;
        final properties = feature['properties'] as Map? ?? {};
        final coordinates = geometry['coordinates'] as List?;
        if (coordinates == null || coordinates.length < 2) {
          continue;
        }
        final point = _coordinateToGeoPoint(coordinates, properties);
        if (point == null) {
          continue;
        }
        points.add(point);
        _collectChannelSamples(point.time, properties, channelMap);
        sport ??= _parseSport(properties['activity_type']?.toString());
      }

      if (points.isEmpty) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.error,
            code: 'geojson.no_points',
            message: 'No valid coordinates found in Point FeatureCollection',
          ),
        );
        return ActivityParseResult(
          activity: RawActivity(),
          diagnostics: diagnostics,
        );
      }

      final activity = RawActivity(
        points: points,
        channels: channelMap.isEmpty ? null : channelMap,
        sport: sport ?? Sport.unknown,
      );
      return ActivityParseResult(activity: activity, diagnostics: diagnostics);
    }

    // Fallback: parse first feature as main activity
    return _parseFeature(features[0], diagnostics);
  }

  ActivityParseResult _parseFeature(
    dynamic feature,
    List<ParseDiagnostic> diagnostics,
  ) {
    if (feature is! Map) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.invalid_feature',
          message: 'Feature must be a JSON object',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }

    final geometry = feature['geometry'] as Map?;
    if (geometry == null) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.missing_geometry',
          message: 'Feature missing geometry',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }

    final properties = feature['properties'] as Map? ?? {};
    final coordinates = geometry['coordinates'] as List?;

    if (coordinates == null || coordinates.isEmpty) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.missing_coordinates',
          message: 'Geometry missing coordinates',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }

    final geomType = geometry['type'] as String?;
    final points = <GeoPoint>[];
    final channelMap = <Channel, List<Sample>>{};

    if (geomType == 'LineString') {
      // LineString: array of [lon, lat, ...] coordinates
      for (final coord in coordinates) {
        if (coord is! List || coord.length < 2) continue;
        final point = _coordinateToGeoPoint(coord, properties);
        if (point != null) {
          points.add(point);
          _collectChannelSamples(point.time, properties, channelMap);
        }
      }
    } else if (geomType == 'Point') {
      // Point: [lon, lat, ...]
      final point = _coordinateToGeoPoint(coordinates, properties);
      if (point != null) {
        points.add(point);
        _collectChannelSamples(point.time, properties, channelMap);
      }
    } else if (geomType == 'MultiLineString') {
      // MultiLineString: array of LineStrings
      for (final lineCoords in coordinates) {
        if (lineCoords is! List) continue;
        for (final coord in lineCoords) {
          if (coord is! List || coord.length < 2) continue;
          final point = _coordinateToGeoPoint(coord, properties);
          if (point != null) {
            points.add(point);
            _collectChannelSamples(point.time, properties, channelMap);
          }
        }
      }
    } else {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'geojson.unsupported_geometry',
          message: 'Unsupported geometry type: $geomType',
        ),
      );
    }

    if (points.isEmpty) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.no_points',
          message: 'No valid coordinates found in geometry',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }

    final sport = _parseSport(properties['activity_type']?.toString());

    final activity = RawActivity(
      points: points,
      channels: channelMap.isEmpty ? null : channelMap,
      sport: sport,
    );

    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
  }

  /// Convert GeoJSON coordinate to GeoPoint
  static GeoPoint? _coordinateToGeoPoint(List coord, Map properties) {
    try {
      if (coord.length < 2) return null;

      final longitude = _toDouble(coord[0]);
      final latitude = _toDouble(coord[1]);

      if (latitude == null || longitude == null) return null;

      // GeoJSON is [lon, lat, elevation?, ...] per spec
      final altitude = coord.length > 2 ? _toDouble(coord[2]) : null;

      // Extract time from properties if available
      DateTime? timestamp;
      if (properties['timestamp'] != null) {
        try {
          timestamp = DateTime.parse(properties['timestamp'].toString());
        } catch (_) {}
      }
      // TODO(0.5.5)(determinism): Avoid DateTime.now() fallback for missing timestamps.
      timestamp ??= DateTime.now().toUtc();

      final point = GeoPoint(
        latitude: latitude,
        longitude: longitude,
        time: timestamp,
        elevation: altitude,
      );

      return point;
    } catch (_) {
      return null;
    }
  }

  /// Collect channel samples from properties
  static void _collectChannelSamples(
    DateTime timestamp,
    Map properties,
    Map<Channel, List<Sample>> channelMap,
  ) {
    if (properties['heart_rate'] is num) {
      channelMap
          .putIfAbsent(Channel.heartRate, () => [])
          .add(
            Sample(
              time: timestamp,
              value: (properties['heart_rate'] as num).toDouble(),
            ),
          );
    }
    if (properties['cadence'] is num) {
      channelMap
          .putIfAbsent(Channel.cadence, () => [])
          .add(
            Sample(
              time: timestamp,
              value: (properties['cadence'] as num).toDouble(),
            ),
          );
    }
    if (properties['speed'] is num) {
      channelMap
          .putIfAbsent(Channel.speed, () => [])
          .add(
            Sample(
              time: timestamp,
              value: (properties['speed'] as num).toDouble(),
            ),
          );
    }
    if (properties['power'] is num) {
      channelMap
          .putIfAbsent(Channel.power, () => [])
          .add(
            Sample(
              time: timestamp,
              value: (properties['power'] as num).toDouble(),
            ),
          );
    }
    if (properties['temperature'] is num) {
      channelMap
          .putIfAbsent(Channel.temperature, () => [])
          .add(
            Sample(
              time: timestamp,
              value: (properties['temperature'] as num).toDouble(),
            ),
          );
    }
    if (properties['distance'] is num) {
      channelMap
          .putIfAbsent(Channel.distance, () => [])
          .add(
            Sample(
              time: timestamp,
              value: (properties['distance'] as num).toDouble(),
            ),
          );
    }
  }

  /// Safe conversion to double
  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      try {
        return double.parse(value);
      } catch (_) {}
    }
    return null;
  }

  /// Parse sport from string
  static Sport _parseSport(String? value) {
    if (value == null) return Sport.unknown;
    final sportStr = value.toLowerCase();
    try {
      return Sport.values.firstWhere(
        (s) => s.name.toLowerCase() == sportStr,
        orElse: () => Sport.unknown,
      );
    } catch (_) {
      return Sport.unknown;
    }
  }
}
