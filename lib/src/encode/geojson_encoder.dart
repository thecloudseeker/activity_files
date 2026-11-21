// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';

import '../models.dart';
import 'encoder_options.dart';
import 'encoder_utils.dart';

/// Encodes activity data to GeoJSON format
/// Supports export of trackpoints as LineString features with properties
class GeojsonEncoder {
  /// Reserved per-point property keys in [_encodePointFeatures]'s output; a
  /// channel id colliding with one of these is skipped rather than silently
  /// overwriting it (map literals let a later duplicate key win).
  static const Set<String> _reservedPointFeatureKeys = {
    'timestamp',
    'altitude',
  };

  /// Whether [value] can be written as JSON: null, a string, a bool, a
  /// finite number, or a list or string-keyed map of such values.
  static bool isJsonValue(Object? value) => switch (value) {
    null || String() || bool() || int() => true,
    final double d => d.isFinite,
    final List<Object?> list => list.every(isJsonValue),
    final Map<Object?, Object?> map =>
      map.keys.every((k) => k is String) && map.values.every(isJsonValue),
    _ => false,
  };

  /// Encode activity to GeoJSON FeatureCollection format
  ///
  /// Returns GeoJSON string with activity as LineString feature
  static String encode(
    RawActivity activity, {
    EncoderOptions options = const EncoderOptions(),
  }) => jsonEncode({
    'type': 'FeatureCollection',
    // A single LineString feature is emitted; merge multi-track input.
    'features': [_buildFeature(activity.flattened(), options)],
  });

  /// Encode multiple activities to GeoJSON FeatureCollection
  static String encodeMultiple(
    List<RawActivity> activities, {
    EncoderOptions options = const EncoderOptions(),
  }) => jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      for (final activity in activities)
        _buildFeature(activity.flattened(), options),
    ],
  });

  /// Encode activity with all trackpoints as individual point features
  static String encodeAsPoints(
    RawActivity activity, {
    EncoderOptions options = const EncoderOptions(),
  }) =>
      _encodePointFeatures(activity, includeChannels: false, options: options);

  /// Encode activity with points as individual features including channel data
  static String encodeAsPointsWithChannels(
    RawActivity activity, {
    EncoderOptions options = const EncoderOptions(),
  }) => _encodePointFeatures(activity, includeChannels: true, options: options);

  /// Rounds a coordinate/elevation value to [precision] fractional digits,
  /// mirroring the GPX encoder's `_round` (JSON numbers, not strings, so the
  /// value itself is rounded rather than formatted).
  static double _round(double value, int precision) =>
      double.parse(value.toStringAsFixed(precision));

  /// Running mean, so values near the double limit cannot overflow a sum
  /// into infinity, which JSON cannot hold.
  static double _mean(List<double> values) {
    var mean = 0.0;
    for (var i = 0; i < values.length; i++) {
      mean += values[i] / (i + 1) - mean / (i + 1);
    }
    return mean;
  }

  /// Build GeoJSON Feature from activity
  static Map<String, dynamic> _buildFeature(
    RawActivity activity,
    EncoderOptions options,
  ) {
    // Third coordinate is elevation per the GeoJSON spec (RFC 7946 §3.1.1);
    // omitted when the point has none so nulls round-trip as null.
    final coordinates = [
      for (final p in activity.points)
        [
          _round(p.longitude, options.precisionLatLon),
          _round(p.latitude, options.precisionLatLon),
          if (p.elevation != null) _round(p.elevation!, options.precisionEle),
        ],
    ];
    return {
      'type': 'Feature',
      // A LineString needs two positions (RFC 7946 §3.1.4): one position is
      // a Point, and none is a null geometry, which keeps the properties.
      'geometry': switch (coordinates.length) {
        0 => null,
        1 => {'type': 'Point', 'coordinates': coordinates.single},
        _ => {'type': 'LineString', 'coordinates': coordinates},
      },
      'properties': _getProperties(activity),
    };
  }

  /// Extract GeoJSON properties from activity
  static Map<String, dynamic> _getProperties(RawActivity activity) {
    final points = activity.points;
    final laps = activity.laps;
    final avgHeartRates = laps.map((lap) => lap.avgHeartRate).nonNulls.toList();
    return {
      'activity_type': activity.sport.name.toLowerCase(),
      'start_time': points.isNotEmpty
          ? points.first.time.toIso8601String()
          : '',
      'duration': points.isNotEmpty
          ? points.last.time.difference(points.first.time).inSeconds.toDouble()
          : 0,
      if (activity.summary?.calories != null)
        'total_calories': activity.summary!.calories,
      if (laps.isNotEmpty) ...{
        'num_laps': laps.length,
        if (avgHeartRates.isNotEmpty) 'avg_heart_rate': _mean(avgHeartRates),
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
      for (final MapEntry(:key, :value) in activity.metadata.entries)
        if (isJsonValue(value)) key: value,
      // Per-point timestamps are always regenerated from the current points
      // (togeojson/Mapbox convention); GeoJSON has no native time field.
      if (points.isNotEmpty)
        'coordinateProperties': {
          'times': [for (final p in points) p.time.toUtc().toIso8601String()],
          // One parallel array per channel, index-aligned with `coordinates`
          // (same convention as `times`), so channel data survives the
          // default LineString export instead of only the point-features one.
          if (activity.channels.isNotEmpty)
            'channels': _coordinateChannelArrays(activity, points),
        },
    };
  }

  /// One entry per channel, each a parallel array (index-aligned with
  /// [points]) of that channel's value at the point's exact timestamp, or
  /// `null` where no sample exists at that instant.
  static Map<String, List<double?>> _coordinateChannelArrays(
    RawActivity activity,
    List<GeoPoint> points,
  ) {
    final channelsByTime = channelValuesByTime(activity.channels);
    final sortedChannels = activity.channels.keys.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return {
      for (final channel in sortedChannels)
        channel.id: [for (final p in points) channelsByTime[p.time]?[channel]],
    };
  }

  static String _encodePointFeatures(
    RawActivity activity, {
    required bool includeChannels,
    EncoderOptions options = const EncoderOptions(),
  }) {
    activity = activity.flattened();
    // No points is one feature with a null geometry, as in the LineString
    // form, so the activity's properties still have a place.
    if (activity.points.isEmpty) {
      return jsonEncode({
        'type': 'FeatureCollection',
        'features': [_buildFeature(activity, options)],
      });
    }
    final channelsByTime = includeChannels
        ? channelValuesByTime(activity.channels)
        : const <DateTime, Map<Channel, double>>{};
    final features = [
      for (final p in activity.points)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            // Third coordinate is elevation per the GeoJSON spec (RFC 7946
            // §3.1.1); omitted when the point has none so nulls round-trip.
            'coordinates': [
              _round(p.longitude, options.precisionLatLon),
              _round(p.latitude, options.precisionLatLon),
              if (p.elevation != null)
                _round(p.elevation!, options.precisionEle),
            ],
          },
          'properties': {
            'timestamp': p.time.toIso8601String(),
            if (p.elevation != null)
              'altitude': _round(p.elevation!, options.precisionEle),
            // Every channel (built-in and custom) is written under its
            // channel id so no sensor data is lost -- except a channel id
            // that collides with a reserved key above (e.g. a custom
            // channel literally named "altitude"), which would otherwise
            // silently overwrite the real elevation value in this same map
            // literal (later duplicate keys win). Skip it here, matching
            // csv_encoder.dart's equivalent reserved-column handling.
            if (includeChannels)
              for (final entry in (channelsByTime[p.time] ?? const {}).entries)
                if (!_reservedPointFeatureKeys.contains(entry.key.id))
                  entry.key.id: entry.value,
          },
        },
    ];
    return jsonEncode({'type': 'FeatureCollection', 'features': features});
  }
}
