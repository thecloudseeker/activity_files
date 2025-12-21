// SPDX-License-Identifier: BSD-3-Clause

import 'models.dart';

/// Snapshot of sensor values at a specific timestamp.
class ChannelSnapshot {
  ChannelSnapshot._(Map<Channel, ChannelReading> readings, {this.pace})
    : _readings = Map.unmodifiable(readings);

  final Map<Channel, ChannelReading> _readings;

  /// All resolved channel readings keyed by channel.
  Map<Channel, ChannelReading> get readings => _readings;

  /// Returns the reading for [channel], if present.
  ChannelReading? reading(Channel channel) => _readings[channel];

  /// Convenience accessor returning the value for [channel].
  double? valueFor(Channel channel) => reading(channel)?.value;

  /// Convenience accessor returning the sample delta for [channel].
  Duration? deltaFor(Channel channel) => reading(channel)?.delta;

  /// Pace as seconds per kilometer when derived from speed.
  final double? pace;

  /// Heart rate in beats per minute.
  double? get heartRate => valueFor(Channel.heartRate);

  /// Time delta between request and heart-rate sample.
  Duration? get heartRateDelta => deltaFor(Channel.heartRate);

  /// Cadence in revolutions per minute.
  double? get cadence => valueFor(Channel.cadence);

  /// Time delta for cadence sample.
  Duration? get cadenceDelta => deltaFor(Channel.cadence);

  /// Power in watts.
  double? get power => valueFor(Channel.power);

  /// Time delta for power sample.
  Duration? get powerDelta => deltaFor(Channel.power);

  /// Temperature in degrees Celsius.
  double? get temperature => valueFor(Channel.temperature);

  /// Time delta for temperature sample.
  Duration? get temperatureDelta => deltaFor(Channel.temperature);

  /// Speed in meters per second.
  double? get speed => valueFor(Channel.speed);

  /// Time delta for speed sample.
  Duration? get speedDelta => deltaFor(Channel.speed);

  /// Whether no channel was resolved.
  bool get isEmpty => _readings.isEmpty;
}

/// Reading for a single channel.
class ChannelReading {
  const ChannelReading({required this.value, required this.delta});

  /// Sample value.
  final double value;

  /// Absolute time delta between the request timestamp and the sample.
  final Duration delta;
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
  }) => cursor(channels, maxDelta: maxDelta).snapshot(timestamp);

  /// Returns a reusable cursor that keeps per-channel indices hot while
  /// iterating over chronological timestamps.
  static ChannelCursor cursor(
    Map<Channel, List<Sample>> channels, {
    Duration maxDelta = const Duration(seconds: 5),
  }) => ChannelCursor._(channels, maxDelta: maxDelta);
}

/// Maintains per-channel cursors and cached timestamps for repeated lookups.
class ChannelCursor {
  ChannelCursor._(
    Map<Channel, List<Sample>> channels, {
    Duration maxDelta = const Duration(seconds: 5),
  }) : _maxDeltaMicros = maxDelta.inMicroseconds.abs(),
       _series = {
         for (final entry in channels.entries)
           if (entry.value.isNotEmpty) entry.key: _ChannelSeries(entry.value),
       };

  final int _maxDeltaMicros;
  final Map<Channel, _ChannelSeries> _series;

  /// Resolves channel readings at [timestamp].
  ChannelSnapshot snapshot(DateTime timestamp) {
    final targetMicros = timestamp.toUtc().microsecondsSinceEpoch;
    final readings = <Channel, ChannelReading>{};
    for (final entry in _series.entries) {
      final sample = entry.value.nearest(targetMicros, _maxDeltaMicros);
      if (sample == null) {
        continue;
      }
      final deltaMicros =
          (sample.time.toUtc().microsecondsSinceEpoch - targetMicros).abs();
      readings[entry.key] = ChannelReading(
        value: sample.value,
        delta: Duration(microseconds: deltaMicros),
      );
    }
    final speedReading = readings[Channel.speed];
    double? pace;
    if (speedReading != null &&
        speedReading.value > 0 &&
        speedReading.delta.inMicroseconds <= _maxDeltaMicros) {
      pace = 1000.0 / speedReading.value;
    }
    return ChannelSnapshot._(readings, pace: pace);
  }
}

class _ChannelSeries {
  _ChannelSeries(List<Sample> samples)
    : _samples = samples,
      _timestamps = samples
          .map((sample) => sample.time.toUtc().microsecondsSinceEpoch)
          .toList(growable: false);

  final List<Sample> _samples;
  final List<int> _timestamps;
  int _cursor = 0;
  int? _lastTarget;

  Sample? nearest(int targetMicros, int toleranceMicros) {
    if (_samples.isEmpty) {
      return null;
    }
    if (_samples.length == 1) {
      final delta = (_timestamps.first - targetMicros).abs();
      return delta <= toleranceMicros ? _samples.first : null;
    }
    if (_lastTarget != null && targetMicros >= _lastTarget!) {
      while (_cursor < _timestamps.length &&
          _timestamps[_cursor] < targetMicros) {
        _cursor++;
      }
    } else {
      _cursor = _lowerBound(targetMicros);
    }
    _lastTarget = targetMicros;
    if (_cursor >= _timestamps.length) {
      _cursor = _timestamps.length - 1;
    }
    Sample? candidate;
    var bestDelta = toleranceMicros + 1;
    void consider(int index) {
      if (index < 0 || index >= _timestamps.length) {
        return;
      }
      final delta = (_timestamps[index] - targetMicros).abs();
      if (delta <= toleranceMicros && delta < bestDelta) {
        candidate = _samples[index];
        bestDelta = delta;
      }
    }

    consider(_cursor);
    consider(_cursor - 1);
    return candidate;
  }

  int _lowerBound(int target) {
    var low = 0;
    var high = _timestamps.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_timestamps[mid] < target) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low >= _timestamps.length) {
      return _timestamps.length - 1;
    }
    return low;
  }
}
