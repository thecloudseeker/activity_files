// SPDX-License-Identifier: BSD-3-Clause

import '../models.dart';

/// Optional typed wrapper over [RawActivity] for FIT-like access patterns.
///
/// This is an additive API that keeps [RawActivity] as the canonical model while
/// offering familiar `session / records / laps` views for FIT-oriented workflows.
class FitTypedActivityView {
  const FitTypedActivityView(
    this.activity, {
    this.channelMatchWindow = const Duration(seconds: 5),
  });

  /// Canonical activity model backing this view.
  final RawActivity activity;

  /// Maximum timestamp delta used to match channel samples to record points.
  final Duration channelMatchWindow;

  /// Session-level typed view.
  FitSessionView get session => FitSessionView.fromRaw(activity);

  /// Lap-level typed views.
  List<FitLapView> get laps => activity.laps
      .map((lap) => FitLapView.fromRaw(lap, activity.sport))
      .toList(growable: false);

  /// Record-level typed views mapped from geographic points.
  ///
  /// Channels are matched by nearest timestamp within [channelMatchWindow].
  Iterable<FitRecordView> get records sync* {
    for (final point in activity.points) {
      yield FitRecordView(
        time: point.time,
        latitude: point.latitude,
        longitude: point.longitude,
        elevation: point.elevation,
        heartRate: _nearestSampleValue(Channel.heartRate, point.time),
        cadence: _nearestSampleValue(Channel.cadence, point.time),
        power: _nearestSampleValue(Channel.power, point.time),
        temperature: _nearestSampleValue(Channel.temperature, point.time),
        speed: _nearestSampleValue(Channel.speed, point.time),
        distance: _nearestSampleValue(Channel.distance, point.time),
        developerFields: _developerFieldValues(point.time),
      );
    }
  }

  /// Developer-field channels exposed at activity level.
  Map<String, List<Sample>> get developerChannels {
    final result = <String, List<Sample>>{};
    for (final entry in activity.channels.entries) {
      final id = entry.key.id;
      if (!_isDeveloperChannel(id)) {
        continue;
      }
      result[id] = List<Sample>.unmodifiable(entry.value);
    }
    return result;
  }

  double? _nearestSampleValue(Channel channel, DateTime time) {
    final samples = activity.channel(channel);
    if (samples.isEmpty) {
      return null;
    }
    Sample? best;
    var bestDelta = Duration(days: 36500);
    for (final sample in samples) {
      final delta = sample.time.difference(time).abs();
      if (delta < bestDelta) {
        best = sample;
        bestDelta = delta;
      }
    }
    if (best == null || bestDelta > channelMatchWindow) {
      return null;
    }
    return best.value;
  }

  Map<String, double> _developerFieldValues(DateTime time) {
    final values = <String, double>{};
    for (final entry in activity.channels.entries) {
      final id = entry.key.id;
      if (!_isDeveloperChannel(id)) {
        continue;
      }
      final value = _nearestSampleValue(entry.key, time);
      if (value != null) {
        values[id] = value;
      }
    }
    return values;
  }
}

/// Typed session-level view.
class FitSessionView {
  const FitSessionView({
    required this.sport,
    this.creator,
    this.device,
    this.summary,
  });

  factory FitSessionView.fromRaw(RawActivity activity) => FitSessionView(
    sport: activity.sport,
    creator: activity.creator,
    device: activity.device,
    summary: activity.summary,
  );

  final Sport sport;
  final String? creator;
  final ActivityDeviceMetadata? device;
  final ActivitySummary? summary;

  Duration? get elapsedTime => summary?.elapsedTime;
  Duration? get timerTime => summary?.timerTime;
  double? get totalDistanceMeters => summary?.totalDistanceMeters;
  double? get avgHeartRate => summary?.avgHeartRate;
  double? get maxHeartRate => summary?.maxHeartRate;
  double? get avgCadence => summary?.avgCadence;
  double? get avgPower => summary?.avgPower;
}

/// Typed lap-level view.
class FitLapView {
  const FitLapView({
    required this.startTime,
    required this.endTime,
    required this.sport,
    this.distanceMeters,
    this.name,
    this.avgSpeed,
    this.maxSpeed,
    this.avgHeartRate,
    this.maxHeartRate,
    this.avgCadence,
    this.maxCadence,
    this.avgPower,
    this.maxPower,
    this.calories,
  });

  factory FitLapView.fromRaw(Lap lap, Sport defaultSport) => FitLapView(
    startTime: lap.startTime,
    endTime: lap.endTime,
    sport: lap.sport ?? defaultSport,
    distanceMeters: lap.distanceMeters,
    name: lap.name,
    avgSpeed: lap.avgSpeed,
    maxSpeed: lap.maxSpeed,
    avgHeartRate: lap.avgHeartRate,
    maxHeartRate: lap.maxHeartRate,
    avgCadence: lap.avgCadence,
    maxCadence: lap.maxCadence,
    avgPower: lap.avgPower,
    maxPower: lap.maxPower,
    calories: lap.calories,
  );

  final DateTime startTime;
  final DateTime endTime;
  final Sport sport;
  final double? distanceMeters;
  final String? name;
  final double? avgSpeed;
  final double? maxSpeed;
  final double? avgHeartRate;
  final double? maxHeartRate;
  final double? avgCadence;
  final double? maxCadence;
  final double? avgPower;
  final double? maxPower;
  final double? calories;

  Duration get elapsed => endTime.difference(startTime);
}

/// Typed record-level view.
class FitRecordView {
  const FitRecordView({
    required this.time,
    required this.latitude,
    required this.longitude,
    this.elevation,
    this.heartRate,
    this.cadence,
    this.power,
    this.temperature,
    this.speed,
    this.distance,
    Map<String, double>? developerFields,
  }) : developerFields = developerFields ?? const <String, double>{};

  final DateTime time;
  final double latitude;
  final double longitude;
  final double? elevation;
  final double? heartRate;
  final double? cadence;
  final double? power;
  final double? temperature;
  final double? speed;
  final double? distance;

  /// Per-record developer fields mapped from custom FIT channels.
  final Map<String, double> developerFields;
}

/// Extension helper for ergonomic typed-view access.
extension FitTypedViewExtension on RawActivity {
  /// Creates a typed FIT view without changing canonical [RawActivity] usage.
  FitTypedActivityView asFitView({
    Duration channelMatchWindow = const Duration(seconds: 5),
  }) => FitTypedActivityView(this, channelMatchWindow: channelMatchWindow);
}

bool _isDeveloperChannel(String id) =>
    id == 'running_power' || id.startsWith('fit_dev_');
