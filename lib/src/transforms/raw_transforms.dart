part of '../transforms.dart';

/// Stateless helpers for generating derived activities.
class RawTransforms {
  const RawTransforms._();

  /// Resamples [activity] to a fixed temporal [step] using linear interpolation
  /// for trajectory and continuous channels. Heart rate uses nearest samples.
  static RawActivity resample(RawActivity activity, {required Duration step}) {
    if (step <= Duration.zero) {
      throw ArgumentError.value(step, 'step', 'must be positive');
    }
    final original = _isSortedByTime(activity.points)
        ? activity.points
        : ([...activity.points]..sort((a, b) => a.time.compareTo(b.time)));
    // TODO(0.6.0)(validation): Sort/deduplicate channel samples here so
    // interpolation stays correct when callers skip normalization.
    if (original.length < 2) {
      return activity;
    }
    final start = original.first.time;
    final end = original.last.time;
    final totalSpanMicros =
        end.toUtc().microsecondsSinceEpoch -
        start.toUtc().microsecondsSinceEpoch;
    final estimatedCount = totalSpanMicros <= 0
        ? 1
        : (totalSpanMicros ~/ step.inMicroseconds) + 1;
    final times = List<DateTime>.filled(estimatedCount, start, growable: true);
    var index = 0;
    var current = start;
    while (!current.isAfter(end)) {
      if (index < times.length) {
        times[index] = current;
      } else {
        times.add(current);
      }
      index++;
      current = current.add(step);
    }
    if (times.isEmpty || !times[index - 1].isAtSameMomentAs(end)) {
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
    return activity.copyWith(points: resampledPoints, channels: channelMap);
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
    final updatedChannels = {...activity.channels}
      ..[Channel.distance] = samples;
    return (
      activity: activity.copyWith(channels: updatedChannels),
      totalDistance: cumulative,
    );
  }
}
