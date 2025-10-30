// SPDX-License-Identifier: BSD-3-Clause
import 'dart:math' as math;
import 'models.dart';
/// Stateless helpers for generating derived activities.
class RawTransforms {
  const RawTransforms._();
  /// Resamples [activity] to a fixed temporal [step] using linear interpolation
  /// for trajectory and continuous channels. Heart rate uses nearest samples.
  static RawActivity resample(
    RawActivity activity, {
    required Duration step,
  }) {
    if (step <= Duration.zero) {
      throw ArgumentError.value(step, 'step', 'must be positive');
    }
    final original = activity.points;
    if (original.length < 2) {
      return activity;
    }
    final start = original.first.time;
    final end = original.last.time;
    final times = <DateTime>[];
    var current = start;
    while (!current.isAfter(end)) {
      times.add(current);
      current = current.add(step);
    }
    if (!times.last.isAtSameMomentAs(end)) {
      times.add(end);
    }
    final resampledPoints = _resamplePoints(original, times);
    final channelMap = <Channel, List<Sample>>{};
    for (final entry in activity.channels.entries) {
      if (entry.value.isEmpty) {
        channelMap[entry.key] = entry.value;
        continue;
      }
      final isHeartRate = entry.key == Channel.heartRate;
      final tolerance = Duration(microseconds: step.inMicroseconds ~/ 2);
      channelMap[entry.key] = isHeartRate
          ? _resampleNearest(entry.value, times, tolerance)
          : _resampleLinear(entry.value, times);
    }
    return activity.copyWith(
      points: resampledPoints,
      channels: channelMap,
    );
  }
  /// Computes cumulative distance (meters) using the haversine formula.
  static ({RawActivity activity, double totalDistance})
      computeCumulativeDistance(RawActivity activity) {
    if (activity.points.length < 2) {
      final updatedChannels = {...activity.channels};
      if (activity.points.isNotEmpty) {
        updatedChannels[Channel.distance] = [
          Sample(time: activity.points.first.time, value: 0),
        ];
      }
      return (
        activity: activity.copyWith(channels: updatedChannels),
        totalDistance: 0,
      );
    }
    final samples = <Sample>[];
    var cumulative = 0.0;
    for (var i = 0; i < activity.points.length; i++) {
      final point = activity.points[i];
      if (i == 0) {
        samples.add(Sample(time: point.time, value: 0));
        continue;
      }
      final prev = activity.points[i - 1];
      cumulative += _haversine(prev, point);
      samples.add(Sample(time: point.time, value: cumulative));
    }
    final updatedChannels = {...activity.channels}..[Channel.distance] =
        samples;
    return (
      activity: activity.copyWith(channels: updatedChannels),
      totalDistance: cumulative,
    );
  }
}
/// Provides chained, immutable transformations over [RawActivity].
class RawEditor {
  RawEditor(RawActivity activity) : _activity = activity;
  RawActivity _activity;
  /// Returns the current result.
  RawActivity get activity => _activity;
  /// Ensures samples and points are sorted by time and removes duplicates.
  RawEditor sortAndDedup() {
    final sortedPoints = [..._activity.points]
      ..sort((a, b) => a.time.compareTo(b.time));
    final dedupedPoints = <GeoPoint>[];
    GeoPoint? previous;
    for (final point in sortedPoints) {
      final prev = previous;
      final isDuplicate = prev != null &&
          prev.time == point.time &&
          prev.latitude == point.latitude &&
          prev.longitude == point.longitude;
      if (!isDuplicate) {
        dedupedPoints.add(point);
        previous = point;
      }
    }
    final sortedChannels = _activity.channels.map((channel, samples) {
      final sorted = [...samples]..sort((a, b) => a.time.compareTo(b.time));
      final deduped = <Sample>[];
      Sample? last;
      for (final sample in sorted) {
        if (last == null || last.time != sample.time) {
          deduped.add(sample);
          last = sample;
        }
      }
      return MapEntry(channel, deduped);
    });
    final sortedLaps = [..._activity.laps]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    _activity = _activity.copyWith(
      points: dedupedPoints,
      channels: sortedChannels.map(
        (key, value) => MapEntry(key, value),
      ),
      laps: sortedLaps,
    );
    return this;
  }
  /// Drops invalid coordinates and trims channels outside the point range.
  RawEditor trimInvalid() {
    final validPoints = _activity.points.where((point) {
      final latOk = point.latitude.isFinite &&
          point.latitude >= -90 &&
          point.latitude <= 90;
      final lonOk = point.longitude.isFinite &&
          point.longitude >= -180 &&
          point.longitude <= 180;
      return latOk && lonOk;
    }).toList();
    final start = validPoints.isNotEmpty ? validPoints.first.time : null;
    final end = validPoints.isNotEmpty ? validPoints.last.time : null;
    final trimmedChannels = _activity.channels.map((channel, samples) {
      if (start == null || end == null) {
        return MapEntry(channel, <Sample>[]);
      }
      final filtered = samples
          .where((sample) =>
              !sample.time.isBefore(start) && !sample.time.isAfter(end))
          .toList();
      return MapEntry(channel, filtered);
    });
    final trimmedLaps = <Lap>[];
    if (start != null && end != null) {
      final startUtc = start;
      final endUtc = end;
      trimmedLaps.addAll(
        _activity.laps
            .where((lap) =>
                !lap.endTime.isBefore(startUtc) &&
                !lap.startTime.isAfter(endUtc))
            .map((lap) {
          final lapStart =
              lap.startTime.isBefore(startUtc) ? startUtc : lap.startTime;
          final lapEnd = lap.endTime.isAfter(endUtc) ? endUtc : lap.endTime;
          return lap.copyWith(startTime: lapStart, endTime: lapEnd);
        }),
      );
    }
    _activity = _activity.copyWith(
      points: validPoints,
      channels: trimmedChannels.map((key, value) => MapEntry(key, value)),
      laps: trimmedLaps,
    );
    return this;
  }
  /// Crops the activity to the inclusive [start] and [end] times.
  RawEditor crop(DateTime start, DateTime end) {
    if (end.isBefore(start)) {
      throw ArgumentError.value(end, 'end', 'must be after start');
    }
    final startUtc = start.toUtc();
    final endUtc = end.toUtc();
    final croppedPoints = _activity.points
        .where(
          (point) =>
              !point.time.isBefore(startUtc) && !point.time.isAfter(endUtc),
        )
        .toList();
    final croppedChannels = _activity.channels.map((channel, samples) {
      final filtered = samples
          .where((sample) =>
              !sample.time.isBefore(startUtc) && !sample.time.isAfter(endUtc))
          .toList();
      return MapEntry(channel, filtered);
    });
    final croppedLaps = _activity.laps.where((lap) {
      return !lap.endTime.isBefore(startUtc) && !lap.startTime.isAfter(endUtc);
    }).map((lap) {
      final lapStart =
          lap.startTime.isBefore(startUtc) ? startUtc : lap.startTime;
      final lapEnd = lap.endTime.isAfter(endUtc) ? endUtc : lap.endTime;
      return lap.copyWith(startTime: lapStart, endTime: lapEnd);
    }).toList();
    _activity = _activity.copyWith(
      points: croppedPoints,
      channels: croppedChannels.map((key, value) => MapEntry(key, value)),
      laps: croppedLaps,
    );
    return this;
  }
  /// Offsets all timestamps by [delta].
  RawEditor shiftTime(Duration delta) {
    final shiftedPoints = _activity.points
        .map(
          (point) => point.copyWith(time: point.time.add(delta)),
        )
        .toList();
    final shiftedChannels = _activity.channels.map((channel, samples) {
      final shifted = samples
          .map(
            (sample) => sample.copyWith(time: sample.time.add(delta)),
          )
          .toList();
      return MapEntry(channel, shifted);
    });
    final shiftedLaps = _activity.laps
        .map(
          (lap) => lap.copyWith(
            startTime: lap.startTime.add(delta),
            endTime: lap.endTime.add(delta),
          ),
        )
        .toList();
    _activity = _activity.copyWith(
      points: shiftedPoints,
      channels: shiftedChannels.map((key, value) => MapEntry(key, value)),
      laps: shiftedLaps,
    );
    return this;
  }
  /// Down-samples by the minimum [step] between consecutive timestamps.
  RawEditor downsampleTime(Duration step) {
    if (step.isNegative || step == Duration.zero) {
      throw ArgumentError.value(step, 'step', 'must be positive');
    }
    final retained = <GeoPoint>[];
    DateTime? lastKept;
    for (final point in _activity.points) {
      final previous = lastKept;
      if (previous == null || point.time.difference(previous) >= step) {
        retained.add(point);
        lastKept = point.time;
      }
    }
    final retainedTimes =
        retained.map((point) => point.time.microsecondsSinceEpoch).toList();
    final tolerance = math.max(1, step.inMicroseconds ~/ 2);
    final filteredChannels = _activity.channels.map((channel, samples) {
      final filtered = samples.where((sample) {
        final sampleMicros = sample.time.microsecondsSinceEpoch;
        return retainedTimes.any(
          (kept) => (kept - sampleMicros).abs() <= tolerance,
        );
      }).toList();
      return MapEntry(channel, filtered);
    });
    _activity = _activity.copyWith(
      points: retained,
      channels: filteredChannels.map((key, value) => MapEntry(key, value)),
    );
    return this;
  }
  /// Down-samples by requiring at least [meters] between consecutive points.
  RawEditor downsampleDistance(double meters) {
    if (meters <= 0) {
      throw ArgumentError.value(meters, 'meters', 'must be positive');
    }
    if (_activity.points.length < 2) {
      return this;
    }
    final retained = <GeoPoint>[_activity.points.first];
    var lastKept = _activity.points.first;
    for (final point in _activity.points.skip(1)) {
      final distance = _haversine(lastKept, point);
      if (distance >= meters) {
        retained.add(point);
        lastKept = point;
      }
    }
    final retainedTimes =
        retained.map((point) => point.time.microsecondsSinceEpoch).toSet();
    final filteredChannels = _activity.channels.map((channel, samples) {
      final filtered = samples
          .where(
            (sample) => retainedTimes.contains(
              sample.time.microsecondsSinceEpoch,
            ),
          )
          .toList();
      return MapEntry(channel, filtered);
    });
    _activity = _activity.copyWith(
      points: retained,
      channels: filteredChannels.map((key, value) => MapEntry(key, value)),
    );
    return this;
  }
  /// Applies a moving-average smoothing over the heart-rate channel.
  RawEditor smoothHR(int window) {
    if (window <= 1) {
      return this;
    }
    final hrSamples = _activity.channel(Channel.heartRate);
    if (hrSamples.isEmpty) {
      return this;
    }
    final halfWindow = window ~/ 2;
    final smoothed = <Sample>[];
    for (var i = 0; i < hrSamples.length; i++) {
      final start = math.max(0, i - halfWindow);
      final end = math.min(hrSamples.length - 1, i + halfWindow);
      var total = 0.0;
      var count = 0;
      for (var j = start; j <= end; j++) {
        total += hrSamples[j].value;
        count++;
      }
      final averaged = total / count;
      smoothed.add(
        hrSamples[i].copyWith(value: averaged),
      );
    }
    final newChannels = {
      for (final entry in _activity.channels.entries) entry.key: entry.value,
    };
    newChannels[Channel.heartRate] = smoothed;
    _activity = _activity.copyWith(channels: newChannels);
    return this;
  }
  /// Recomputes distance (meters) and speed (meters per second) from the trajectory.
  RawEditor recomputeDistanceAndSpeed() {
    if (_activity.points.length < 2) {
      return this;
    }
    final cumulative = <Sample>[];
    final speed = <Sample>[];
    var total = 0.0;
    for (var i = 0; i < _activity.points.length; i++) {
      final point = _activity.points[i];
      if (i == 0) {
        cumulative.add(Sample(time: point.time, value: 0));
        speed.add(Sample(time: point.time, value: 0));
        continue;
      }
      final previous = _activity.points[i - 1];
      final deltaDistance = _haversine(previous, point);
      total += deltaDistance;
      final deltaTime =
          point.time.difference(previous.time).inMicroseconds / 1e6;
      final currentSpeed = deltaTime > 0 ? deltaDistance / deltaTime : 0.0;
      cumulative.add(Sample(time: point.time, value: total));
      speed.add(Sample(time: point.time, value: currentSpeed));
    }
    final newChannels = {
      for (final entry in _activity.channels.entries) entry.key: entry.value,
    };
    newChannels[Channel.distance] = cumulative;
    newChannels[Channel.speed] = speed;
    _activity = _activity.copyWith(channels: newChannels);
    return this;
  }
  /// Generates laps at every [meters] boundary using the distance channel.
  RawEditor markLapsByDistance(double meters) {
    if (meters <= 0) {
      throw ArgumentError.value(meters, 'meters', 'must be positive');
    }
    final distanceSamples = _activity.channel(Channel.distance);
    if (distanceSamples.isEmpty) {
      return this;
    }
    final laps = <Lap>[];
    double nextSplit = meters;
    DateTime? lapStart = distanceSamples.first.time;
    for (final sample in distanceSamples) {
      if (sample.value >= nextSplit) {
        laps.add(
          Lap(
            startTime: lapStart ?? sample.time,
            endTime: sample.time,
            distanceMeters: sample.value,
            name: 'Split ${laps.length + 1}',
          ),
        );
        lapStart = sample.time;
        nextSplit += meters;
      }
    }
    if (laps.isEmpty && _activity.points.isNotEmpty) {
      laps.add(
        Lap(
          startTime: _activity.points.first.time,
          endTime: _activity.points.last.time,
          distanceMeters: distanceSamples.last.value,
          name: 'Split 1',
        ),
      );
    }
    _activity = _activity.copyWith(laps: laps);
    return this;
  }
}
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
    while (
        upperIndex < points.length && points[upperIndex].time.isBefore(time)) {
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
        lower.time, upper.time, time, lower.value, upper.value);
    result.add(Sample(time: time, value: value));
  }
  return result;
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
  for (final time in times) {
    final targetMicros = time.toUtc().microsecondsSinceEpoch;
    Sample? candidate;
    var smallest = toleranceMicros + 1;
    for (final sample in samples) {
      final delta = (sample.time.microsecondsSinceEpoch - targetMicros).abs();
      if (delta <= toleranceMicros && delta < smallest) {
        candidate = sample;
        smallest = delta;
      }
      if (candidate != null && sample.time.isAfter(time) && delta > smallest) {
        break;
      }
    }
    if (candidate != null) {
      result.add(Sample(time: time, value: candidate.value));
    }
  }
  return result;
}
GeoPoint _interpolatePoint(GeoPoint lower, GeoPoint upper, DateTime target) {
  final factor = _timeLerpFactor(lower.time, upper.time, target);
  final elevation =
      _interpolateOptional(lower.elevation, upper.elevation, factor);
  return GeoPoint(
    latitude: _interpolateValue(
        lower.time, upper.time, target, lower.latitude, upper.latitude),
    longitude: _interpolateValue(
        lower.time, upper.time, target, lower.longitude, upper.longitude),
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
