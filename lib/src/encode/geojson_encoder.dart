import 'dart:convert';

import '../models.dart';

/// Encodes activity data to GeoJSON format
/// Supports export of trackpoints as LineString features with properties
class GeojsonEncoder {
  /// Encode activity to GeoJSON FeatureCollection format
  ///
  /// Returns GeoJSON string with activity as LineString feature
  static String encode(RawActivity activity) {
    final feature = _buildFeature(activity);
    return jsonEncode({
      'type': 'FeatureCollection',
      'features': [feature],
    });
  }

  /// Build GeoJSON Feature from activity
  static Map<String, dynamic> _buildFeature(RawActivity activity) {
    return {
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': _getCoordinates(activity),
      },
      'properties': _getProperties(activity),
    };
  }

  /// Extract coordinates from activity trackpoints
  static List<List<double>> _getCoordinates(RawActivity activity) {
    return activity.points.map((p) => [p.longitude, p.latitude]).toList();
  }

  /// Extract GeoJSON properties from activity
  static Map<String, dynamic> _getProperties(RawActivity activity) {
    final props = <String, dynamic>{
      'activity_type': activity.sport.name.toLowerCase(),
      'start_time': activity.points.isNotEmpty
          ? activity.points.first.time.toIso8601String()
          : '',
      'duration': activity.points.isNotEmpty
          ? activity.points.last.time
                .difference(activity.points.first.time)
                .inSeconds
                .toDouble()
          : 0,
      'total_calories': 0,
      'total_steps': 0,
    };

    // Add lap info if available
    if (activity.laps.isNotEmpty) {
      props['num_laps'] = activity.laps.length;
      props['avg_heart_rate'] =
          activity.laps.fold<double>(
            0,
            (sum, lap) => sum + (lap.avgHeartRate ?? 0),
          ) /
          activity.laps.length;
      props['max_heart_rate'] = activity.laps
          .map((lap) => lap.maxHeartRate)
          .nonNulls
          .fold<double?>(
            null,
            (max, val) => max == null
                ? val.toDouble()
                : (val > max ? val.toDouble() : max),
          );
    }

    // Add device info if available
    if (activity.device != null) {
      props['device_manufacturer'] = activity.device!.manufacturer;
    }

    return props;
  }

  /// Encode multiple activities to GeoJSON FeatureCollection
  static String encodeMultiple(List<RawActivity> activities) {
    if (activities.isEmpty) {
      return jsonEncode({'type': 'FeatureCollection', 'features': []});
    }

    final features = activities.map(_buildFeature).toList();

    return jsonEncode({'type': 'FeatureCollection', 'features': features});
  }

  /// Encode activity with all trackpoints as individual point features
  static String encodeAsPoints(RawActivity activity) {
    final features = activity.points
        .map(
          (p) => {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [p.longitude, p.latitude],
            },
            'properties': {
              'timestamp': p.time.toIso8601String(),
              'altitude': p.elevation ?? 0,
            },
          },
        )
        .toList();

    return jsonEncode({'type': 'FeatureCollection', 'features': features});
  }

  /// Encode activity with points as individual features including channel data
  static String encodeAsPointsWithChannels(RawActivity activity) {
    // Build channel lookup by timestamp
    final channelsByTime = <DateTime, Map<Channel, double>>{};
    for (final entry in activity.channels.entries) {
      for (final sample in entry.value) {
        final values = channelsByTime.putIfAbsent(sample.time, () => {});
        values[entry.key] = sample.value;
      }
    }

    final features = activity.points.map((p) {
      final values = channelsByTime[p.time] ?? {};
      return {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [p.longitude, p.latitude],
        },
        'properties': {
          'timestamp': p.time.toIso8601String(),
          'altitude': p.elevation ?? 0,
          'heart_rate': values[Channel.heartRate],
          'cadence': values[Channel.cadence],
          'power': values[Channel.power],
          'temperature': values[Channel.temperature],
          'distance': values[Channel.distance],
          'speed': values[Channel.speed],
        },
      };
    }).toList();

    return jsonEncode({'type': 'FeatureCollection', 'features': features});
  }
}
