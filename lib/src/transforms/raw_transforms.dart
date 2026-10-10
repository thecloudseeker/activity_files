// SPDX-License-Identifier: BSD-3-Clause
part of '../transforms.dart';

/// Stateless helpers for generating derived activities.
class RawTransforms {
  const RawTransforms._();

  /// Resamples [activity] onto a fixed time grid of [step], starting at the
  /// first point's time.
  ///
  /// Use this when a consumer needs one sample per interval: charting, feeding
  /// a model that expects a regular cadence, or comparing two recordings
  /// sample by sample. [RawEditor.downsampleTime] is the cheaper choice when
  /// you only want fewer points, since it keeps original samples and drops the
  /// rest, while this one synthesizes new ones.
  ///
  /// Points, and every channel other than [Channel.heartRate], are
  /// interpolated linearly between the two neighbouring samples. Heart rate
  /// takes the nearest sample within half a [step] and emits nothing when
  /// there is none, so gaps in heart rate coverage stay gaps instead of being
  /// bridged. Past a channel's last sample its final value is held.
  ///
  /// The activity's last timestamp is always the closing grid point even when
  /// it does not fall on [step], so the final interval can be shorter than the
  /// others. Points out of chronological order are sorted first. Laps,
  /// summary, device metadata, and every other field carry over untouched, so
  /// a lap boundary may no longer line up with a point.
  ///
  /// Returns [activity] unchanged when it has fewer than two points, and
  /// throws [ArgumentError] when [step] is zero or negative. Interpolating a
  /// multi-hour recording is CPU-heavy, so consider running it off the main
  /// isolate.
  ///
  /// ```dart
  /// final onGrid = RawTransforms.resample(
  ///   activity,
  ///   step: const Duration(seconds: 1),
  /// );
  /// ```
  static RawActivity resample(RawActivity activity, {required Duration step}) {
    if (step <= Duration.zero) {
      throw ArgumentError.value(step, 'step', 'must be positive');
    }
    final original = _isSortedByTime(activity.points)
        ? activity.points
        : ([...activity.points]..sort((a, b) => a.time.compareTo(b.time)));
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
  ///
  /// [RawEditor.recomputeDistanceAndSpeed] walks the same points with the same
  /// haversine call and writes the same `Channel.distance`, and additionally
  /// writes `Channel.speed` and sorts first when timestamps are out of order.
  /// Read the total from the last distance sample, or use
  /// [RawActivity.approximateDistance]:
  ///
  /// ```dart
  /// final updated = ActivityFiles.edit(activity)
  ///     .recomputeDistanceAndSpeed()
  ///     .activity;
  /// final total = updated.channels[Channel.distance]!.last.value;
  /// ```
  @Deprecated(
    'Use ActivityFiles.edit(activity).recomputeDistanceAndSpeed(), then read '
    'the last Channel.distance sample for the total. '
    'Will be removed in 0.10.0.',
  )
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
      cumulative += haversineMeters(prev, point);
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
