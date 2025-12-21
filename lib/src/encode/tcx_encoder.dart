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
    final tcxVersion = options.tcxVersion;
    final emitV1 = tcxVersion == TcxVersion.v1;
    final points = [...activity.points]
      ..sort((a, b) => a.time.compareTo(b.time));
    if (points.isEmpty) {
      return _emptyDocument(
        emitV1
            ? 'http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v1'
            : 'http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2',
      );
    }
    final metadataExtensions = activity.gpxMetadataExtensions;
    final trackExtensions = activity.gpxTrackExtensions;
    final namespaceRegistry = <String, String>{};
    for (final extension in metadataExtensions) {
      _collectExtensionNamespaces(extension, namespaceRegistry);
    }
    for (final extension in trackExtensions) {
      _collectExtensionNamespaces(extension, namespaceRegistry);
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
    final hrDelta = options.maxDeltaFor(Channel.heartRate);
    final cadenceDelta = options.maxDeltaFor(Channel.cadence);
    final distanceDelta = options.maxDeltaFor(Channel.distance);
    final searchDelta =
        [
          hrDelta,
          cadenceDelta,
          options.maxDeltaFor(Channel.speed),
          options.defaultMaxDelta,
        ].nonNulls.fold<Duration>(
          options.defaultMaxDelta,
          (previous, current) => current > previous ? current : previous,
        );
    final tcxNamespace = emitV1
        ? 'http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v1'
        : 'http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2';
    final tcxSchema = emitV1
        ? 'http://www.garmin.com/xmlschemas/TrainingCenterDatabasev1.xsd'
        : 'http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd';
    final rootAttributes = <String, String>{
      'xmlns': tcxNamespace,
      'xmlns:xsi': 'http://www.w3.org/2001/XMLSchema-instance',
      'xsi:schemaLocation': '$tcxNamespace $tcxSchema',
    };
    namespaceRegistry.forEach((prefix, uri) {
      final key = 'xmlns:$prefix';
      rootAttributes.putIfAbsent(key, () => uri);
    });
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'TrainingCenterDatabase',
      attributes: rootAttributes,
      nest: () {
        builder.element(
          'Activities',
          nest: () {
            builder.element(
              'Activity',
              attributes: {'Sport': _sportLabel(activity.sport)},
              nest: () {
                builder.element(
                  'Id',
                  nest: points.first.time.toUtc().toIso8601String(),
                );
                var wroteTrackExtensions = false;
                final channelCursor = ChannelMapper.cursor(
                  activity.channels,
                  maxDelta: searchDelta,
                );
                for (final lap in laps) {
                  builder.element(
                    'Lap',
                    attributes: {
                      'StartTime': lap.startTime.toUtc().toIso8601String(),
                    },
                    nest: () {
                      final totalSeconds = lap.elapsed.inMicroseconds / 1e6;
                      builder.element(
                        'TotalTimeSeconds',
                        nest: totalSeconds.toStringAsFixed(3),
                      );
                      builder.element(
                        'DistanceMeters',
                        nest:
                            (lap.distanceMeters ?? activity.approximateDistance)
                                .toStringAsFixed(1),
                      );
                      builder.element(
                        'Track',
                        nest: () {
                          if (trackExtensions.isNotEmpty &&
                              !wroteTrackExtensions) {
                            builder.element(
                              'Extensions',
                              nest: () {
                                for (final extension in trackExtensions) {
                                  _writeExtensionNode(builder, extension);
                                }
                              },
                            );
                            wroteTrackExtensions = true;
                          }
                          var cumulativeDistance = 0.0;
                          GeoPoint? previous;
                          for (final point in points.where(
                            (p) =>
                                !p.time.isBefore(lap.startTime) &&
                                !p.time.isAfter(lap.endTime),
                          )) {
                            final snapshot = channelCursor.snapshot(point.time);
                            final hr = _valueWithin(
                              snapshot.heartRate,
                              snapshot.heartRateDelta,
                              hrDelta,
                            );
                            final cadence = _valueWithin(
                              snapshot.cadence,
                              snapshot.cadenceDelta,
                              cadenceDelta,
                            );
                            final knownDistance = _valueWithin(
                              snapshot.valueFor(Channel.distance),
                              snapshot.deltaFor(Channel.distance),
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
                            builder.element(
                              'Trackpoint',
                              nest: () {
                                builder.element(
                                  'Time',
                                  nest: point.time.toUtc().toIso8601String(),
                                );
                                builder.element(
                                  'Position',
                                  nest: () {
                                    builder.element(
                                      'LatitudeDegrees',
                                      nest: _round(
                                        point.latitude,
                                        options.precisionLatLon,
                                      ),
                                    );
                                    builder.element(
                                      'LongitudeDegrees',
                                      nest: _round(
                                        point.longitude,
                                        options.precisionLatLon,
                                      ),
                                    );
                                  },
                                );
                                final elevation = point.elevation;
                                if (elevation != null) {
                                  builder.element(
                                    'AltitudeMeters',
                                    nest: _round(
                                      elevation,
                                      options.precisionEle,
                                    ),
                                  );
                                }
                                builder.element(
                                  'DistanceMeters',
                                  nest: cumulativeDistance.toStringAsFixed(1),
                                );
                                if (hr != null) {
                                  builder.element(
                                    'HeartRateBpm',
                                    nest: () {
                                      builder.element(
                                        'Value',
                                        nest: hr.round().toString(),
                                      );
                                    },
                                  );
                                }
                                if (cadence != null) {
                                  builder.element(
                                    'Cadence',
                                    nest: cadence.round().toString(),
                                  );
                                }
                              },
                            );
                          }
                        },
                      );
                    },
                  );
                }
                if (metadataExtensions.isNotEmpty) {
                  builder.element(
                    'Extensions',
                    nest: () {
                      for (final extension in metadataExtensions) {
                        _writeExtensionNode(builder, extension);
                      }
                    },
                  );
                }
                final device = activity.device;
                final creatorLabel = activity.creator;
                if (device != null && device.isNotEmpty) {
                  builder.element(
                    'Creator',
                    attributes: const {'xsi:type': 'Device_t'},
                    nest: () {
                      final name = device.model ?? creatorLabel;
                      if (name != null && name.trim().isNotEmpty) {
                        builder.element('Name', nest: name);
                      } else if (creatorLabel != null) {
                        builder.text(creatorLabel);
                      }
                      _writeTcxDeviceMetadata(builder, device);
                    },
                  );
                } else if (creatorLabel != null) {
                  builder.element('Creator', nest: creatorLabel);
                }
              },
            );
          },
        );
      },
    );
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  String _emptyDocument(String tcxNamespace) {
    final schemaSuffix = tcxNamespace.endsWith('/v1')
        ? 'http://www.garmin.com/xmlschemas/TrainingCenterDatabasev1.xsd'
        : 'http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd';
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'TrainingCenterDatabase',
      attributes: {
        'xmlns': tcxNamespace,
        'xmlns:xsi': 'http://www.w3.org/2001/XMLSchema-instance',
        'xsi:schemaLocation': '$tcxNamespace $schemaSuffix',
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

void _collectExtensionNamespaces(
  GpxExtensionNode node,
  Map<String, String> registry,
) {
  final prefix = node.namespacePrefix;
  final uri = node.namespaceUri;
  if (prefix != null && uri != null && !registry.containsKey(prefix)) {
    registry[prefix] = uri;
  }
  for (final child in node.children) {
    _collectExtensionNamespaces(child, registry);
  }
}

void _writeExtensionNode(XmlBuilder builder, GpxExtensionNode node) {
  final qualified = node.namespacePrefix != null
      ? '${node.namespacePrefix}:${node.name}'
      : node.name;
  builder.element(
    qualified,
    attributes: node.attributes,
    nest: () {
      if (node.value != null) {
        builder.text(node.value!);
      }
      for (final child in node.children) {
        _writeExtensionNode(builder, child);
      }
    },
  );
}

void _writeTcxDeviceMetadata(
  XmlBuilder builder,
  ActivityDeviceMetadata device,
) {
  void writeTag(String tag, String? value) {
    if (value == null) {
      return;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    builder.element(tag, nest: trimmed);
  }

  writeTag('Manufacturer', device.manufacturer);
  writeTag('ProductID', device.product);
  writeTag('UnitId', device.serialNumber);

  if (device.softwareVersion != null &&
      device.softwareVersion!.trim().isNotEmpty) {
    final version = device.softwareVersion!.trim();
    final parts = version.split('+');
    final core = parts.first.split('.');
    final build = parts.length > 1 ? parts[1].split('.') : const <String>[];
    builder.element(
      'Version',
      nest: () {
        if (core.isNotEmpty && core[0].isNotEmpty) {
          builder.element('VersionMajor', nest: core[0]);
        }
        if (core.length > 1 && core[1].isNotEmpty) {
          builder.element('VersionMinor', nest: core[1]);
        }
        if (build.isNotEmpty && build[0].isNotEmpty) {
          builder.element('BuildMajor', nest: build[0]);
        }
        if (build.length > 1 && build[1].isNotEmpty) {
          builder.element('BuildMinor', nest: build[1]);
        }
      },
    );
  }
}
