import 'dart:convert';

import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

final DateTime _geojsonFallbackTimestamp = DateTime.fromMillisecondsSinceEpoch(
  0,
  isUtc: true,
);

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
      // LineString: array of [lon, lat, ...] coordinates. Per-point times may
      // be present as properties.coordinateProperties.times (togeojson/Mapbox
      // convention), parallel to the coordinates array.
      final times = _coordinateTimes(properties);
      for (var i = 0; i < coordinates.length; i++) {
        final coord = coordinates[i];
        if (coord is! List || coord.length < 2) continue;
        final point = _coordinateToGeoPoint(
          coord,
          properties,
          timeOverride: times != null && i < times.length ? times[i] : null,
        );
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
    } else if (geomType == 'Polygon') {
      // Polygon: [ exteriorRing, ...holes ]. The exterior ring becomes the
      // track; interior rings (holes) are not part of an activity path.
      final exterior = coordinates.isNotEmpty ? coordinates[0] : null;
      if (exterior is List) {
        final times = _coordinateTimes(properties);
        for (var i = 0; i < exterior.length; i++) {
          final coord = exterior[i];
          if (coord is! List || coord.length < 2) continue;
          final point = _coordinateToGeoPoint(
            coord,
            properties,
            timeOverride: times != null && i < times.length ? times[i] : null,
          );
          if (point != null) {
            points.add(point);
            _collectChannelSamples(point.time, properties, channelMap);
          }
        }
      }
      if (coordinates.length > 1) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.warning,
            code: 'geojson.polygon_holes_dropped',
            message:
                'Polygon has ${coordinates.length - 1} interior ring(s) '
                '(holes) that are not representable as an activity track.',
          ),
        );
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
      metadata: _collectMetadata(properties),
    );

    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
  }

  /// Captures all scalar feature properties (String/num/bool) as activity
  /// metadata, so free-form properties — numeric and non-numeric — round-trip.
  /// Structural nested objects/arrays (e.g. `coordinateProperties`) are skipped.
  static Map<String, Object?> _collectMetadata(Map properties) {
    final metadata = <String, Object?>{};
    for (final entry in properties.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || key == 'coordinateProperties') continue;
      if (value == null || value is Map || value is List) continue;
      metadata[key] = value;
    }
    return metadata;
  }

  /// Parses `properties.coordinateProperties.times` (per-point timestamps
  /// parallel to the coordinates array), if present.
  static List<DateTime?>? _coordinateTimes(Map properties) {
    final coordinateProperties = properties['coordinateProperties'];
    if (coordinateProperties is! Map) return null;
    final times = coordinateProperties['times'];
    if (times is! List) return null;
    return [
      for (final t in times)
        t == null ? null : DateTime.tryParse(t.toString())?.toUtc(),
    ];
  }

  /// Convert GeoJSON coordinate to GeoPoint
  static GeoPoint? _coordinateToGeoPoint(
    List coord,
    Map properties, {
    DateTime? timeOverride,
  }) {
    try {
      if (coord.length < 2) return null;

      final longitude = _toDouble(coord[0]);
      final latitude = _toDouble(coord[1]);

      if (latitude == null || longitude == null) return null;

      // GeoJSON is [lon, lat, elevation?, ...] per spec
      final altitude = coord.length > 2 ? _toDouble(coord[2]) : null;

      // Extract time from properties if available
      DateTime? timestamp = timeOverride;
      if (timestamp == null && properties['timestamp'] != null) {
        try {
          timestamp = DateTime.parse(properties['timestamp'].toString());
        } catch (_) {}
      }
      timestamp ??= _geojsonFallbackTimestamp;

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

  /// Property keys that are activity metadata rather than channel values.
  static const Set<String> _metaPropertyKeys = {
    'timestamp',
    'altitude',
    'activity_type',
    'start_time',
    'duration',
    'total_calories',
    'total_steps',
    'num_laps',
    'avg_heart_rate',
    'max_heart_rate',
    'device_manufacturer',
    'coordinateProperties',
  };

  /// Collect channel samples from properties.
  ///
  /// Every numeric property that is not a known metadata key becomes a
  /// channel sample; `Channel.custom` normalizes the name, so known names
  /// (heart_rate, cadence, power, …) map onto the built-in channels and
  /// unknown names are preserved as custom channels.
  static void _collectChannelSamples(
    DateTime timestamp,
    Map properties,
    Map<Channel, List<Sample>> channelMap,
  ) {
    for (final entry in properties.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is! num || key is! String || _metaPropertyKeys.contains(key)) {
        continue;
      }
      channelMap
          .putIfAbsent(Channel.custom(key), () => [])
          .add(Sample(time: timestamp, value: value.toDouble()));
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
