// SPDX-License-Identifier: BSD-3-Clause
import 'dart:math' as math;
/// Supported file formats for activities.
enum ActivityFileFormat { gpx, tcx, fit }
/// Supported sports.
enum Sport {
  unknown,
  running,
  cycling,
  swimming,
  hiking,
  walking,
  other,
}
/// A strongly-typed channel identifier used for sensor samples.
class Channel {
  /// Creates a new channel with the provided [id].
  ///
  /// The [id] is normalized to lowercase to ensure deterministic equality.
  factory Channel.custom(String id) => Channel._(_normalize(id));
  const Channel._(this.id);
  /// Primary heart-rate channel.
  static const Channel heartRate = Channel._('heart_rate');
  /// Primary cadence channel.
  static const Channel cadence = Channel._('cadence');
  /// Primary power channel.
  static const Channel power = Channel._('power');
  /// Primary temperature channel.
  static const Channel temperature = Channel._('temperature');
  /// Derived speed channel (m/s).
  static const Channel speed = Channel._('speed');
  /// Derived distance channel (meters).
  static const Channel distance = Channel._('distance');
  /// Unique identifier for the channel.
  final String id;
  static String _normalize(String value) => value.trim().toLowerCase();
  @override
  bool operator ==(Object other) => other is Channel && other.id == id;
  @override
  int get hashCode => id.hashCode;
  @override
  String toString() => 'Channel($id)';
}
/// A single geographic sample with associated timestamp.
class GeoPoint {
  GeoPoint({
    required this.latitude,
    required this.longitude,
    this.elevation,
    required DateTime time,
  }) : time = time.toUtc();
  final double latitude;
  final double longitude;
  final double? elevation;
  final DateTime time;
  GeoPoint copyWith({
    double? latitude,
    double? longitude,
    double? elevation,
    DateTime? time,
  }) =>
      GeoPoint(
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        elevation: elevation ?? this.elevation,
        time: (time ?? this.time).toUtc(),
      );
}
/// A generic sensor sample.
class Sample {
  Sample({required DateTime time, required this.value}) : time = time.toUtc();
  final DateTime time;
  final double value;
  Sample copyWith({DateTime? time, double? value}) => Sample(
        time: (time ?? this.time).toUtc(),
        value: value ?? this.value,
      );
}
/// Summary information for a lap or segment.
class Lap {
  Lap({
    required DateTime startTime,
    required DateTime endTime,
    this.distanceMeters,
    this.name,
  })  : startTime = startTime.toUtc(),
        endTime = endTime.toUtc();
  final DateTime startTime;
  final DateTime endTime;
  final double? distanceMeters;
  final String? name;
  Duration get elapsed => endTime.difference(startTime);
  Lap copyWith({
    DateTime? startTime,
    DateTime? endTime,
    double? distanceMeters,
    String? name,
  }) =>
      Lap(
        startTime: (startTime ?? this.startTime).toUtc(),
        endTime: (endTime ?? this.endTime).toUtc(),
        distanceMeters: distanceMeters ?? this.distanceMeters,
        name: name ?? this.name,
      );
}
/// Unified in-memory representation of an activity.
class RawActivity {
  RawActivity({
    Iterable<GeoPoint>? points,
    Map<Channel, Iterable<Sample>>? channels,
    Iterable<Lap>? laps,
    this.sport = Sport.unknown,
    this.creator,
  })  : points = List<GeoPoint>.unmodifiable(points ?? const <GeoPoint>[]),
        channels = Map.unmodifiable({
          for (final entry
              in (channels ?? const <Channel, Iterable<Sample>>{}).entries)
            entry.key: List<Sample>.unmodifiable(
              entry.value.map((sample) => sample.copyWith()),
            )
        }),
        laps = List<Lap>.unmodifiable(laps ?? const <Lap>[]);
  /// Sequence of geographic points.
  final List<GeoPoint> points;
  /// Time-aligned sensor channels.
  final Map<Channel, List<Sample>> channels;
  /// Declared laps or segments.
  final List<Lap> laps;
  /// Dominant sport classification.
  final Sport sport;
  /// Name of the originating software or device.
  final String? creator;
  /// Returns the samples for a given [channel], if present.
  List<Sample> channel(Channel channel) =>
      channels[channel] ?? const <Sample>[];
  /// Creates a copy with overrides.
  RawActivity copyWith({
    Iterable<GeoPoint>? points,
    Map<Channel, Iterable<Sample>>? channels,
    Iterable<Lap>? laps,
    Sport? sport,
    String? creator,
  }) {
    return RawActivity(
      points: points ?? this.points,
      channels: channels ??
          {
            for (final entry in this.channels.entries)
              entry.key: entry.value.map((sample) => sample.copyWith()),
          },
      laps: laps ?? this.laps,
      sport: sport ?? this.sport,
      creator: creator ?? this.creator,
    );
  }
  /// Returns the timestamp of the first point, if any.
  DateTime? get startTime => points.isEmpty ? null : points.first.time;
  /// Returns the timestamp of the last point, if any.
  DateTime? get endTime => points.isEmpty ? null : points.last.time;
  /// Approximates the total distance in meters based on stored channels or
  /// planar projection of geographic points.
  double get approximateDistance {
    final distanceSamples = channels[Channel.distance];
    if (distanceSamples != null && distanceSamples.isNotEmpty) {
      return distanceSamples.last.value;
    }
    if (points.length < 2) {
      return 0;
    }
    double total = 0;
    for (var i = 1; i < points.length; i++) {
      total += _haversine(points[i - 1], points[i]);
    }
    return total;
  }
  static double _haversine(GeoPoint a, GeoPoint b) {
    const earthRadius = 6371000; // meters
    final dLat = _radians(b.latitude - a.latitude);
    final dLon = _radians(b.longitude - a.longitude);
    final lat1 = _radians(a.latitude);
    final lat2 = _radians(b.latitude);
    final sinDLat = math.sin(dLat / 2);
    final sinDLon = math.sin(dLon / 2);
    final h =
        sinDLat * sinDLat + math.cos(lat1) * math.cos(lat2) * sinDLon * sinDLon;
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return earthRadius * c;
  }
  static double _radians(double deg) => deg * math.pi / 180.0;
}
