import 'dart:convert';

import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';
import 'timestamp_utils.dart';

final DateTime _geojsonFallbackTimestamp = DateTime.fromMillisecondsSinceEpoch(
  0,
  isUtc: true,
);

/// Type-checking casts instead of `as`: a malformed feature (e.g. a
/// `"geometry"` field that's a string, not an object) must degrade to a
/// per-feature diagnostic, not an uncaught TypeError that wipes every other
/// valid feature in the same FeatureCollection.
Map? _asMapOrNull(Object? value) => value is Map ? value : null;
List? _asListOrNull(Object? value) => value is List ? value : null;
String? _asStringOrNull(Object? value) => value is String ? value : null;

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

    final type = _asStringOrNull(json['type']);

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
    final features = _asListOrNull(json['features']);
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
      final geometry = _asMapOrNull(feature['geometry']);
      return geometry != null && geometry['type'] == 'Point';
    }).toList();

    if (pointFeatures.length == features.length) {
      final points = <GeoPoint>[];
      final channelMap = <Channel, List<Sample>>{};
      Sport? sport;

      for (final feature in pointFeatures) {
        final geometry = _asMapOrNull(feature['geometry'])!;
        final properties = _asMapOrNull(feature['properties']) ?? {};
        final coordinates = _asListOrNull(geometry['coordinates']);
        if (coordinates == null) {
          diagnostics.add(
            const ParseDiagnostic(
              severity: ParseSeverity.warning,
              code: 'geojson.point.invalid_coordinate',
              message: 'Feature geometry missing coordinates; point skipped.',
            ),
          );
          continue;
        }
        final point = _coordinateToGeoPoint(
          coordinates,
          properties,
          diagnostics,
        );
        if (point == null) {
          continue;
        }
        points.add(point);
        _collectChannelSamples(point.time, properties, channelMap);
        // _parseSport never returns null (Sport.unknown is its own
        // fallback), so `sport ??= ...` would only ever evaluate the first
        // feature; re-check for Sport.unknown instead, matching
        // csv_parser.dart's equivalent loop.
        if (sport == null || sport == Sport.unknown) {
          sport = _parseSport(properties['activity_type']?.toString());
        }
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

    final trackFeatures = <Map>[];
    var droppedPointFeatures = 0;
    var droppedMalformedFeatures = 0;
    for (final feature in features) {
      if (feature is! Map) {
        droppedMalformedFeatures++;
        continue;
      }
      final geometry = _asMapOrNull(feature['geometry']);
      if (geometry == null) {
        droppedMalformedFeatures++;
        continue;
      }
      if (geometry['type'] == 'Point') {
        droppedPointFeatures++;
        continue;
      }
      trackFeatures.add(feature);
    }

    if (droppedPointFeatures > 0) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'geojson.point_features_dropped',
          message:
              '$droppedPointFeatures standalone Point feature(s) alongside '
              'track geometry are not representable here and were dropped.',
        ),
      );
    }
    if (droppedMalformedFeatures > 0) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'geojson.malformed_feature_dropped',
          message:
              '$droppedMalformedFeatures feature(s) were not a JSON object '
              'or had no valid geometry, and were dropped.',
        ),
      );
    }

    if (trackFeatures.isEmpty) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'geojson.no_points',
          message: 'No track geometry found in FeatureCollection',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }

    final parsedTracks = [
      for (final feature in trackFeatures) _parseFeature(feature, diagnostics),
    ];
    // The first track feature to actually produce points becomes primary,
    // not always index 0: a corrupt first feature (e.g. all-malformed
    // coordinates) would otherwise strand a later, valid track's data in
    // additionalTracks, where most callers reading activity.points directly
    // never look.
    final primaryIndex = parsedTracks.indexWhere(
      (r) => r.activity.points.isNotEmpty,
    );
    final effectivePrimaryIndex = primaryIndex == -1 ? 0 : primaryIndex;
    final primaryResult = parsedTracks[effectivePrimaryIndex];
    final additionalTracks = <RawActivity>[
      for (var i = 0; i < parsedTracks.length; i++)
        if (i != effectivePrimaryIndex &&
            parsedTracks[i].activity.points.isNotEmpty)
          parsedTracks[i].activity,
    ];

    final activity = additionalTracks.isEmpty
        ? primaryResult.activity
        : primaryResult.activity.copyWith(additionalTracks: additionalTracks);

    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
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

    final geometry = _asMapOrNull(feature['geometry']);
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

    final properties = _asMapOrNull(feature['properties']) ?? {};
    final coordinates = _asListOrNull(geometry['coordinates']);

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

    final geomType = _asStringOrNull(geometry['type']);
    final points = <GeoPoint>[];
    final channelMap = <Channel, List<Sample>>{};

    if (geomType == 'LineString') {
      // LineString: array of [lon, lat, ...] coordinates. Per-point times may
      // be present as properties.coordinateProperties.times (togeojson/Mapbox
      // convention), parallel to the coordinates array. All coordinates share
      // one feature-level `properties` map, so its `timestamp` is resolved
      // once here rather than per point (avoids diagnostic spam for a single
      // bad value shared across every coordinate).
      final times = _coordinateTimes(properties);
      final coordinateChannels = _coordinateChannels(properties);
      final sharedTimestamp = _resolvePropertyTimestamp(
        properties,
        diagnostics,
      );
      for (var i = 0; i < coordinates.length; i++) {
        final coord = coordinates[i];
        if (coord is! List || coord.length < 2) continue;
        final point = _coordinateToGeoPoint(
          coord,
          properties,
          diagnostics,
          timeOverride:
              (times != null && i < times.length ? times[i] : null) ??
              sharedTimestamp,
          resolvePropertyTimestamp: false,
        );
        if (point != null) {
          points.add(point);
          _collectCoordinateChannelSamples(
            point.time,
            i,
            coordinateChannels,
            channelMap,
          );
        }
      }
    } else if (geomType == 'Point') {
      // Point: [lon, lat, ...]
      final point = _coordinateToGeoPoint(coordinates, properties, diagnostics);
      if (point != null) {
        points.add(point);
        _collectChannelSamples(point.time, properties, channelMap);
      }
    } else if (geomType == 'MultiLineString') {
      // MultiLineString: array of LineStrings, all sharing one feature-level
      // `properties` map — resolve `timestamp` once, see LineString above.
      // Per-point channel data uses the same `coordinateProperties.channels`
      // convention as LineString/Polygon, but with each channel's array
      // nested one level (one array per line, mirroring `coordTimes`'s
      // per-line shape below) since a MultiLineString has multiple point
      // sequences under one shared `properties` map.
      final sharedTimestamp = _resolvePropertyTimestamp(
        properties,
        diagnostics,
      );
      final lineTimes = _multiLineCoordinateTimes(properties);
      final coordinateChannels = _coordinateChannels(properties);
      for (var lineIndex = 0; lineIndex < coordinates.length; lineIndex++) {
        final lineCoords = coordinates[lineIndex];
        if (lineCoords is! List) continue;
        final times = lineTimes != null && lineIndex < lineTimes.length
            ? lineTimes[lineIndex]
            : null;
        for (var i = 0; i < lineCoords.length; i++) {
          final coord = lineCoords[i];
          if (coord is! List || coord.length < 2) continue;
          final point = _coordinateToGeoPoint(
            coord,
            properties,
            diagnostics,
            timeOverride:
                (times != null && i < times.length ? times[i] : null) ??
                sharedTimestamp,
            resolvePropertyTimestamp: false,
          );
          if (point != null) {
            points.add(point);
            _collectMultiLineCoordinateChannelSamples(
              point.time,
              lineIndex,
              i,
              coordinateChannels,
              channelMap,
            );
          }
        }
      }
    } else if (geomType == 'Polygon') {
      // Polygon: [ exteriorRing, ...holes ]. The exterior ring becomes the
      // track; interior rings (holes) are not part of an activity path.
      final exterior = coordinates.isNotEmpty ? coordinates[0] : null;
      if (exterior is List) {
        final times = _coordinateTimes(properties);
        final coordinateChannels = _coordinateChannels(properties);
        final sharedTimestamp = _resolvePropertyTimestamp(
          properties,
          diagnostics,
        );
        for (var i = 0; i < exterior.length; i++) {
          final coord = exterior[i];
          if (coord is! List || coord.length < 2) continue;
          final point = _coordinateToGeoPoint(
            coord,
            properties,
            diagnostics,
            timeOverride:
                (times != null && i < times.length ? times[i] : null) ??
                sharedTimestamp,
            resolvePropertyTimestamp: false,
          );
          if (point != null) {
            points.add(point);
            _collectCoordinateChannelSamples(
              point.time,
              i,
              coordinateChannels,
              channelMap,
            );
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
      summary: _parseSummary(properties),
      device: _parseDevice(properties),
    );

    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
  }

  /// Reads `properties.total_calories` into [ActivitySummary.calories], the
  /// structured field the encoder actually regenerates `total_calories`
  /// from; without this, the property (excluded from [_collectMetadata] on
  /// the assumption it's regenerated) had nowhere to go and was dropped.
  static ActivitySummary? _parseSummary(Map properties) {
    final calories = properties['total_calories'];
    return calories is num
        ? ActivitySummary(calories: calories.toDouble())
        : null;
  }

  /// Reads `properties.device_manufacturer` into
  /// [ActivityDeviceMetadata.manufacturer]; see [_parseSummary].
  static ActivityDeviceMetadata? _parseDevice(Map properties) {
    final manufacturer = properties['device_manufacturer'];
    return manufacturer is String
        ? ActivityDeviceMetadata(manufacturer: manufacturer)
        : null;
  }

  /// Captures scalar feature properties (String/num/bool) as activity
  /// metadata, so free-form properties (numeric and non-numeric) round-trip.
  /// Skips structural nested objects/arrays (e.g. `coordinateProperties`)
  /// and keys in [_metaPropertyKeys]: those are computed fields the encoder
  /// regenerates from the activity itself, so keeping a stale copy in
  /// `metadata` would let old values survive an edit and contradict the
  /// freshly re-encoded output.
  static Map<String, Object?> _collectMetadata(Map properties) {
    final metadata = <String, Object?>{};
    for (final entry in properties.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || _metadataExcludedKeys.contains(key)) continue;
      if (value == null || value is Map || value is List) continue;
      metadata[key] = value;
    }
    return metadata;
  }

  /// Parses per-point timestamps parallel to a LineString/Polygon's
  /// coordinates array: `coordTimes` (togeojson/Mapbox) or
  /// `coordinateProperties.times` (this library's own encoder), if present.
  static List<DateTime?>? _coordinateTimes(Map properties) {
    final coordTimes = properties['coordTimes'];
    if (coordTimes is List) {
      return [
        for (final t in coordTimes)
          t == null ? null : _tryParseTimestampAssumeUtc(t.toString()),
      ];
    }
    final coordinateProperties = properties['coordinateProperties'];
    if (coordinateProperties is! Map) return null;
    final times = coordinateProperties['times'];
    if (times is! List) return null;
    return [
      for (final t in times)
        t == null ? null : _tryParseTimestampAssumeUtc(t.toString()),
    ];
  }

  /// `properties.coordTimes` for a MultiLineString: one array per line.
  static List<List<DateTime?>?>? _multiLineCoordinateTimes(Map properties) {
    final coordTimes = properties['coordTimes'];
    if (coordTimes is! List) return null;
    return [
      for (final line in coordTimes)
        line is List
            ? [
                for (final t in line)
                  t == null ? null : _tryParseTimestampAssumeUtc(t.toString()),
              ]
            : null,
    ];
  }

  static DateTime? _tryParseTimestampAssumeUtc(String text) {
    try {
      return parseTimestampAssumeUtc(text);
    } catch (_) {
      return null;
    }
  }

  /// Reads channel values for line [lineIndex], point [pointIndex] from
  /// [coordinateChannels], where each channel's array is itself one array
  /// per line (mirrors [_multiLineCoordinateTimes]'s per-line `coordTimes`
  /// shape), so a MultiLineString round-trips per-point channel data the
  /// same way LineString/Polygon do.
  static void _collectMultiLineCoordinateChannelSamples(
    DateTime timestamp,
    int lineIndex,
    int pointIndex,
    Map<String, List>? coordinateChannels,
    Map<Channel, List<Sample>> channelMap,
  ) {
    if (coordinateChannels == null) return;
    for (final entry in coordinateChannels.entries) {
      if (lineIndex >= entry.value.length) continue;
      final line = entry.value[lineIndex];
      if (line is! List || pointIndex >= line.length) continue;
      final value = line[pointIndex];
      if (value is! num) continue;
      channelMap
          .putIfAbsent(Channel.custom(entry.key), () => [])
          .add(Sample(time: timestamp, value: value.toDouble()));
    }
  }

  /// Parses `properties.coordinateProperties.channels` (one parallel array
  /// per channel id, index-aligned with the coordinates array), if present.
  static Map<String, List>? _coordinateChannels(Map properties) {
    final coordinateProperties = properties['coordinateProperties'];
    if (coordinateProperties is! Map) return null;
    final channels = coordinateProperties['channels'];
    if (channels is! Map) return null;
    return {
      for (final entry in channels.entries)
        if (entry.key is String && entry.value is List)
          entry.key as String: entry.value as List,
    };
  }

  /// Reads channel values for coordinate [index] from [coordinateChannels]
  /// (the per-index parallel arrays), not the shared feature-level scalar
  /// properties, so a scalar summary property on a multi-point geometry
  /// isn't broadcast as an identical sample at every point.
  static void _collectCoordinateChannelSamples(
    DateTime timestamp,
    int index,
    Map<String, List>? coordinateChannels,
    Map<Channel, List<Sample>> channelMap,
  ) {
    if (coordinateChannels == null) return;
    for (final entry in coordinateChannels.entries) {
      if (index >= entry.value.length) continue;
      final value = entry.value[index];
      if (value is! num) continue;
      channelMap
          .putIfAbsent(Channel.custom(entry.key), () => [])
          .add(Sample(time: timestamp, value: value.toDouble()));
    }
  }

  /// Parses `properties['timestamp']`, if present. Callers that share one
  /// `properties` map across many coordinates (LineString/MultiLineString/
  /// Polygon) call this once per feature and thread the result through
  /// [_coordinateToGeoPoint]'s `timeOverride`, so an invalid value reports
  /// `geojson.point.invalid_timestamp` once per feature, not once per point.
  static DateTime? _resolvePropertyTimestamp(
    Map properties,
    List<ParseDiagnostic> diagnostics,
  ) {
    final raw = properties['timestamp'];
    if (raw == null) return null;
    try {
      return parseTimestampAssumeUtc(raw.toString());
    } catch (_) {
      diagnostics.add(
        const ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'geojson.point.invalid_timestamp',
          message:
              'Point "timestamp" property is not a valid ISO 8601 '
              'date; point kept with an epoch fallback time.',
        ),
      );
      return null;
    }
  }

  /// Convert GeoJSON coordinate to GeoPoint. Malformed coordinates are
  /// dropped (skip the point, keep going); an invalid `timestamp` property
  /// falls back to the epoch, mirroring the GPX parser's
  /// `gpx.wpt.invalid_timestamp` behavior.
  ///
  /// Pass [resolvePropertyTimestamp]: false when the caller already resolved
  /// `properties['timestamp']` once (via [_resolvePropertyTimestamp]) and
  /// threaded it through [timeOverride], to avoid re-resolving (and
  /// re-diagnosing) it per coordinate.
  static GeoPoint? _coordinateToGeoPoint(
    List coord,
    Map properties,
    List<ParseDiagnostic> diagnostics, {
    DateTime? timeOverride,
    bool resolvePropertyTimestamp = true,
  }) {
    try {
      if (coord.length < 2) {
        diagnostics.add(
          const ParseDiagnostic(
            severity: ParseSeverity.warning,
            code: 'geojson.point.invalid_coordinate',
            message: 'Coordinate has fewer than 2 elements; point skipped.',
          ),
        );
        return null;
      }

      final longitude = _toDouble(coord[0]);
      final latitude = _toDouble(coord[1]);

      if (latitude == null || longitude == null) {
        diagnostics.add(
          const ParseDiagnostic(
            severity: ParseSeverity.warning,
            code: 'geojson.point.invalid_coordinate',
            message:
                'Coordinate longitude/latitude is not numeric; point '
                'skipped.',
          ),
        );
        return null;
      }

      // GeoJSON is [lon, lat, elevation?, ...] per spec
      final altitude = coord.length > 2 ? _toDouble(coord[2]) : null;

      // Extract time from properties if available
      DateTime? timestamp = timeOverride;
      if (timestamp == null && resolvePropertyTimestamp) {
        timestamp = _resolvePropertyTimestamp(properties, diagnostics);
      }
      timestamp ??= _geojsonFallbackTimestamp;

      final point = GeoPoint(
        latitude: latitude,
        longitude: longitude,
        time: timestamp,
        elevation: altitude,
      );

      return point;
    } catch (e) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'geojson.point.invalid_coordinate',
          message: 'Failed to read coordinate: $e. Point skipped.',
        ),
      );
      return null;
    }
  }

  /// Property keys that are never per-point channel values: either scalar
  /// activity metadata, or (for `total_calories`/`device_manufacturer`)
  /// captured into a structured field instead (see [_parseSummary],
  /// [_parseDevice]). Broadcasting any of these as an identical sample on
  /// every point would misrepresent a single feature-level summary as a
  /// per-point time series.
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

  /// [_metaPropertyKeys] minus `total_steps`: every other key there is
  /// either regenerated from a structured field on re-encode (so keeping a
  /// stale copy in `metadata` would contradict the freshly re-encoded
  /// output) or purely structural. `total_steps` has no structured field to
  /// regenerate it from (this library's model has no step-count field), so
  /// unlike the others it must round-trip via `metadata` or be lost.
  static final Set<String> _metadataExcludedKeys = _metaPropertyKeys.difference(
    {'total_steps'},
  );

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
    if (value is num) return value.isFinite ? value.toDouble() : null;
    if (value is String) {
      try {
        // double.parse accepts the literal strings "NaN"/"Infinity"/
        // "-Infinity"; treat those as unparseable like any other malformed
        // value instead of letting a non-finite double reach a GeoPoint/
        // Sample (and later crash jsonEncode in the GeoJSON encoder).
        final parsed = double.parse(value);
        if (parsed.isFinite) return parsed;
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
