// MIT License
//
// Copyright (c) 2024 activity_files
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

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
    final target = timestamp.toUtc();
    final maxDeltaMicros = maxDelta.inMicroseconds;

    ({double? value, Duration? delta}) resolve(Channel channel) {
      final samples = channels[channel];
      if (samples == null || samples.isEmpty) {
        return (value: null, delta: null);
      }
      final targetMicros = target.microsecondsSinceEpoch;
      Sample? nearest;
      var nearestDelta = maxDeltaMicros + 1;
      for (final sample in samples) {
        final delta = (sample.time.microsecondsSinceEpoch - targetMicros).abs();
        if (delta < nearestDelta && delta <= maxDeltaMicros) {
          nearest = sample;
          nearestDelta = delta;
        }
        if (delta > nearestDelta && sample.time.isAfter(target)) {
          break;
        }
      }
      if (nearest == null) {
        return (value: null, delta: null);
      }
      return (
        value: nearest.value,
        delta: Duration(microseconds: nearestDelta),
      );
    }

    final hr = resolve(Channel.heartRate);
    final cadence = resolve(Channel.cadence);
    final power = resolve(Channel.power);
    final temperature = resolve(Channel.temperature);
    final speed = resolve(Channel.speed);
    final pace = speed.value != null && speed.value! > 0
        ? 1000.0 / speed.value!
        : null; // s/km from m/s

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
}
