part of '../transforms.dart';

/// Provides chained, immutable transformations over [RawActivity].
class RawEditor {
  RawEditor(RawActivity activity) : _activity = activity;
  RawActivity _activity;

  final List<ValidationDiagnostic> _repairDiagnostics = [];

  /// Diagnostics emitted by repair operations (e.g. [trimInvalid]).
  ///
  /// Each entry describes a specific data-quality issue that was automatically
  /// corrected. Use these to surface repair summaries to end users or logs.
  List<ValidationDiagnostic> get repairDiagnostics =>
      List.unmodifiable(_repairDiagnostics);

  /// Returns the current result.
  RawActivity get activity => _activity;

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
      channels: sortedChannels, // Already a Map, no need to copy again
      laps: sortedLaps,
    );
    return this;
  }

  /// Drops invalid coordinates and trims channels outside the point range.
  ///
  /// In addition to geometrically out-of-range coordinates, this also handles
  /// well-known device sentinel values:
  ///
  /// - Points where both latitude and longitude are within 1e-6° of zero
  ///   (the Null Island sentinel emitted before GPS acquires a fix) are
  ///   removed.
  /// - Elevation values ≤ −499 m (the common "no elevation" sentinel, e.g.
  ///   −500 written by Garmin firmware) are cleared to null; the point itself
  ///   is kept because its coordinates are valid.
  ///
  /// Repair diagnostics for both repairs are appended to [repairDiagnostics].
  RawEditor trimInvalid() {
    var allValid = true;
    var sentinelCoordCount = 0;
    var sentinelElevationCount = 0;
    final validPoints = <GeoPoint>[];
    for (final point in _activity.points) {
      final latOk =
          point.latitude.isFinite &&
          point.latitude >= -90 &&
          point.latitude <= 90;
      final lonOk =
          point.longitude.isFinite &&
          point.longitude >= -180 &&
          point.longitude <= 180;
      if (!latOk || !lonOk) {
        allValid = false;
        continue;
      }
      // Null Island sentinel: device has no GPS fix yet
      if (point.latitude.abs() < 1e-6 && point.longitude.abs() < 1e-6) {
        allValid = false;
        sentinelCoordCount++;
        continue;
      }
      // Sentinel elevation: device reports "no elevation data". Keep the
      // point (its coordinates are valid) but clear the bogus elevation.
      if (point.elevation != null && point.elevation! <= -499.0) {
        allValid = false;
        sentinelElevationCount++;
        validPoints.add(
          GeoPoint(
            latitude: point.latitude,
            longitude: point.longitude,
            time: point.time,
          ),
        );
        continue;
      }
      validPoints.add(point);
    }
    if (sentinelCoordCount > 0) {
      _repairDiagnostics.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: '${DiagnosticCategory.repaired}.sentinel_coords_removed',
          message:
              'Removed $sentinelCoordCount point(s) with near-zero '
              'coordinates (GPS not yet acquired).',
          suggestedFix: 'No action needed; invalid points were discarded.',
          priority: 5,
        ),
      );
    }
    if (sentinelElevationCount > 0) {
      _repairDiagnostics.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: '${DiagnosticCategory.repaired}.sentinel_elevation_cleared',
          message:
              'Cleared sentinel elevation (≤ −499 m) on '
              '$sentinelElevationCount point(s); GPS coordinates were kept.',
          suggestedFix:
              'No action needed; the affected points now have no elevation.',
          priority: 3,
        ),
      );
    }
    final retainedPoints = allValid
        ? _activity
              .points // No invalid points, no copy needed
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
      channels: trimmedChannels,
      laps: trimmedLaps,
    );
    return this;
  }

  /// Crops the activity to the inclusive [start] and [end] times.
  ///
  /// Note: After cropping, use [validateLapBoundaries] to detect lap timing
  /// mismatches if the activity contains laps.
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
      channels: croppedChannels,
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
    final shiftedSets = _activity.sets
        .map(
          (s) => s.copyWith(
            startTime: s.startTime.add(delta),
            endTime: s.endTime.add(delta),
          ),
        )
        .toList();
    final shiftedEvents = _activity.events
        .map((e) => e.copyWith(time: e.time.add(delta)))
        .toList();
    final shiftedLengths = _activity.lengths
        .map(
          (l) => l.copyWith(
            startTime: l.startTime.add(delta),
            endTime: l.endTime.add(delta),
          ),
        )
        .toList();
    _activity = _activity.copyWith(
      points: shiftedPoints,
      channels: shiftedChannels,
      laps: shiftedLaps,
      sets: shiftedSets,
      events: shiftedEvents,
      lengths: shiftedLengths,
    );
    return this;
  }

  /// Inserts [point] into the points list maintaining chronological order.
  ///
  /// The point's time is normalised to UTC. No channel or lap changes are made.
  /// Does NOT call [sortAndDedup] so callers can detect ordering bugs.
  RawEditor insertPoint(GeoPoint point) {
    // GeoPoint's constructor already normalized point.time to UTC.
    final points = List<GeoPoint>.from(_activity.points);
    final insertIndex = points.indexWhere((p) => p.time.isAfter(point.time));
    points.insert(insertIndex == -1 ? points.length : insertIndex, point);
    _activity = _activity.copyWith(points: points);
    return this;
  }

  /// Removes the point at [index].
  ///
  /// Throws [RangeError] if [index] is out of bounds.
  /// No channel or lap changes are made.
  RawEditor deletePointAt(int index) {
    RangeError.checkValidIndex(index, _activity.points, 'index');
    final points = List<GeoPoint>.from(_activity.points)..removeAt(index);
    _activity = _activity.copyWith(points: points);
    return this;
  }

  /// Updates a single point in place at [index].
  ///
  /// Throws [RangeError] if [index] is out of bounds.
  /// If [time] is provided the points list is re-sorted by time after update.
  /// No channel changes are made.
  RawEditor updatePoint(
    int index, {
    double? latitude,
    double? longitude,
    double? elevation,
    DateTime? time,
  }) {
    RangeError.checkValidIndex(index, _activity.points, 'index');
    final points = List<GeoPoint>.from(_activity.points);
    points[index] = points[index].copyWith(
      latitude: latitude,
      longitude: longitude,
      elevation: elevation,
      time: time,
    );
    if (time != null) {
      points.sort((a, b) => a.time.compareTo(b.time));
    }
    _activity = _activity.copyWith(points: points);
    return this;
  }

  /// Rewrites every point and channel-sample timestamp with [transform].
  ///
  /// Returning the timestamp unchanged keeps the original element (no copy);
  /// returning a new timestamp rewrites it; returning `null` drops it.
  ({List<GeoPoint> points, Map<Channel, List<Sample>> channels})
  _remapTimestamps(DateTime? Function(DateTime time) transform) => (
    points: [
      for (final p in _activity.points)
        if (transform(p.time) case final time?)
          identical(time, p.time) ? p : p.copyWith(time: time),
    ],
    channels: _activity.channels.map(
      (channel, samples) => MapEntry(channel, [
        for (final s in samples)
          if (transform(s.time) case final time?)
            identical(time, s.time) ? s : s.copyWith(time: time),
      ]),
    ),
  );

  /// Removes GPS points and channel samples where [from] <= t <= [to]
  /// (inclusive) and adjusts lap and set boundaries accordingly.
  ///
  /// Throws [ArgumentError] if [to] is before [from].
  RawEditor deleteRange(DateTime from, DateTime to) {
    if (to.isBefore(from)) {
      throw ArgumentError.value(to, 'to', 'must not be before from');
    }
    final fromUtc = from.toUtc();
    final toUtc = to.toUtc();

    final (
      points: filteredPoints,
      channels: filteredChannels,
    ) = _remapTimestamps(
      (t) => t.isBefore(fromUtc) || t.isAfter(toUtc) ? t : null,
    );

    final adjustedLaps = _clipRangesForDelete(
      _activity.laps,
      fromUtc,
      toUtc,
      startOf: (lap) => lap.startTime,
      endOf: (lap) => lap.endTime,
      rebuild: _rebuildLap,
    );
    final adjustedSets = _clipRangesForDelete(
      _activity.sets,
      fromUtc,
      toUtc,
      startOf: (s) => s.startTime,
      endOf: (s) => s.endTime,
      rebuild: _rebuildSet,
    );

    _activity = _activity.copyWith(
      points: filteredPoints,
      channels: filteredChannels,
      laps: adjustedLaps,
      sets: adjustedSets,
    );
    return this;
  }

  /// Shifts all timestamps strictly after [at] forward by [duration],
  /// inserting a pause at that point in time.
  ///
  /// Laps that straddle [at] have only their endTime extended.
  /// Throws [ArgumentError] if [duration] is negative.
  RawEditor insertPause(DateTime at, Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    if (duration == Duration.zero) {
      return this;
    }
    final atUtc = at.toUtc();

    final (points: shiftedPoints, channels: shiftedChannels) = _remapTimestamps(
      (t) => t.isAfter(atUtc) ? t.add(duration) : t,
    );

    final adjustedLaps = _shiftRangesAfter(
      _activity.laps,
      atUtc,
      duration,
      startOf: (lap) => lap.startTime,
      endOf: (lap) => lap.endTime,
      rebuild: _rebuildLap,
    );
    final adjustedSets = _shiftRangesAfter(
      _activity.sets,
      atUtc,
      duration,
      startOf: (s) => s.startTime,
      endOf: (s) => s.endTime,
      rebuild: _rebuildSet,
    );

    _activity = _activity.copyWith(
      points: shiftedPoints,
      channels: shiftedChannels,
      laps: adjustedLaps,
      sets: adjustedSets,
    );
    return this;
  }

  /// Closes a time gap by removing points/samples strictly inside (from, to)
  /// (exclusive both boundaries) and shifting everything >= to back by
  /// gap = to.difference(from).
  ///
  /// Throws [ArgumentError] if [to] is before [from].
  RawEditor removePause(DateTime from, DateTime to) {
    if (to.isBefore(from)) {
      throw ArgumentError.value(to, 'to', 'must not be before from');
    }
    final fromUtc = from.toUtc();
    final toUtc = to.toUtc();
    final gap = toUtc.difference(fromUtc);
    if (gap == Duration.zero) {
      return this;
    }

    final (
      points: adjustedPoints,
      channels: adjustedChannels,
    ) = _remapTimestamps((t) {
      if (t.isAfter(fromUtc) && t.isBefore(toUtc)) {
        return null; // remove strictly inside gap
      }
      return t.isBefore(toUtc) ? t : t.subtract(gap);
    });

    final adjustedLaps = _closeGapInRanges(
      _activity.laps,
      fromUtc,
      toUtc,
      gap,
      startOf: (lap) => lap.startTime,
      endOf: (lap) => lap.endTime,
      rebuild: _rebuildLap,
    );
    final adjustedSets = _closeGapInRanges(
      _activity.sets,
      fromUtc,
      toUtc,
      gap,
      startOf: (s) => s.startTime,
      endOf: (s) => s.endTime,
      rebuild: _rebuildSet,
    );

    _activity = _activity.copyWith(
      points: adjustedPoints,
      channels: adjustedChannels,
      laps: adjustedLaps,
      sets: adjustedSets,
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
      channels: filteredChannels,
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
      final distance = haversineMeters(lastKept, point);
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
      channels: filteredChannels,
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
    _activity = _activity.copyWith(
      channels: {..._activity.channels, Channel.heartRate: smoothed},
    );
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
      final deltaDistance = haversineMeters(previous, point);
      total += deltaDistance;
      final deltaTime =
          point.time.difference(previous.time).inMicroseconds / 1e6;
      final currentSpeed = deltaTime > 0 ? deltaDistance / deltaTime : 0.0;
      cumulative.add(Sample(time: point.time, value: total));
      speed.add(Sample(time: point.time, value: currentSpeed));
    }
    _activity = _activity.copyWith(
      channels: {
        ..._activity.channels,
        Channel.distance: cumulative,
        Channel.speed: speed,
      },
    );
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

  /// Validates that lap boundaries align with the current activity timeframe.
  ///
  /// This helper is useful after compound edits (crop, trim, downsample, etc.)
  /// to detect lap boundary mismatches early. Returns a [LapValidationResult]
  /// with any detected issues.
  ///
  /// Checks performed:
  /// - Lap start/end times are in chronological order
  /// - Laps don't overlap
  /// - Lap boundaries fall within the activity's point timeframe
  /// - Each lap's end time is after its start time
  LapValidationResult validateLapBoundaries() {
    if (_activity.points.isEmpty) {
      return validateLapBoundariesList(_activity.laps, warnWhenNoPoints: true);
    }

    return validateLapBoundariesList(
      _activity.laps,
      pointsStart: _activity.points.first.time,
      pointsEnd: _activity.points.last.time,
    );
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

bool _isStrictlyIncreasing<T>(List<T> items, DateTime Function(T item) timeOf) {
  for (var i = 1; i < items.length; i++) {
    final previous = timeOf(items[i - 1]).toUtc();
    final current = timeOf(items[i]).toUtc();
    if (!current.isAfter(previous)) {
      return false;
    }
  }
  return true;
}

/// Rebuilds a time-range item with new boundaries; `null` keeps the original.
typedef _RangeRebuild<T> = T Function(T item, {DateTime? start, DateTime? end});

Lap _rebuildLap(Lap lap, {DateTime? start, DateTime? end}) =>
    lap.copyWith(startTime: start, endTime: end);

WorkoutSet _rebuildSet(WorkoutSet s, {DateTime? start, DateTime? end}) =>
    s.copyWith(startTime: start, endTime: end);

/// Applies the [RawEditor.deleteRange] clipping rules to laps or sets:
/// ranges fully inside `[fromUtc, toUtc]` are dropped, ranges straddling one
/// boundary are clipped, and ranges spanning the whole window keep their
/// original bounds — deleteRange leaves the timeline gap in place, so such a
/// range still covers the surviving points after [toUtc]; clipping it would
/// orphan them.
List<T> _clipRangesForDelete<T>(
  List<T> items,
  DateTime fromUtc,
  DateTime toUtc, {
  required DateTime Function(T) startOf,
  required DateTime Function(T) endOf,
  required _RangeRebuild<T> rebuild,
}) {
  final result = <T>[];
  for (final item in items) {
    final start = startOf(item);
    final end = endOf(item);
    if (!end.isAfter(fromUtc) || !start.isBefore(toUtc)) {
      // Fully before or after the deleted range: keep.
      result.add(item);
    } else if (!start.isBefore(fromUtc) && !end.isAfter(toUtc)) {
      // Fully inside: remove.
    } else if (start.isBefore(fromUtc) && !end.isAfter(toUtc)) {
      // Straddles start only: clip end.
      result.add(rebuild(item, end: fromUtc));
    } else if (!start.isBefore(fromUtc) && end.isAfter(toUtc)) {
      // Straddles end only: clip start.
      result.add(rebuild(item, start: toUtc));
    } else {
      // Straddles the whole range: keep original bounds.
      result.add(item);
    }
  }
  return result;
}

/// Applies the [RawEditor.removePause] gap-closing rules to laps or sets:
/// ranges inside the gap are dropped, boundary-straddling ranges are clipped,
/// and later ranges shift back by [gap]. Clipping can collapse a range to zero
/// duration (which would fail boundary validation), so such results are
/// discarded.
List<T> _closeGapInRanges<T>(
  List<T> items,
  DateTime fromUtc,
  DateTime toUtc,
  Duration gap, {
  required DateTime Function(T) startOf,
  required DateTime Function(T) endOf,
  required _RangeRebuild<T> rebuild,
}) {
  final result = <T>[];
  void addIfPositive(T item) {
    if (endOf(item).isAfter(startOf(item))) {
      result.add(item);
    }
  }

  for (final item in items) {
    final start = startOf(item);
    final end = endOf(item);
    if (!end.isAfter(fromUtc)) {
      // Fully before or at the gap: keep.
      result.add(item);
    } else if (!start.isBefore(toUtc)) {
      // Fully after: shift both boundaries back.
      result.add(
        rebuild(item, start: start.subtract(gap), end: end.subtract(gap)),
      );
    } else if (start.isAfter(fromUtc) && end.isBefore(toUtc)) {
      // Fully within the gap: remove.
    } else if (!start.isAfter(fromUtc) &&
        end.isAfter(fromUtc) &&
        end.isBefore(toUtc)) {
      // Straddles gap start: clip end.
      addIfPositive(rebuild(item, end: fromUtc));
    } else if (start.isAfter(fromUtc) &&
        start.isBefore(toUtc) &&
        !end.isBefore(toUtc)) {
      // Straddles gap end: snap start to gap start, shift end back.
      addIfPositive(rebuild(item, start: fromUtc, end: end.subtract(gap)));
    } else {
      // Straddles the whole gap: close the gap within the range.
      addIfPositive(rebuild(item, end: end.subtract(gap)));
    }
  }
  return result;
}

/// Applies the [RawEditor.insertPause] shift to laps or sets: ranges starting
/// strictly after [atUtc] shift entirely; ranges straddling [atUtc] have only
/// their end extended.
List<T> _shiftRangesAfter<T>(
  List<T> items,
  DateTime atUtc,
  Duration duration, {
  required DateTime Function(T) startOf,
  required DateTime Function(T) endOf,
  required _RangeRebuild<T> rebuild,
}) => [
  for (final item in items)
    if (startOf(item).isAfter(atUtc))
      rebuild(
        item,
        start: startOf(item).add(duration),
        end: endOf(item).add(duration),
      )
    else if (endOf(item).isAfter(atUtc))
      rebuild(item, end: endOf(item).add(duration))
    else
      item,
];
