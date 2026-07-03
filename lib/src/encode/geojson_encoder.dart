import 'dart:convert';

import '../models.dart';
import 'encoder_utils.dart';

/// Encodes activity data to GeoJSON format
/// Supports export of trackpoints as LineString features with properties
class GeojsonEncoder {
  /// Encode activity to GeoJSON FeatureCollection format
  ///
  /// Returns GeoJSON string with activity as LineString feature
  static String encode(RawActivity activity) => jsonEncode({
    'type': 'FeatureCollection',
    // A single LineString feature is emitted; merge multi-track input.
    'features': [_buildFeature(activity.flattened())],
  });

  /// Encode multiple activities to GeoJSON FeatureCollection
  static String encodeMultiple(List<RawActivity> activities) => jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      for (final activity in activities) _buildFeature(activity.flattened()),
    ],
  });

  /// Encode activity with all trackpoints as individual point features
  static String encodeAsPoints(RawActivity activity) =>
      _encodePointFeatures(activity, includeChannels: false);

  /// Encode activity with points as individual features including channel data
  static String encodeAsPointsWithChannels(RawActivity activity) =>
      _encodePointFeatures(activity, includeChannels: true);

  /// Build GeoJSON Feature from activity
  static Map<String, dynamic> _buildFeature(RawActivity activity) => {
    'type': 'Feature',
    'geometry': {
      'type': 'LineString',
      // Third coordinate is elevation per the GeoJSON spec (RFC 7946 §3.1.1);
      // omitted when the point has none so nulls round-trip as null.
      'coordinates': [
        for (final p in activity.points)
          [p.longitude, p.latitude, if (p.elevation != null) p.elevation],
      ],
    },
    'properties': _getProperties(activity),
  };

  /// Extract GeoJSON properties from activity
  static Map<String, dynamic> _getProperties(RawActivity activity) {
    final points = activity.points;
    final laps = activity.laps;
    return {
      'activity_type': activity.sport.name.toLowerCase(),
      'start_time': points.isNotEmpty
          ? points.first.time.toIso8601String()
          : '',
      'duration': points.isNotEmpty
          ? points.last.time.difference(points.first.time).inSeconds.toDouble()
          : 0,
      'total_calories': 0,
      'total_steps': 0,
      if (laps.isNotEmpty) ...{
        'num_laps': laps.length,
        'avg_heart_rate':
            laps.fold<double>(0, (sum, lap) => sum + (lap.avgHeartRate ?? 0)) /
            laps.length,
        'max_heart_rate': laps
            .map((lap) => lap.maxHeartRate)
            .nonNulls
            .fold<double?>(
              null,
              (max, val) => max == null || val > max ? val.toDouble() : max,
            ),
      },
      if (activity.device != null)
        'device_manufacturer': activity.device!.manufacturer,
      // Preserved source properties win over the computed defaults above, so a
      // GeoJSON round-trip keeps every original feature property verbatim.
      // Empty for non-GeoJSON sources, leaving the computed defaults intact.
      ...activity.metadata,
      // Per-point timestamps are always regenerated from the current points
      // (togeojson/Mapbox convention); GeoJSON has no native time field.
      if (points.isNotEmpty)
        'coordinateProperties': {
          'times': [for (final p in points) p.time.toUtc().toIso8601String()],
        },
    };
  }

  static String _encodePointFeatures(
    RawActivity activity, {
    required bool includeChannels,
  }) {
    activity = activity.flattened();
    final channelsByTime = includeChannels
        ? channelValuesByTime(activity.channels)
        : const <DateTime, Map<Channel, double>>{};
    final features = [
      for (final p in activity.points)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [p.longitude, p.latitude],
          },
          'properties': {
            'timestamp': p.time.toIso8601String(),
            'altitude': p.elevation ?? 0,
            // Every channel (built-in and custom) is written under its
            // channel id so no sensor data is lost.
            if (includeChannels)
              for (final entry in (channelsByTime[p.time] ?? const {}).entries)
                entry.key.id: entry.value,
          },
        },
    ];
    return jsonEncode({'type': 'FeatureCollection', 'features': features});
  }
}
