// SPDX-License-Identifier: BSD-3-Clause
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
        : _stableSortByTime(_activity.points, (p) => p.time);
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
          : _stableSortByTime(samples, (s) => s.time);
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
        : _stableSortByTime(_activity.laps, (lap) => lap.startTime);
    _activity = _activity.copyWith(
      points: dedupedPoints,
      channels: sortedChannels, // Already a Map, no need to copy again
      laps: sortedLaps,
    );
    return this;
  }

  /// Like [sortAndDedup], but nudges duplicate timestamps forward by 1
  /// microsecond instead of dropping entries. Reports adjustments via
  /// [repairDiagnostics].
  RawEditor ensureStrictTimeOrder() {
    final sortedPoints = _isSortedByTime(_activity.points)
        ? _activity.points
        : _stableSortByTime(_activity.points, (p) => p.time);
    final pointResult = _pushTimestampsForward(
      sortedPoints,
      timeOf: (p) => p.time,
      withTime: (p, t) => p.copyWith(time: t),
    );
    var adjustedSamples = 0;
    final sortedChannels = _activity.channels.map((channel, samples) {
      final result = _pushTimestampsForward(
        _isSortedSamples(samples)
            ? samples
            : _stableSortByTime(samples, (s) => s.time),
        timeOf: (s) => s.time,
        withTime: (s, t) => s.copyWith(time: t),
      );
      adjustedSamples += result.adjustedCount;
      return MapEntry(channel, result.items);
    });
    final sortedLaps = _isSortedByStart(_activity.laps)
        ? _activity.laps
        : _stableSortByTime(_activity.laps, (lap) => lap.startTime);
    final lapResult = _pushTimestampsForward(
      sortedLaps,
      timeOf: (lap) => lap.startTime,
      withTime: (lap, t) => lap.copyWith(startTime: t),
    );
    // Only rescan points-per-lap when a point actually moved: with nothing
    // nudged, no point could have crossed a lap's original end boundary.
    final expandedLaps = pointResult.adjustedCount == 0
        ? lapResult.items
        : _expandLapEndsForNudgedPoints(
            lapResult.items,
            sortedLaps,
            sortedPoints,
            pointResult.items,
          );
    // The nudge above only ever moves startTime forward; a near-zero-duration
    // lap tied with the next lap's startTime can end up nudged past its own
    // unmodified endTime. Clamp to a zero-length lap instead of writing a
    // negative duration into the encoded output, matching the FIT parser's
    // `fit.lap.negative_duration_clamped` guard -- by moving endTime forward
    // to the (already nudged) startTime, not startTime backward to endTime:
    // pulling startTime back would reintroduce the very duplicate this pass
    // just nudged it away from, undoing the nudge and breaking the strictly-
    // increasing-times guarantee this method exists to provide.
    var clampedLapCount = 0;
    final clampedLaps = <Lap>[];
    for (final lap in expandedLaps) {
      if (lap.startTime.isAfter(lap.endTime)) {
        clampedLapCount++;
        clampedLaps.add(lap.copyWith(endTime: lap.startTime));
      } else {
        clampedLaps.add(lap);
      }
    }
    _activity = _activity.copyWith(
      points: pointResult.items,
      channels: sortedChannels,
      laps: clampedLaps,
    );
    final adjustedTotal =
        pointResult.adjustedCount + adjustedSamples + lapResult.adjustedCount;
    if (adjustedTotal > 0) {
      _repairDiagnostics.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: '${DiagnosticCategory.repaired}.duplicate_timestamps_adjusted',
          message:
              'Adjusted $adjustedTotal timestamp(s) by up to a few '
              'microseconds so the encoded output has strictly increasing '
              'times; no points, samples, or laps were dropped.',
          suggestedFix: 'No action needed; every original entry was kept.',
          priority: 5,
        ),
      );
    }
    if (clampedLapCount > 0) {
      _repairDiagnostics.add(
        ValidationDiagnostic(
          severity: ValidationSeverity.warning,
          code: '${DiagnosticCategory.repaired}.lap_negative_duration_clamped',
          message:
              '$clampedLapCount lap(s) had a startTime nudge push past '
              'their own endTime; clamped to a zero-length lap.',
          suggestedFix: 'No action needed; the lap was kept, zero-length.',
          priority: 5,
        ),
      );
    }
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
        validPoints.add(point.copyWithoutElevation());
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
    final List<Lap> trimmedLaps;
    if (start == null || end == null) {
      // Preserve sensor-only activities (indoor/trainer sessions) by
      // keeping laps unchanged, same as the channels branch above.
      trimmedLaps = List<Lap>.from(_activity.laps);
    } else {
      final startUtc = start;
      final endUtc = end;
      trimmedLaps = _activity.laps
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
          })
          .toList();
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
    final croppedLaps = _clipRangesForCrop(
      _activity.laps,
      startUtc,
      endUtc,
      startOf: (lap) => lap.startTime,
      endOf: (lap) => lap.endTime,
      rebuild: _rebuildLap,
    );
    final croppedSets = _clipRangesForCrop(
      _activity.sets,
      startUtc,
      endUtc,
      startOf: (s) => s.startTime,
      endOf: (s) => s.endTime,
      rebuild: _rebuildSet,
    );
    final croppedLengths = _clipRangesForCrop(
      _activity.lengths,
      startUtc,
      endUtc,
      startOf: (l) => l.startTime,
      endOf: (l) => l.endTime,
      rebuild: _rebuildLength,
    );
    final croppedEvents = _activity.events
        .where((e) => !e.time.isBefore(startUtc) && !e.time.isAfter(endUtc))
        .toList();
    _activity = _activity.copyWith(
      points: croppedPoints,
      channels: croppedChannels,
      laps: croppedLaps,
      sets: croppedSets,
      events: croppedEvents,
      lengths: croppedLengths,
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
    // Only pay for a sort when the update actually broke ordering (e.g. the
    // new time still falls between the same neighbors) -- every other sort
    // site in this file guards the same way instead of always re-sorting.
    if (time != null && !_isSortedByTime(points)) {
      mergeSort(points, compare: (a, b) => a.time.compareTo(b.time));
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
  /// (inclusive), adjusts lap/set/length boundaries accordingly, and drops
  /// any event falling in that window.
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
    final adjustedLengths = _clipRangesForDelete(
      _activity.lengths,
      fromUtc,
      toUtc,
      startOf: (l) => l.startTime,
      endOf: (l) => l.endTime,
      rebuild: _rebuildLength,
    );
    // Events are instants, not ranges, so unlike laps/sets/lengths there's
    // nothing to clip: one inside the deleted window is simply dropped.
    final adjustedEvents = [
      for (final e in _activity.events)
        if (e.time.isBefore(fromUtc) || e.time.isAfter(toUtc)) e,
    ];

    _activity = _activity.copyWith(
      points: filteredPoints,
      channels: filteredChannels,
      laps: adjustedLaps,
      sets: adjustedSets,
      events: adjustedEvents,
      lengths: adjustedLengths,
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
    final adjustedLengths = _shiftRangesAfter(
      _activity.lengths,
      atUtc,
      duration,
      startOf: (l) => l.startTime,
      endOf: (l) => l.endTime,
      rebuild: _rebuildLength,
    );
    final adjustedEvents = [
      for (final e in _activity.events)
        e.time.isAfter(atUtc) ? e.copyWith(time: e.time.add(duration)) : e,
    ];

    _activity = _activity.copyWith(
      points: shiftedPoints,
      channels: shiftedChannels,
      laps: adjustedLaps,
      sets: adjustedSets,
      events: adjustedEvents,
      lengths: adjustedLengths,
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
    final adjustedLengths = _closeGapInRanges(
      _activity.lengths,
      fromUtc,
      toUtc,
      gap,
      startOf: (l) => l.startTime,
      endOf: (l) => l.endTime,
      rebuild: _rebuildLength,
    );
    final adjustedEvents = [
      for (final e in _activity.events)
        if (!(e.time.isAfter(fromUtc) && e.time.isBefore(toUtc)))
          e.time.isBefore(toUtc) ? e : e.copyWith(time: e.time.subtract(gap)),
    ];

    _activity = _activity.copyWith(
      points: adjustedPoints,
      channels: adjustedChannels,
      laps: adjustedLaps,
      sets: adjustedSets,
      events: adjustedEvents,
      lengths: adjustedLengths,
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

  /// Applies the auto-fix pipeline described by [options]: sort/dedup, trim
  /// invalid points, recompute distance/speed, fill timestamp gaps, and
  /// (optionally) generate laps by distance. See [ActivityAutoFixOptions] for
  /// what each flag controls.
  RawEditor autoFix(ActivityAutoFixOptions options) {
    sortAndDedup();
    if (options.fixInvalidGps || options.fixChannelDrift) {
      trimInvalid();
    }
    if (options.fixDistanceDrift) {
      recomputeDistanceAndSpeed();
    }
    if (options.fixTimestampGaps && options.maxInsertedGapPoints > 0) {
      _fillTimestampGaps(
        options.gapThreshold,
        maxInsertedPoints: options.maxInsertedGapPoints,
      );
    }
    if (options.autoLapByDistance) {
      // Generate auto-laps if:
      // 1. autoLapOnlyWhenMissing is false (always generate), OR
      // 2. autoLapOnlyWhenMissing is true AND laps are missing/placeholder
      final hasPlaceholderLaps =
          _activity.laps.isNotEmpty &&
          _activity.laps.every(
            (lap) =>
                (lap.name?.startsWith('Segment') ?? false) ||
                (lap.name?.startsWith('Split') ?? false),
          );
      final shouldGenerateLaps =
          !options.autoLapOnlyWhenMissing ||
          _activity.laps.isEmpty ||
          hasPlaceholderLaps;
      if (shouldGenerateLaps && _activity.points.length >= 2) {
        // Always recompute distance for auto-lap to ensure accuracy
        // (distance may be lost during format conversions like GPX->TCX
        // roundtrip).
        recomputeDistanceAndSpeed();
        final splitMeters = _autoLapDistanceForSport(_activity.sport, options);
        if (splitMeters > 0) {
          markLapsByDistance(splitMeters);
        }
      }
    }
    return this;
  }

  // Fills large timestamp gaps by linearly interpolating position and
  // elevation. Channel samples (HR, power, cadence, etc.) are intentionally
  // not interpolated; inserted points carry no sensor data and will appear
  // as gaps in channel coverage.
  void _fillTimestampGaps(
    Duration threshold, {
    required int maxInsertedPoints,
  }) {
    if (_activity.points.length < 2 || threshold <= Duration.zero) {
      return;
    }
    final output = <GeoPoint>[];
    var inserted = 0;
    for (var i = 0; i < _activity.points.length - 1; i++) {
      final current = _activity.points[i];
      final next = _activity.points[i + 1];
      output.add(current);
      final gap = next.time.difference(current.time);
      if (gap <= threshold || inserted >= maxInsertedPoints) {
        continue;
      }
      final thresholdMicros = threshold.inMicroseconds;
      if (thresholdMicros <= 0) {
        continue;
      }
      final steps = gap.inMicroseconds ~/ thresholdMicros;
      if (steps <= 1) {
        continue;
      }
      for (var j = 1; j < steps; j++) {
        if (inserted >= maxInsertedPoints) {
          break;
        }
        final ratio = j / steps;
        final time = current.time.add(
          Duration(microseconds: (gap.inMicroseconds * ratio).round()),
        );
        final elevation = current.elevation != null && next.elevation != null
            ? current.elevation! +
                  (next.elevation! - current.elevation!) * ratio
            : null;
        output.add(
          GeoPoint(
            latitude:
                current.latitude + (next.latitude - current.latitude) * ratio,
            longitude:
                current.longitude +
                (next.longitude - current.longitude) * ratio,
            elevation: elevation,
            time: time,
          ),
        );
        inserted++;
      }
    }
    output.add(_activity.points.last);
    if (output.length == _activity.points.length) {
      return;
    }
    _activity = _activity.copyWith(points: output);
  }

  static double _autoLapDistanceForSport(
    Sport sport,
    ActivityAutoFixOptions options,
  ) {
    final override = options.autoLapDistanceMeters;
    if (override != null && override > 0) {
      return override;
    }
    switch (sport) {
      case Sport.running:
      case Sport.walking:
      case Sport.hiking:
        return options.runningLapDistanceMeters;
      case Sport.cycling:
        return options.cyclingLapDistanceMeters;
      default:
        return options.defaultLapDistanceMeters;
    }
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

  /// Merges multiple activities into a single unified activity.
  ///
  /// Combines GPS points, sensor channels, and laps from all activities.
  /// The resulting activity will have:
  /// - All points merged and sorted by timestamp (when [normalize] is true)
  /// - All sensor channel samples combined
  /// - All laps preserved with their original sport values
  /// - Sport from the first activity as the overall sport
  /// - Optional custom [creator] metadata
  ///
  /// Set [preserveSportPerLap] to true to retain each source activity's sport
  /// on its laps, enabling multi-sport merges (e.g., combining separate swim/
  /// bike/run files into a triathlon). When false, lap sports remain as defined
  /// in the source activities.
  ///
  /// Enable [normalize] (default: true) to automatically sort and deduplicate
  /// the merged data.
  ///
  /// Example:
  /// ```dart
  /// final swim = await ActivityFiles.import(File('swim.gpx'));
  /// final bike = await ActivityFiles.import(File('bike.gpx'));
  /// final run = await ActivityFiles.import(File('run.gpx'));
  ///
  /// final triathlon = RawEditor.merge(
  ///   [swim.activity, bike.activity, run.activity],
  ///   preserveSportPerLap: true,
  ///   creator: 'my_triathlon_app',
  /// );
  /// ```
  static RawActivity merge(
    List<RawActivity> activities, {
    bool preserveSportPerLap = false,
    bool normalize = true,
    String? creator,
  }) {
    if (activities.isEmpty) {
      throw ArgumentError(
        'Cannot merge activities: the input list is empty.\n'
        '\n'
        'You must provide at least one activity to merge:\n'
        '  final merged = RawEditor.merge(activities);\n'
        '\n'
        'To combine multiple activities, ensure the list contains at least one element.\n'
        'To split a multi-sport activity instead, use: RawEditor.splitBySport(activity)',
      );
    }
    if (activities.length == 1) {
      final single = activities.first;
      if (!normalize || _isAlreadyNormalized(single)) {
        return single;
      }
      return RawEditor(single).sortAndDedup().trimInvalid().activity;
    }

    // Flatten multi-track sources so additional-track data is not dropped.
    final sources = [for (final activity in activities) activity.flattened()];
    final mergedChannels = <Channel, List<Sample>>{};
    for (final activity in sources) {
      for (final entry in activity.channels.entries) {
        mergedChannels
            .putIfAbsent(entry.key, () => <Sample>[])
            .addAll(entry.value);
      }
    }

    final merged = RawActivity(
      points: [for (final activity in sources) ...activity.points],
      channels: mergedChannels,
      laps: [
        // Assign the source activity's sport to laps that lack one so the
        // per-lap sport survives multi-sport merges.
        for (final activity in sources)
          for (final lap in activity.laps)
            preserveSportPerLap && lap.sport == null
                ? lap.copyWith(sport: activity.sport)
                : lap,
      ],
      sets: [for (final activity in sources) ...activity.sets],
      events: [for (final activity in sources) ...activity.events],
      lengths: [for (final activity in sources) ...activity.lengths],
      sport: sources.first.sport,
      creator: creator ?? sources.first.creator,
      device: sources.first.device,
    );
    return normalize
        ? (RawEditor(merged).sortAndDedup().trimInvalid().activity)
        : merged;
  }

  /// Splits a multi-sport activity into separate activities by sport type.
  ///
  /// Each returned activity contains only the points, channels, and laps
  /// that fall within the time range of laps with that sport. Useful for
  /// splitting triathlon files into individual swim/bike/run activities.
  ///
  /// Returns a map from [Sport] to [RawActivity]. Laps without an explicit
  /// sport are grouped under the activity's overall sport.
  ///
  /// Enable [normalize] (default: true) to automatically sort and deduplicate
  /// each split activity's data.
  ///
  /// Example:
  /// ```dart
  /// final triathlon = await ActivityFiles.import(File('triathlon.tcx'));
  /// final splits = RawEditor.splitBySport(triathlon.activity);
  ///
  /// // Export each sport separately
  /// for (final entry in splits.entries) {
  ///   final filename = '${entry.key.name}.gpx';
  ///   final export = await ActivityFiles.export(
  ///     activity: entry.value,
  ///     to: ActivityFileFormat.gpx,
  ///   );
  ///   await File(filename).writeAsString(export.asString());
  /// }
  /// ```
  static Map<Sport, RawActivity> splitBySport(
    RawActivity activity, {
    bool normalize = true,
  }) {
    if (activity.laps.isEmpty) {
      // No laps - return entire activity under its overall sport
      return {activity.sport: activity};
    }

    // Group laps by sport
    final lapsBySport = <Sport, List<Lap>>{};
    for (final lap in activity.laps) {
      final sport = lap.sport ?? activity.sport;
      lapsBySport.putIfAbsent(sport, () => []).add(lap);
    }

    if (lapsBySport.length == 1) {
      // Single sport - return as-is
      return {lapsBySport.keys.first: activity};
    }

    // Create separate activities for each sport
    final result = <Sport, RawActivity>{};

    // A lap's end boundary is exclusive only when another lap (any sport)
    // starts exactly there, so a point sitting on that instant is claimed by
    // exactly one lap. Membership is checked per lap (union of that sport's
    // own lap windows) rather than one aggregate min..max range per sport,
    // so a sport whose laps bracket another sport's laps (a brick workout:
    // run/bike/run) doesn't swallow the bracketed sport's window.
    final lapStartTimes = activity.laps.map((lap) => lap.startTime).toSet();
    bool withinLap(DateTime time, Lap lap) {
      final endExclusive = lapStartTimes.contains(lap.endTime);
      return !time.isBefore(lap.startTime) &&
          (endExclusive
              ? time.isBefore(lap.endTime)
              : !time.isAfter(lap.endTime));
    }

    bool withinAnyLap(DateTime time, List<Lap> laps) =>
        laps.any((lap) => withinLap(time, lap));

    for (final entry in lapsBySport.entries) {
      final sport = entry.key;
      final laps = entry.value;
      final otherLaps = [
        for (final other in lapsBySport.entries)
          if (other.key != sport) ...other.value,
      ];
      final sortedLaps = [...laps]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));

      // A gap between two of this sport's own laps (e.g. an undeclared
      // auto-pause between consecutive laps) belongs to this sport too,
      // unless another sport's lap actually claims that time range (the
      // bracketing case's per-lap membership above already handles).
      bool withinOwnGap(DateTime time) {
        for (var i = 0; i < sortedLaps.length - 1; i++) {
          if (time.isAfter(sortedLaps[i].endTime) &&
              time.isBefore(sortedLaps[i + 1].startTime)) {
            return !withinAnyLap(time, otherLaps);
          }
        }
        return false;
      }

      bool belongsToSport(DateTime time) =>
          withinAnyLap(time, laps) || withinOwnGap(time);

      // Filter points to this sport's lap windows
      final sportPoints = activity.points
          .where((p) => belongsToSport(p.time))
          .toList();

      // Filter channels to this sport's lap windows
      final sportChannels = <Channel, List<Sample>>{};
      for (final channelEntry in activity.channels.entries) {
        final samples = channelEntry.value
            .where((s) => belongsToSport(s.time))
            .toList();
        if (samples.isNotEmpty) {
          sportChannels[channelEntry.key] = samples;
        }
      }

      // Strip sport from laps while preserving all lap metadata.
      final normalizedLaps = [for (final lap in laps) lap.copyWithoutSport()];

      var sportActivity = RawActivity(
        points: sportPoints,
        channels: sportChannels,
        laps: normalizedLaps,
        sport: sport,
        creator: activity.creator,
        device: activity.device,
        gpxMetadataName: activity.gpxMetadataName,
        gpxMetadataDescription: activity.gpxMetadataDescription,
        gpxTrackName: activity.gpxTrackName,
        gpxTrackDescription: activity.gpxTrackDescription,
        gpxTrackType: activity.gpxTrackType,
      );

      if (normalize) {
        sportActivity = RawEditor(
          sportActivity,
        ).sortAndDedup().trimInvalid().activity;
      }

      result[sport] = sportActivity;
    }

    return result;
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

bool _isStrictlyOrderedBy<T>(List<T> items, DateTime Function(T item) timeOf) {
  for (var i = 1; i < items.length; i++) {
    if (!timeOf(items[i]).toUtc().isAfter(timeOf(items[i - 1]).toUtc())) {
      return false;
    }
  }
  return true;
}

/// Whether [activity] already satisfies what `sortAndDedup()`/`trimInvalid()`
/// would produce, so a caller (e.g. [RawEditor.merge]'s single-activity
/// case) can skip the chain and keep the identical instance instead of
/// rebuilding an equal one. Mirrors the facade's own `_isAlreadyNormalized`
/// fast path; kept here too since `transforms/` can't depend on `api/`.
bool _isAlreadyNormalized(RawActivity activity) {
  if (!_isStrictlyOrderedBy(activity.points, (p) => p.time) ||
      !activity.channels.values.every(
        (samples) => _isStrictlyOrderedBy(samples, (s) => s.time),
      ) ||
      !_isStrictlyOrderedBy(activity.laps, (l) => l.startTime)) {
    return false;
  }
  final validCoordinates = activity.points.every(
    (p) =>
        p.latitude.isFinite &&
        p.latitude >= -90 &&
        p.latitude <= 90 &&
        p.longitude.isFinite &&
        p.longitude >= -180 &&
        p.longitude <= 180 &&
        !(p.latitude.abs() < 1e-6 && p.longitude.abs() < 1e-6) &&
        (p.elevation == null || p.elevation! > -499.0),
  );
  if (!validCoordinates) return false;
  if (activity.points.isEmpty) return true;
  final start = activity.points.first.time;
  final end = activity.points.last.time;
  final channelsInRange = activity.channels.values.every(
    (samples) =>
        samples.every((s) => !s.time.isBefore(start) && !s.time.isAfter(end)),
  );
  if (!channelsInRange) return false;
  return activity.laps.every(
    (lap) => !lap.startTime.isBefore(start) && !lap.endTime.isAfter(end),
  );
}

/// Sorts a copy of [items] by [timeOf] with a stable sort, so equal
/// timestamps keep their original relative order instead of `List.sort`'s
/// unspecified (and in practice non-stable, above ~32 elements) tie-break.
List<T> _stableSortByTime<T>(List<T> items, DateTime Function(T item) timeOf) {
  final sorted = List<T>.of(items);
  mergeSort(sorted, compare: (a, b) => timeOf(a).compareTo(timeOf(b)));
  return sorted;
}

class _PushForwardResult<T> {
  const _PushForwardResult(this.items, this.adjustedCount);
  final List<T> items;
  final int adjustedCount;
}

/// Extends each lap's endTime to cover any point that fell inside its
/// original `[startTime, endTime]` window but was nudged past it, so
/// consumers that select points by lap time range (e.g. the TCX encoder)
/// don't lose points that only ever moved because of the nudge.
List<Lap> _expandLapEndsForNudgedPoints(
  List<Lap> laps,
  List<Lap> originalLaps,
  List<GeoPoint> originalPoints,
  List<GeoPoint> nudgedPoints,
) => [
  for (var i = 0; i < laps.length; i++)
    _expandLapEnd(laps[i], originalLaps[i], originalPoints, nudgedPoints),
];

Lap _expandLapEnd(
  Lap lap,
  Lap originalLap,
  List<GeoPoint> originalPoints,
  List<GeoPoint> nudgedPoints,
) {
  DateTime? maxNudgedTime;
  for (var j = 0; j < originalPoints.length; j++) {
    final originalTime = originalPoints[j].time;
    if (!originalTime.isBefore(originalLap.startTime) &&
        !originalTime.isAfter(originalLap.endTime)) {
      final nudgedTime = nudgedPoints[j].time;
      if (maxNudgedTime == null || nudgedTime.isAfter(maxNudgedTime)) {
        maxNudgedTime = nudgedTime;
      }
    }
  }
  return maxNudgedTime != null && maxNudgedTime.isAfter(lap.endTime)
      ? lap.copyWith(endTime: maxNudgedTime)
      : lap;
}

/// Nudges timestamps in pre-sorted [items] so each is strictly after the
/// previous one, cascading through any run of equal timestamps.
_PushForwardResult<T> _pushTimestampsForward<T>(
  List<T> items, {
  required DateTime Function(T item) timeOf,
  required T Function(T item, DateTime time) withTime,
}) {
  final result = <T>[];
  DateTime? previous;
  var adjustedCount = 0;
  for (final item in items) {
    var time = timeOf(item).toUtc();
    if (previous != null && !time.isAfter(previous)) {
      time = previous.add(const Duration(microseconds: 1));
      adjustedCount++;
      result.add(withTime(item, time));
    } else {
      result.add(item);
    }
    previous = time;
  }
  return _PushForwardResult(result, adjustedCount);
}

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

SwimLength _rebuildLength(SwimLength l, {DateTime? start, DateTime? end}) =>
    l.copyWith(startTime: start, endTime: end);

/// Applies the [RawEditor.crop] clipping rules to laps, sets, or lengths:
/// ranges entirely outside `[startUtc, endUtc]` are dropped, ranges
/// straddling a boundary are clipped to it, matching the point/channel
/// filter in the same method.
List<T> _clipRangesForCrop<T>(
  List<T> items,
  DateTime startUtc,
  DateTime endUtc, {
  required DateTime Function(T) startOf,
  required DateTime Function(T) endOf,
  required _RangeRebuild<T> rebuild,
}) => [
  for (final item in items)
    if (!endOf(item).isBefore(startUtc) && !startOf(item).isAfter(endUtc))
      rebuild(
        item,
        start: startOf(item).isBefore(startUtc) ? startUtc : startOf(item),
        end: endOf(item).isAfter(endUtc) ? endUtc : endOf(item),
      ),
];

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
