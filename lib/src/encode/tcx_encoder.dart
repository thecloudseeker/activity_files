// SPDX-License-Identifier: BSD-3-Clause
import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../channel_mapper.dart';
import '../models.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';

/// Encoder for the TCX file format.
class TcxEncoder implements ActivityFormatEncoder {
  const TcxEncoder();
  @override
  String encode(RawActivity activity, EncoderOptions options) {
    final points = [...activity.points]
      ..sort((a, b) => a.time.compareTo(b.time));
    if (points.isEmpty) {
      return _emptyDocument();
    }
    final laps = activity.laps.isNotEmpty
        ? activity.laps
        : [
            Lap(
              startTime: points.first.time,
              endTime: points.last.time,
              distanceMeters: activity.approximateDistance,
              name: 'Lap 1',
            ),
          ];
    final distanceSamples = [...activity.channel(Channel.distance)]
      ..sort((a, b) => a.time.compareTo(b.time));
    final hrDelta = options.maxDeltaFor(Channel.heartRate);
    final cadenceDelta = options.maxDeltaFor(Channel.cadence);
    final distanceDelta = options.maxDeltaFor(Channel.distance);
    final searchDelta = [
      hrDelta,
      cadenceDelta,
      options.maxDeltaFor(Channel.speed),
      options.defaultMaxDelta,
    ].nonNulls.fold<Duration>(
          options.defaultMaxDelta,
          (previous, current) => current > previous ? current : previous,
        );
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'TrainingCenterDatabase',
      attributes: const {
        'xmlns': 'http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2',
        'xmlns:xsi': 'http://www.w3.org/2001/XMLSchema-instance',
        'xsi:schemaLocation':
            'http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 '
                'http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd',
      },
      nest: () {
        builder.element('Activities', nest: () {
          builder.element(
            'Activity',
            attributes: {'Sport': _sportLabel(activity.sport)},
            nest: () {
              builder.element('Id',
                  nest: points.first.time.toUtc().toIso8601String());
              for (final lap in laps) {
                builder.element(
                  'Lap',
                  attributes: {
                    'StartTime': lap.startTime.toUtc().toIso8601String()
                  },
                  nest: () {
                    final totalSeconds = lap.elapsed.inMicroseconds / 1e6;
                    builder.element(
                      'TotalTimeSeconds',
                      nest: totalSeconds.toStringAsFixed(3),
                    );
                    builder.element(
                      'DistanceMeters',
                      nest: (lap.distanceMeters ?? activity.approximateDistance)
                          .toStringAsFixed(1),
                    );
                    builder.element('Track', nest: () {
                      var cumulativeDistance = 0.0;
                      GeoPoint? previous;
                      for (final point in points.where((p) =>
                          !p.time.isBefore(lap.startTime) &&
                          !p.time.isAfter(lap.endTime))) {
                        final snapshot = ChannelMapper.mapAt(
                          point.time,
                          activity.channels,
                          maxDelta: searchDelta,
                        );
                        final hr = _valueWithin(snapshot.heartRate,
                            snapshot.heartRateDelta, hrDelta);
                        final cadence = _valueWithin(
                          snapshot.cadence,
                          snapshot.cadenceDelta,
                          cadenceDelta,
                        );
                        final knownDistance = _sampleValueAt(
                          distanceSamples,
                          point.time,
                          distanceDelta,
                        );
                        if (knownDistance != null) {
                          cumulativeDistance = knownDistance;
                        } else {
                          final prev = previous;
                          if (prev != null) {
                            cumulativeDistance += _haversine(prev, point);
                          }
                        }
                        previous = point;
                        builder.element('Trackpoint', nest: () {
                          builder.element(
                            'Time',
                            nest: point.time.toUtc().toIso8601String(),
                          );
                          builder.element('Position', nest: () {
                            builder.element(
                              'LatitudeDegrees',
                              nest: _round(
                                  point.latitude, options.precisionLatLon),
                            );
                            builder.element(
                              'LongitudeDegrees',
                              nest: _round(
                                  point.longitude, options.precisionLatLon),
                            );
                          });
                          final elevation = point.elevation;
                          if (elevation != null) {
                            builder.element(
                              'AltitudeMeters',
                              nest: _round(elevation, options.precisionEle),
                            );
                          }
                          builder.element(
                            'DistanceMeters',
                            nest: cumulativeDistance.toStringAsFixed(1),
                          );
                          if (hr != null) {
                            builder.element('HeartRateBpm', nest: () {
                              builder.element('Value',
                                  nest: hr.round().toString());
                            });
                          }
                          if (cadence != null) {
                            builder.element('Cadence',
                                nest: cadence.round().toString());
                          }
                        });
                      }
                    });
                  },
                );
              }
              if (activity.creator != null) {
                builder.element('Creator', nest: activity.creator!);
              }
            },
          );
        });
      },
    );
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }
  String _emptyDocument() {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'TrainingCenterDatabase',
      attributes: const {
        'xmlns': 'http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2',
      },
      nest: () {
        builder.element('Activities');
      },
    );
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }
  String _sportLabel(Sport sport) => switch (sport) {
        Sport.running => 'Running',
        Sport.cycling => 'Biking',
        Sport.walking => 'Walking',
        _ => 'Other',
      };
}
String _round(double value, int precision) => value.toStringAsFixed(precision);
double? _valueWithin(double? value, Duration? delta, Duration tolerance) {
  if (value == null || delta == null) {
    return null;
  }
  return delta <= tolerance ? value : null;
}
double? _sampleValueAt(
  List<Sample> samples,
  DateTime time,
  Duration tolerance,
) {
  if (samples.isEmpty) {
    return null;
  }
  final target = time.toUtc().microsecondsSinceEpoch;
  Sample? candidate;
  var best = tolerance.inMicroseconds + 1;
  for (final sample in samples) {
    final delta = (sample.time.microsecondsSinceEpoch - target).abs();
    if (delta <= tolerance.inMicroseconds && delta < best) {
      candidate = sample;
      best = delta;
    }
  }
  return candidate?.value;
}
double _haversine(GeoPoint a, GeoPoint b) {
  const earthRadius = 6371000.0;
  final dLat = _radians(b.latitude - a.latitude);
  final dLon = _radians(b.longitude - a.longitude);
  final lat1 = _radians(a.latitude);
  final lat2 = _radians(b.latitude);
  final sinDLat = math.sin(dLat / 2);
  final sinDLon = math.sin(dLon / 2);
  final h =
      sinDLat * sinDLat + math.cos(lat1) * math.cos(lat2) * sinDLon * sinDLon;
  final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  return earthRadius * c;
}
double _radians(double deg) => deg * math.pi / 180.0;
