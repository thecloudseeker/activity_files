// SPDX-License-Identifier: BSD-3-Clause
import '../api/export_serialization.dart';
import '../models.dart';

/// What [dropNonFinite] removed, counted per kind of value.
class NonFiniteReport {
  final Map<String, int> _counts = {};

  /// Counts by kind, such as `points` or `heart_rate samples`.
  Map<String, int> get counts => Map.unmodifiable(_counts);

  bool get isEmpty => _counts.isEmpty;

  void _add(String kind, [int count = 1]) {
    if (count > 0) _counts[kind] = (_counts[kind] ?? 0) + count;
  }

  /// A readable list such as `2 points, 1 lap value`.
  String describe() => [
    for (final entry in _counts.entries) '${entry.value} ${entry.key}',
  ].join(', ');
}

/// Returns [activity] without any `NaN` or infinite value, and records what
/// was removed in [report].
///
/// A point whose latitude or longitude is not finite is removed, and so is
/// a sample whose value is not finite. Every other non-finite number (an
/// elevation, a lap or summary statistic, a raw FIT field) is cleared and
/// the rest of its object kept. Returns [activity] itself when it holds no
/// such value, so the common case costs one pass and no copy.
RawActivity dropNonFinite(RawActivity activity, NonFiniteReport report) {
  final points = _finitePoints(activity.points, report, 'points');
  final channels = _finiteChannels(activity.channels, report);
  final laps = _finiteObjects(
    activity.laps,
    report,
    'lap values',
    ExportSerialization.lapToJson,
    ExportSerialization.lapFromJson,
  );
  final sets = _finiteObjects(
    activity.sets,
    report,
    'set values',
    ExportSerialization.workoutSetToJson,
    ExportSerialization.workoutSetFromJson,
  );
  final lengths = _finiteObjects(
    activity.lengths,
    report,
    'swim length values',
    ExportSerialization.swimLengthToJson,
    ExportSerialization.swimLengthFromJson,
  );
  final summary = activity.summary == null
      ? null
      : _finiteObjects(
          [activity.summary!],
          report,
          'summary values',
          ExportSerialization.summaryToJson,
          ExportSerialization.summaryFromJson,
        )?.single;
  final sessions = _finiteObjects(
    activity.additionalSessions,
    report,
    'session values',
    ExportSerialization.summaryToJson,
    ExportSerialization.summaryFromJson,
  );
  final waypoints = _finitePoints(activity.gpxWaypoints, report, 'waypoints');
  List<GpxRoute>? routes;
  for (var i = 0; i < activity.gpxRoutes.length; i++) {
    final route = activity.gpxRoutes[i];
    final routePoints = _finitePoints(route.points, report, 'route points');
    if (routePoints == null) continue;
    routes ??= [...activity.gpxRoutes];
    routes[i] = route.copyWith(points: routePoints);
  }
  List<RawActivity>? tracks;
  for (var i = 0; i < activity.additionalTracks.length; i++) {
    final track = activity.additionalTracks[i];
    final cleaned = dropNonFinite(track, report);
    if (identical(cleaned, track)) continue;
    tracks ??= [...activity.additionalTracks];
    tracks[i] = cleaned;
  }
  final metadata = _finiteJson(activity.metadata, report, 'metadata values');

  if (points == null &&
      channels == null &&
      laps == null &&
      sets == null &&
      lengths == null &&
      summary == null &&
      sessions == null &&
      waypoints == null &&
      routes == null &&
      tracks == null &&
      metadata == null) {
    return activity;
  }
  return activity.copyWith(
    points: points,
    channels: channels,
    laps: laps,
    sets: sets,
    lengths: lengths,
    summary: summary,
    additionalSessions: sessions,
    gpxWaypoints: waypoints,
    gpxRoutes: routes,
    additionalTracks: tracks,
    metadata: metadata as Map<String, Object?>?,
  );
}

bool _isBad(double? value) => value != null && !value.isFinite;

/// Null when every point is finite; otherwise the cleaned list.
List<GeoPoint>? _finitePoints(
  List<GeoPoint> points,
  NonFiniteReport report,
  String kind,
) {
  final firstBad = points.indexWhere(
    (p) => _isBad(p.latitude) || _isBad(p.longitude) || _isBad(p.elevation),
  );
  if (firstBad < 0) return null;
  final cleaned = points.sublist(0, firstBad);
  for (var i = firstBad; i < points.length; i++) {
    final point = points[i];
    if (_isBad(point.latitude) || _isBad(point.longitude)) {
      report._add(kind);
    } else if (_isBad(point.elevation)) {
      report._add('elevations');
      cleaned.add(point.copyWithoutElevation());
    } else {
      cleaned.add(point);
    }
  }
  return cleaned;
}

/// Null when every sample is finite; otherwise the cleaned channel map.
Map<Channel, List<Sample>>? _finiteChannels(
  Map<Channel, List<Sample>> channels,
  NonFiniteReport report,
) {
  Map<Channel, List<Sample>>? cleaned;
  for (final entry in channels.entries) {
    final samples = entry.value;
    if (!samples.any((s) => _isBad(s.value))) continue;
    final kept = [
      for (final sample in samples)
        if (!_isBad(sample.value)) sample,
    ];
    report._add('${entry.key.id} samples', samples.length - kept.length);
    cleaned ??= {...channels};
    cleaned[entry.key] = kept;
  }
  return cleaned;
}

/// Null when no object holds a non-finite number; otherwise the list with
/// each affected object rebuilt without those numbers. Objects go through
/// their serialized form so that every field, including ones added later,
/// is covered without listing it here.
List<T>? _finiteObjects<T>(
  List<T> objects,
  NonFiniteReport report,
  String kind,
  Map<String, Object?> Function(T) toJson,
  T Function(Map<String, Object?>) fromJson,
) {
  List<T>? cleaned;
  for (var i = 0; i < objects.length; i++) {
    final json = _finiteJson(toJson(objects[i]), report, kind);
    if (json == null) continue;
    cleaned ??= [...objects];
    cleaned[i] = fromJson(json as Map<String, Object?>);
  }
  return cleaned;
}

/// Null when [value] holds no non-finite number; otherwise a copy with each
/// one removed (map entries and list elements left out).
Object? _finiteJson(Object? value, NonFiniteReport report, String kind) {
  if (!_holdsNonFinite(value)) return null;
  return _stripNonFinite(value, report, kind);
}

bool _holdsNonFinite(Object? value) => switch (value) {
  final double d => !d.isFinite,
  final Map<Object?, Object?> map => map.values.any(_holdsNonFinite),
  final List<Object?> list => list.any(_holdsNonFinite),
  _ => false,
};

Object? _stripNonFinite(Object? value, NonFiniteReport report, String kind) {
  switch (value) {
    case final Map<Object?, Object?> map:
      final result = <Object?, Object?>{};
      for (final entry in map.entries) {
        final v = entry.value;
        if (v is double && !v.isFinite) {
          report._add(kind);
          continue;
        }
        result[entry.key] = _stripNonFinite(v, report, kind);
      }
      return value is Map<String, Object?>
          ? result.cast<String, Object?>()
          : _retype(map, result);
    case final List<Object?> list:
      final result = <Object?>[];
      for (final v in list) {
        if (v is double && !v.isFinite) {
          report._add(kind);
          continue;
        }
        result.add(_stripNonFinite(v, report, kind));
      }
      return list is List<double> ? result.cast<double>().toList() : result;
    default:
      return value;
  }
}

/// Keeps the key and value types of the raw FIT field maps, which
/// deserialization casts back to `Map<int, double>` and
/// `Map<int, List<double>>`.
Object _retype(Map<Object?, Object?> original, Map<Object?, Object?> result) {
  if (original is Map<int, double>) return result.cast<int, double>();
  if (original is Map<int, List<double>>) {
    return {
      for (final e in result.entries)
        e.key as int: (e.value as List).cast<double>().toList(),
    };
  }
  return result;
}
