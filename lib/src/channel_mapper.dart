// SPDX-License-Identifier: BSD-3-Clause

import 'models.dart';

/// Snapshot of sensor values at a specific timestamp.
class ChannelSnapshot {
  const ChannelSnapshot({
    this.heartRate,
    this.heartRateDelta,
    this.cadence,
    this.cadenceDelta,
    this.power,
    this.powerDelta,
    this.temperature,
    this.temperatureDelta,
    this.speed,
    this.speedDelta,
    this.pace,
  });

  /// Heart rate in beats per minute.
  final double? heartRate;

  /// Time delta between request and heart-rate sample.
  final Duration? heartRateDelta;

  /// Cadence in revolutions per minute.
  final double? cadence;

  /// Time delta for cadence sample.
  final Duration? cadenceDelta;

  /// Power in watts.
  final double? power;

  /// Time delta for power sample.
  final Duration? powerDelta;

  /// Temperature in degrees Celsius.
  final double? temperature;

  /// Time delta for temperature sample.
  final Duration? temperatureDelta;

  /// Speed in meters per second.
  final double? speed;

  /// Time delta for speed sample.
  final Duration? speedDelta;

  /// Pace as seconds per kilometer.
  final double? pace;

  /// Whether no channel was resolved.
  bool get isEmpty =>
      heartRate == null &&
      cadence == null &&
      power == null &&
      temperature == null &&
      speed == null &&
      pace == null;
}

/// Utility for extracting channel values at arbitrary timestamps.
class ChannelMapper {
  /// Finds the nearest sample per channel at [timestamp].
  ///
  /// When no sample is found within [maxDelta], the corresponding value is
  /// omitted. Pace is derived from speed when available, expressed in seconds
  /// per kilometer.
  static ChannelSnapshot mapAt(
    DateTime timestamp,
    Map<Channel, List<Sample>> channels, {
    Duration maxDelta = const Duration(seconds: 5),
  }) {
    // TODO(extensibility): Consider exposing a channel-agnostic snapshot map so
    // new Channel enum entries become available without updating this helper.
    final target = timestamp.toUtc();
    final maxDeltaMicros = maxDelta.inMicroseconds;
    // TODO(perf-fancy-sweep): Explore a sweep-line cursor or segment tree that
    // advances all channels in lockstep (the fancy shmancy algo cool kids use)
    // so repeated scrubs avoid fresh binary searches for every lookup.

    ({double? value, Duration? delta}) resolve(Channel channel) {
      final samples = channels[channel];
      if (samples == null || samples.isEmpty) {
        return (value: null, delta: null);
      }
      final targetMicros = target.microsecondsSinceEpoch;
      // TODO(perf): Cache per-sample timestamps (e.g. alongside Sample or in a
      // parallel Int32List) so repeated lookups avoid DateTime conversions.
      final nearest = _nearestSampleWithin(
        samples,
        targetMicros: targetMicros,
        maxDeltaMicros: maxDeltaMicros,
      );
      if (nearest == null) {
        return (value: null, delta: null);
      }
      final deltaMicros = (nearest.time.microsecondsSinceEpoch - targetMicros)
          .abs();
      return (value: nearest.value, delta: Duration(microseconds: deltaMicros));
    }

    final hr = resolve(Channel.heartRate);
    final cadence = resolve(Channel.cadence);
    final power = resolve(Channel.power);
    final temperature = resolve(Channel.temperature);
    final speed = resolve(Channel.speed);
    final hasFreshSpeed =
        speed.value != null &&
        speed.value! > 0 &&
        speed.delta != null &&
        speed.delta!.inMicroseconds <= maxDeltaMicros;
    final pace = hasFreshSpeed ? 1000.0 / speed.value! : null; // s/km from m/s

    return ChannelSnapshot(
      heartRate: hr.value,
      heartRateDelta: hr.delta,
      cadence: cadence.value,
      cadenceDelta: cadence.delta,
      power: power.value,
      powerDelta: power.delta,
      temperature: temperature.value,
      temperatureDelta: temperature.delta,
      speed: speed.value,
      speedDelta: speed.delta,
      pace: pace,
    );
  }

  /// Returns the nearest sample to [targetMicros] within [maxDeltaMicros]
  /// using binary search (assuming samples sorted by time).
  // TODO(perf): Provide a cursor API that reuses per-channel indices for
  // sequential timeline scrubs instead of re-running binary search.
  static Sample? _nearestSampleWithin(
    List<Sample> samples, {
    required int targetMicros,
    required int maxDeltaMicros,
  }) {
    if (samples.length == 1) {
      final single = samples.first;
      final delta = (single.time.microsecondsSinceEpoch - targetMicros).abs();
      return delta <= maxDeltaMicros ? single : null;
    }
    var low = 0;
    var high = samples.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final sampleTime = samples[mid].time.microsecondsSinceEpoch;
      if (sampleTime < targetMicros) {
        low = mid + 1;
      } else if (sampleTime > targetMicros) {
        high = mid - 1;
      } else {
        return samples[mid];
      }
    }

    Sample? best;
    var bestDelta = maxDeltaMicros + 1;
    void consider(int index) {
      if (index < 0 || index >= samples.length) {
        return;
      }
      final sample = samples[index];
      final delta = (sample.time.microsecondsSinceEpoch - targetMicros).abs();
      if (delta <= maxDeltaMicros && delta < bestDelta) {
        best = sample;
        bestDelta = delta;
      }
    }

    consider(low);
    consider(low - 1);
    return best;
  }
}
