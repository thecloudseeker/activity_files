// SPDX-License-Identifier: BSD-3-Clause
/// Test data builders for creating RawActivity instances.
///
/// Provides fluent builder API and factory methods for common test scenarios.
library;

import 'package:activity_files/activity_files.dart';

/// Builds a standard RawActivity with 3 points and common channels.
///
/// Default configuration:
/// - 3 points at 5-second intervals
/// - Location: 40.0-40.001 lat, -105.0 to -105.001 lon
/// - Elevation: 1600-1602m
/// - Channels: HR (140-145), cadence (80-84), power (200-220), temp (21-23)
/// - Single lap covering all points
/// - Sport: cycling
/// - Creator: 'unit-test device'
///
/// Returns activity with cumulative distance and speed computed.
RawActivity buildSampleActivity() {
  final baseTime = DateTime.utc(2024, 4, 1, 6);
  final points = [
    GeoPoint(
      latitude: 40.0,
      longitude: -105.0,
      elevation: 1600,
      time: baseTime,
    ),
    GeoPoint(
      latitude: 40.0005,
      longitude: -105.0005,
      elevation: 1601,
      time: baseTime.add(const Duration(seconds: 5)),
    ),
    GeoPoint(
      latitude: 40.0010,
      longitude: -105.0010,
      elevation: 1602,
      time: baseTime.add(const Duration(seconds: 10)),
    ),
  ];
  final hr = [
    Sample(time: points[0].time, value: 140),
    Sample(time: points[1].time, value: 142),
    Sample(time: points[2].time, value: 145),
  ];
  final cadence = [
    Sample(time: points[0].time, value: 80),
    Sample(time: points[1].time, value: 82),
    Sample(time: points[2].time, value: 84),
  ];
  final power = [
    Sample(time: points[0].time, value: 200),
    Sample(time: points[1].time, value: 210),
    Sample(time: points[2].time, value: 220),
  ];
  final temperature = [
    Sample(time: points[0].time, value: 21),
    Sample(time: points[1].time, value: 22),
    Sample(time: points[2].time, value: 23),
  ];

  final baseActivity = RawActivity(
    points: points,
    channels: {
      Channel.heartRate: hr,
      Channel.cadence: cadence,
      Channel.power: power,
      Channel.temperature: temperature,
    },
    laps: [
      Lap(
        startTime: points.first.time,
        endTime: points.last.time,
        distanceMeters: 150,
      ),
    ],
    sport: Sport.cycling,
    creator: 'unit-test device',
  );

  final result = RawTransforms.computeCumulativeDistance(baseActivity);
  final withDistance = result.activity;
  final withSpeed = RawEditor(
    withDistance,
  ).recomputeDistanceAndSpeed().activity;
  return withSpeed;
}

/// Fluent builder for creating test activities with custom configuration.
///
/// Example:
/// ```dart
/// final activity = ActivityBuilder()
///   .withPoints(3, startTime: DateTime.utc(2024, 1, 1))
///   .withHeartRate([140, 145, 150])
///   .withSport(Sport.running)
///   .build();
/// ```
class ActivityBuilder {
  List<GeoPoint> _points = [];
  final Map<Channel, List<Sample>> _channels = {};
  List<Lap> _laps = [];
  Sport? _sport;
  String? _creator;
  String? _gpxTrackName;
  String? _gpxMetadataName;
  String? _gpxMetadataDescription;

  /// Creates points with default spacing and location.
  ///
  /// [count] - Number of points to create
  /// [startTime] - Start time (default: 2024-04-01 06:00:00 UTC)
  /// [intervalSeconds] - Time between points (default: 5)
  /// [startLat] - Starting latitude (default: 40.0)
  /// [startLon] - Starting longitude (default: -105.0)
  /// [startEle] - Starting elevation (default: 1600)
  /// [latIncrement] - Latitude increment per point (default: 0.0005)
  /// [lonIncrement] - Longitude increment per point (default: 0.0005)
  /// [eleIncrement] - Elevation increment per point (default: 1)
  ActivityBuilder withPoints(
    int count, {
    DateTime? startTime,
    int intervalSeconds = 5,
    double startLat = 40.0,
    double startLon = -105.0,
    double startEle = 1600,
    double latIncrement = 0.0005,
    double lonIncrement = 0.0005,
    double eleIncrement = 1,
  }) {
    final baseTime = startTime ?? DateTime.utc(2024, 4, 1, 6);
    _points = List.generate(
      count,
      (i) => GeoPoint(
        latitude: startLat + (i * latIncrement),
        longitude: startLon + (i * lonIncrement),
        elevation: startEle + (i * eleIncrement),
        time: baseTime.add(Duration(seconds: i * intervalSeconds)),
      ),
    );
    return this;
  }

  /// Adds custom points directly.
  ActivityBuilder withCustomPoints(List<GeoPoint> points) {
    _points = points;
    return this;
  }

  /// Adds heart rate channel with values.
  ///
  /// If [values] length matches points, creates sample for each point.
  /// Otherwise creates samples with same timestamps as values list.
  ActivityBuilder withHeartRate(List<num> values) {
    _channels[Channel.heartRate] = _createSamples(values);
    return this;
  }

  /// Adds cadence channel with values.
  ActivityBuilder withCadence(List<num> values) {
    _channels[Channel.cadence] = _createSamples(values);
    return this;
  }

  /// Adds power channel with values.
  ActivityBuilder withPower(List<num> values) {
    _channels[Channel.power] = _createSamples(values);
    return this;
  }

  /// Adds temperature channel with values.
  ActivityBuilder withTemperature(List<num> values) {
    _channels[Channel.temperature] = _createSamples(values);
    return this;
  }

  /// Adds a custom channel with values.
  ActivityBuilder withChannel(Channel channel, List<num> values) {
    _channels[channel] = _createSamples(values);
    return this;
  }

  /// Adds laps to the activity.
  ActivityBuilder withLaps(List<Lap> laps) {
    _laps = laps;
    return this;
  }

  /// Adds a single lap covering all points.
  ActivityBuilder withSingleLap({double? distanceMeters, Sport? lapSport}) {
    if (_points.isEmpty) {
      throw StateError('Must call withPoints() before withSingleLap()');
    }
    _laps = [
      Lap(
        startTime: _points.first.time,
        endTime: _points.last.time,
        distanceMeters: distanceMeters ?? 150,
        sport: lapSport,
      ),
    ];
    return this;
  }

  /// Sets the sport type.
  ActivityBuilder withSport(Sport sport) {
    _sport = sport;
    return this;
  }

  /// Sets the creator/device name.
  ActivityBuilder withCreator(String creator) {
    _creator = creator;
    return this;
  }

  /// Sets GPX-specific metadata.
  ActivityBuilder withGpxMetadata({
    String? trackName,
    String? metadataName,
    String? metadataDescription,
  }) {
    _gpxTrackName = trackName;
    _gpxMetadataName = metadataName;
    _gpxMetadataDescription = metadataDescription;
    return this;
  }

  /// Builds the RawActivity.
  ///
  /// If [computeDistance] is true (default), calculates cumulative distance
  /// and speed channels.
  RawActivity build({bool computeDistance = true}) {
    var activity = RawActivity(
      points: _points,
      channels: _channels,
      laps: _laps,
      sport: _sport ?? Sport.unknown,
      creator: _creator,
      gpxTrackName: _gpxTrackName,
      gpxMetadataName: _gpxMetadataName,
      gpxMetadataDescription: _gpxMetadataDescription,
    );

    if (computeDistance && _points.isNotEmpty) {
      final result = RawTransforms.computeCumulativeDistance(activity);
      activity = result.activity;
      activity = RawEditor(activity).recomputeDistanceAndSpeed().activity;
    }

    return activity;
  }

  List<Sample> _createSamples(List<num> values) {
    if (_points.isEmpty) {
      throw StateError('Must call withPoints() before adding channels');
    }
    if (values.length != _points.length) {
      throw ArgumentError(
        'Values length (${values.length}) must match points length (${_points.length})',
      );
    }
    return List.generate(
      values.length,
      (i) => Sample(time: _points[i].time, value: values[i].toDouble()),
    );
  }
}

/// Creates a simple running activity with 3 points.
RawActivity buildRunningActivity() {
  return ActivityBuilder()
      .withPoints(3)
      .withHeartRate([140, 145, 150])
      .withCadence([80, 82, 84])
      .withSport(Sport.running)
      .withSingleLap()
      .build();
}

/// Creates a simple cycling activity with 3 points.
RawActivity buildCyclingActivity() {
  return ActivityBuilder()
      .withPoints(3)
      .withHeartRate([130, 135, 140])
      .withCadence([85, 87, 90])
      .withPower([180, 190, 200])
      .withSport(Sport.cycling)
      .withSingleLap()
      .build();
}

/// Creates a multi-sport activity (triathlon: swim, bike, run).
RawActivity buildMultiSportActivity() {
  final swimStart = DateTime.utc(2024, 6, 1, 8, 0);
  final bikeStart = swimStart.add(const Duration(minutes: 30));
  final runStart = bikeStart.add(const Duration(hours: 1));

  final swimPoints = List.generate(
    3,
    (i) => GeoPoint(
      latitude: 40.0 + (i * 0.0001),
      longitude: -105.0 + (i * 0.0001),
      time: swimStart.add(Duration(seconds: i * 10)),
    ),
  );

  final bikePoints = List.generate(
    3,
    (i) => GeoPoint(
      latitude: 40.001 + (i * 0.001),
      longitude: -105.001 + (i * 0.001),
      elevation: 1600.0 + (i * 5),
      time: bikeStart.add(Duration(minutes: i * 20)),
    ),
  );

  final runPoints = List.generate(
    3,
    (i) => GeoPoint(
      latitude: 40.01 + (i * 0.0005),
      longitude: -105.01 + (i * 0.0005),
      elevation: 1620.0 + (i * 2),
      time: runStart.add(Duration(minutes: i * 10)),
    ),
  );

  final allPoints = [...swimPoints, ...bikePoints, ...runPoints];

  return RawActivity(
    points: allPoints,
    laps: [
      Lap(
        startTime: swimPoints.first.time,
        endTime: swimPoints.last.time,
        sport: Sport.swimming,
      ),
      Lap(
        startTime: bikePoints.first.time,
        endTime: bikePoints.last.time,
        sport: Sport.cycling,
      ),
      Lap(
        startTime: runPoints.first.time,
        endTime: runPoints.last.time,
        sport: Sport.running,
      ),
    ],
    sport: Sport.other, // Multi-sport activity
  );
}
