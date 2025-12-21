part of '../transforms.dart';

/// Provides chained, immutable transformations over [RawActivity].
class RawEditor {
  RawEditor(RawActivity activity) : _activity = activity;
  RawActivity _activity;

  /// Returns the current result.
  RawActivity get activity => _activity;

  // TODO(0.6.0)(feature): Provide helpers (e.g. histogram, HR zones) that
  // operate on the edited activity so callers don’t need a separate pass over
  // the data.

  /// Ensures samples and points are sorted by time and removes duplicates.
  RawEditor sortAndDedup() {
    final alreadySortedPoints = _isSortedByTime(_activity.points);
    final sortedPoints = alreadySortedPoints
        ? _activity.points
        : ([..._activity.points]..sort((a, b) => a.time.compareTo(b.time)));
    final dedupedPoints = <GeoPoint>[];
    GeoPoint? previous;
    for (final point in sortedPoints) {
      final prev = previous;
      final sameTimestamp =
          prev != null && prev.time.isAtSameMomentAs(point.time);
      if (sameTimestamp && dedupedPoints.isNotEmpty) {
        dedupedPoints[dedupedPoints.length - 1] = point;
        previous = point;
        continue;
      }
      dedupedPoints.add(point);
      previous = point;
    }
    final sortedChannels = _activity.channels.map((channel, samples) {
      final sorted = _isSortedSamples(samples)
          ? samples
          : ([...samples]..sort((a, b) => a.time.compareTo(b.time)));
      final deduped = <Sample>[];
      Sample? last;
      for (final sample in sorted) {
        if (last != null && last.time == sample.time) {
          deduped[deduped.length - 1] = sample;
          last = sample;
          continue;
        }
        deduped.add(sample);
        last = sample;
      }
      return MapEntry(channel, deduped);
    });
    final sortedLaps = _isSortedByStart(_activity.laps)
        ? _activity.laps
        : ([..._activity.laps]
            ..sort((a, b) => a.startTime.compareTo(b.startTime)));
    _activity = _activity.copyWith(
      points: dedupedPoints,
      channels: sortedChannels.map((key, value) => MapEntry(key, value)),
      laps: sortedLaps,
    );
    return this;
  }

  /// Drops invalid coordinates and trims channels outside the point range.
  RawEditor trimInvalid() {
    var allValid = true;
    final validPoints = _activity.points.where((point) {
      final latOk =
          point.latitude.isFinite &&
          point.latitude >= -90 &&
          point.latitude <= 90;
      final lonOk =
          point.longitude.isFinite &&
          point.longitude >= -180 &&
          point.longitude <= 180;
      final valid = latOk && lonOk;
      if (!valid) {
        allValid = false;
      }
      return valid;
    }).toList();
    // TODO(0.6.0)(feature): Preserve laps when all points are discarded so
    // sensor-only activities keep timing metadata.
    final retainedPoints = allValid
        ? List<GeoPoint>.from(_activity.points)
        : validPoints;
    final start = retainedPoints.isNotEmpty ? retainedPoints.first.time : null;
    final end = retainedPoints.isNotEmpty ? retainedPoints.last.time : null;
    final trimmedChannels = _activity.channels.map((channel, samples) {
      if (start == null || end == null) {
        // Preserve sensor-only activities by retaining their history when no
        // valid GPS fixes survive the trim.
        return MapEntry(channel, List<Sample>.from(samples));
      }
      final filtered = samples
          .where(
            (sample) =>
                !sample.time.isBefore(start) && !sample.time.isAfter(end),
          )
          .toList();
      return MapEntry(channel, filtered);
    });
    final trimmedLaps = <Lap>[];
    if (start != null && end != null) {
      final startUtc = start;
      final endUtc = end;
      trimmedLaps.addAll(
        _activity.laps
            .where(
              (lap) =>
                  !lap.endTime.isBefore(startUtc) &&
                  !lap.startTime.isAfter(endUtc),
            )
            .map((lap) {
              final lapStart = lap.startTime.isBefore(startUtc)
                  ? startUtc
                  : lap.startTime;
              final lapEnd = lap.endTime.isAfter(endUtc) ? endUtc : lap.endTime;
              return lap.copyWith(startTime: lapStart, endTime: lapEnd);
            }),
      );
    }
    _activity = _activity.copyWith(
      points: retainedPoints,
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
    // TODO(0.5.0)(validation): Provide a helper that re-validates lap
    // boundaries after compound edits so downstream code can detect mismatches
    // early.
    final croppedPoints = _activity.points
        .where(
          (point) =>
              !point.time.isBefore(startUtc) && !point.time.isAfter(endUtc),
        )
        .toList();
    final croppedChannels = _activity.channels.map((channel, samples) {
      final filtered = samples
          .where(
            (sample) =>
                !sample.time.isBefore(startUtc) && !sample.time.isAfter(endUtc),
          )
          .toList();
      return MapEntry(channel, filtered);
    });
    final croppedLaps = _activity.laps
        .where((lap) {
          return !lap.endTime.isBefore(startUtc) &&
              !lap.startTime.isAfter(endUtc);
        })
        .map((lap) {
          final lapStart = lap.startTime.isBefore(startUtc)
              ? startUtc
              : lap.startTime;
          final lapEnd = lap.endTime.isAfter(endUtc) ? endUtc : lap.endTime;
          return lap.copyWith(startTime: lapStart, endTime: lapEnd);
        })
        .toList();
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
        .map((point) => point.copyWith(time: point.time.add(delta)))
        .toList();
    final shiftedChannels = _activity.channels.map((channel, samples) {
      final shifted = samples
          .map((sample) => sample.copyWith(time: sample.time.add(delta)))
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
    if (_activity.points.length <= 1) {
      return this;
    }
    final retained = <GeoPoint>[];
    for (final point in _activity.points) {
      if (retained.isEmpty ||
          point.time.difference(retained.last.time) >= step) {
        retained.add(point);
      }
    }
    final lastPoint = _activity.points.last;
    if (retained.isEmpty ||
        !retained.last.time.isAtSameMomentAs(lastPoint.time)) {
      retained.add(lastPoint);
    }
    final retainedTimes = retained
        .map((point) => point.time.toUtc().microsecondsSinceEpoch)
        .toList(growable: false);
    final tolerance = math.max(1, step.inMicroseconds ~/ 2);

    final filteredChannels = _activity.channels.map((channel, samples) {
      if (samples.isEmpty) {
        return MapEntry(channel, samples);
      }
      var cursor = 0;

      int closestIndex(int target) {
        while (cursor < retainedTimes.length &&
            retainedTimes[cursor] < target) {
          cursor++;
        }
        if (cursor >= retainedTimes.length) {
          cursor = retainedTimes.length - 1;
        }
        if (cursor == 0) {
          return cursor;
        }
        final lower = retainedTimes[cursor - 1];
        final upper = retainedTimes[cursor];
        return (target - lower).abs() <= (upper - target).abs()
            ? cursor - 1
            : cursor;
      }

      final filtered = <Sample>[];
      for (final sample in samples) {
        final sampleMicros = sample.time.toUtc().microsecondsSinceEpoch;
        final index = closestIndex(sampleMicros);
        final delta = (retainedTimes[index] - sampleMicros).abs();
        if (delta <= tolerance) {
          filtered.add(sample);
        }
      }
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
    final lastPoint = _activity.points.last;
    if (!identical(retained.last, lastPoint)) {
      retained.add(lastPoint);
    }
    final retainedTimes = retained
        .map((point) => point.time)
        .toList(growable: false);
    final channelTolerance = _channelSnapTolerance(retained);
    final filteredChannels = _activity.channels.map((channel, samples) {
      if (samples.isEmpty) {
        return MapEntry(channel, samples);
      }
      final resampled = _resampleNearest(
        samples,
        retainedTimes,
        channelTolerance,
      );
      return MapEntry(channel, resampled);
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
    final leftWindow = (window - 1) ~/ 2;
    final rightWindow = window - leftWindow - 1;
    final prefix = List<double>.filled(hrSamples.length + 1, 0);
    for (var i = 0; i < hrSamples.length; i++) {
      prefix[i + 1] = prefix[i] + hrSamples[i].value;
    }
    final smoothed = <Sample>[];
    for (var i = 0; i < hrSamples.length; i++) {
      final start = math.max(0, i - leftWindow);
      final end = math.min(hrSamples.length - 1, i + rightWindow);
      final total = prefix[end + 1] - prefix[start];
      final count = (end - start) + 1;
      final averaged = total / count;
      smoothed.add(hrSamples[i].copyWith(value: averaged));
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
    if (!_isStrictlyIncreasing(_activity.points, (point) => point.time)) {
      _activity = RawEditor(_activity).sortAndDedup()._activity;
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
    // TODO(0.7.0)(feature): Support time- or elevation-based lap generation so
    // consumers can ask for split summaries beyond fixed distance segments.
    if (meters <= 0) {
      throw ArgumentError.value(meters, 'meters', 'must be positive');
    }
    final distanceSamples = _activity.channel(Channel.distance);
    if (distanceSamples.isEmpty) {
      return this;
    }
    final laps = <Lap>[];
    final firstSample = distanceSamples.first;
    DateTime? lapStart = firstSample.time;
    var normalizedDistance = firstSample.value;
    var lapStartDistance = normalizedDistance;
    var nextSplit = lapStartDistance + meters;
    var previousRaw = firstSample.value;
    for (var i = 0; i < distanceSamples.length; i++) {
      final sample = distanceSamples[i];
      if (i == 0) {
        normalizedDistance = sample.value;
      } else {
        final rawValue = sample.value;
        final delta = rawValue - previousRaw;
        if (delta >= 0) {
          normalizedDistance += delta;
        }
        previousRaw = rawValue;
      }
      while (normalizedDistance >= nextSplit) {
        final lapDistance = nextSplit - lapStartDistance;
        laps.add(
          Lap(
            startTime: lapStart ?? sample.time,
            endTime: sample.time,
            distanceMeters: lapDistance > 0 ? lapDistance : null,
            name: 'Split ${laps.length + 1}',
          ),
        );
        lapStart = sample.time;
        lapStartDistance = nextSplit;
        nextSplit += meters;
      }
    }
    final lastSample = distanceSamples.last;
    final remainingDistance = normalizedDistance - lapStartDistance;
    if (remainingDistance > 0 && lapStart != null) {
      laps.add(
        Lap(
          startTime: lapStart,
          endTime: lastSample.time,
          distanceMeters: remainingDistance,
          name: 'Split ${laps.length + 1}',
        ),
      );
    }
    if (laps.isEmpty && _activity.points.isNotEmpty) {
      laps.add(
        Lap(
          startTime: _activity.points.first.time,
          endTime: _activity.points.last.time,
          distanceMeters:
              distanceSamples.last.value - distanceSamples.first.value,
          name: 'Split 1',
        ),
      );
    }
    _activity = _activity.copyWith(laps: laps);
    return this;
  }
}

bool _isSortedBy<T>(List<T> items, DateTime Function(T item) timeOf) {
  for (var i = 1; i < items.length; i++) {
    final previousTime = timeOf(items[i - 1]);
    final currentTime = timeOf(items[i]);
    if (currentTime.isBefore(previousTime)) {
      return false;
    }
  }
  return true;
}

bool _isSortedByTime(List<GeoPoint> points) =>
    _isSortedBy(points, (point) => point.time);

bool _isSortedSamples(List<Sample> samples) =>
    _isSortedBy(samples, (sample) => sample.time);

bool _isSortedByStart(List<Lap> laps) =>
    _isSortedBy(laps, (lap) => lap.startTime);

bool _isStrictlyIncreasing<T>(
  List<T> items,
  DateTime Function(T item) timeOf,
) {
  for (var i = 1; i < items.length; i++) {
    final previous = timeOf(items[i - 1]).toUtc();
    final current = timeOf(items[i]).toUtc();
    if (!current.isAfter(previous)) {
      return false;
    }
  }
  return true;
}
