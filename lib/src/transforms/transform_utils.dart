part of '../transforms.dart';

double _haversine(GeoPoint a, GeoPoint b) {
  const earthRadius = 6371000.0;
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

double _radians(double deg) => deg * math.pi / 180.0;

List<GeoPoint> _resamplePoints(List<GeoPoint> points, List<DateTime> times) {
  final result = <GeoPoint>[];
  if (points.isEmpty) {
    return result;
  }
  var upperIndex = 1;
  for (final time in times) {
    while (upperIndex < points.length &&
        points[upperIndex].time.isBefore(time)) {
      upperIndex++;
    }
    if (upperIndex >= points.length) {
      final last = points.last;
      result.add(last.copyWith(time: time));
      continue;
    }
    final lowerIndex = upperIndex == 0 ? 0 : upperIndex - 1;
    final lower = points[lowerIndex];
    final upper = points[upperIndex];
    if (time.isAtSameMomentAs(lower.time)) {
      result.add(lower);
      continue;
    }
    if (time.isAtSameMomentAs(upper.time)) {
      result.add(upper);
      continue;
    }
    result.add(_interpolatePoint(lower, upper, time));
  }
  return result;
}

List<Sample> _resampleLinear(List<Sample> samples, List<DateTime> times) {
  if (samples.isEmpty) {
    return const <Sample>[];
  }
  final result = <Sample>[];
  var upperIndex = 1;
  for (final time in times) {
    while (upperIndex < samples.length &&
        samples[upperIndex].time.isBefore(time)) {
      upperIndex++;
    }
    if (upperIndex >= samples.length) {
      final last = samples.last;
      result.add(Sample(time: time, value: last.value));
      continue;
    }
    final lowerIndex = upperIndex == 0 ? 0 : upperIndex - 1;
    final lower = samples[lowerIndex];
    final upper = samples[upperIndex];
    if (time.isAtSameMomentAs(lower.time)) {
      result.add(Sample(time: time, value: lower.value));
      continue;
    }
    if (time.isAtSameMomentAs(upper.time)) {
      result.add(Sample(time: time, value: upper.value));
      continue;
    }
    final value = _interpolateValue(
      lower.time,
      upper.time,
      time,
      lower.value,
      upper.value,
    );
    result.add(Sample(time: time, value: value));
  }
  return result;
}

Duration _channelSnapTolerance(List<GeoPoint> points) {
  if (points.length < 2) {
    return const Duration(seconds: 1);
  }
  final totalMicros =
      points.last.time.microsecondsSinceEpoch -
      points.first.time.microsecondsSinceEpoch;
  if (totalMicros <= 0) {
    return const Duration(milliseconds: 500);
  }
  final averageMicros = totalMicros ~/ (points.length - 1);
  final half = math.max(1, averageMicros ~/ 2);
  const minTolerance = Duration(milliseconds: 200);
  const maxTolerance = Duration(seconds: 10);
  final clamped = half.clamp(
    minTolerance.inMicroseconds,
    maxTolerance.inMicroseconds,
  );
  return Duration(microseconds: clamped.toInt());
}

List<Sample> _resampleNearest(
  List<Sample> samples,
  List<DateTime> times,
  Duration tolerance,
) {
  if (samples.isEmpty) {
    return const <Sample>[];
  }
  final toleranceMicros = tolerance.inMicroseconds.abs();
  final result = <Sample>[];
  var cursor = 0;
  for (final time in times) {
    final targetMicros = time.toUtc().microsecondsSinceEpoch;
    while (cursor < samples.length &&
        samples[cursor].time.toUtc().microsecondsSinceEpoch < targetMicros) {
      cursor++;
    }
    if (cursor >= samples.length) {
      cursor = samples.length - 1;
    }
    Sample? candidate;
    var smallest = toleranceMicros + 1;
    void consider(int index) {
      if (index < 0 || index >= samples.length) {
        return;
      }
      final sampleMicros = samples[index].time.toUtc().microsecondsSinceEpoch;
      final delta = (sampleMicros - targetMicros).abs();
      if (delta <= toleranceMicros && delta < smallest) {
        candidate = samples[index];
        smallest = delta;
      }
    }

    consider(cursor);
    consider(cursor - 1);
    consider(cursor + 1);
    final match = candidate;
    if (match != null) {
      result.add(Sample(time: time, value: match.value));
    }
  }
  return result;
}

GeoPoint _interpolatePoint(GeoPoint lower, GeoPoint upper, DateTime target) {
  final factor = _timeLerpFactor(lower.time, upper.time, target);
  final elevation = _interpolateOptional(
    lower.elevation,
    upper.elevation,
    factor,
  );
  return GeoPoint(
    latitude: _interpolateValue(
      lower.time,
      upper.time,
      target,
      lower.latitude,
      upper.latitude,
    ),
    longitude: _interpolateValue(
      lower.time,
      upper.time,
      target,
      lower.longitude,
      upper.longitude,
    ),
    elevation: elevation,
    time: target,
  );
}

double _interpolateValue(
  DateTime lowerTime,
  DateTime upperTime,
  DateTime target,
  double lowerValue,
  double upperValue,
) {
  final factor = _timeLerpFactor(lowerTime, upperTime, target);
  return lowerValue + (upperValue - lowerValue) * factor;
}

double? _interpolateOptional(double? a, double? b, double factor) {
  if (a == null && b == null) {
    return null;
  }
  if (a == null) {
    return b;
  }
  if (b == null) {
    return a;
  }
  return a + (b - a) * factor;
}

double _timeLerpFactor(DateTime lower, DateTime upper, DateTime target) {
  final lowerMicros = lower.microsecondsSinceEpoch;
  final upperMicros = upper.microsecondsSinceEpoch;
  final targetMicros = target.microsecondsSinceEpoch;
  final span = (upperMicros - lowerMicros).toDouble();
  if (span == 0) {
    return 0;
  }
  return (targetMicros - lowerMicros) / span;
}
