// SPDX-License-Identifier: BSD-3-Clause
import 'package:xml/xml.dart';

import '../channel_mapper.dart';
import '../geo_math.dart';
import '../models.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';

/// Encoder for the TCX file format.
class TcxEncoder implements ActivityFormatEncoder {
  const TcxEncoder();
  @override
  String encode(RawActivity activity, EncoderOptions options) {
    // TCX cannot represent multiple tracks; merge them so no data is lost.
    activity = activity.flattened();
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
    final speedDelta = options.maxDeltaFor(Channel.speed);
    final powerDelta = options.maxDeltaFor(Channel.power);
    final searchDelta =
        [
          hrDelta,
          cadenceDelta,
          speedDelta,
          powerDelta,
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
      // ActivityExtension/v2 for TPX (Speed/Watts) and LX (lap power) nodes.
      'xmlns:ns3': 'http://www.garmin.com/xmlschemas/ActivityExtension/v2',
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
        final channelCursor = ChannelMapper.cursor(
          activity.channels,
          maxDelta: searchDelta,
        );
        // Re-split laps into one <Activity> per consecutive sport, so a merged
        // multi-sport (triathlon) activity round-trips back to multiple
        // <Activity> elements. A single-sport activity yields exactly one.
        final lapGroups = _groupLapsBySport(laps, activity.sport);
        builder.element(
          'Activities',
          nest: () {
            for (final (groupIndex, group) in lapGroups.indexed) {
              builder.element(
                'Activity',
                attributes: {'Sport': _sportLabel(group.sport)},
                nest: () {
                  builder.element(
                    'Id',
                    nest: group.laps.first.startTime.toUtc().toIso8601String(),
                  );
                  var wroteTrackExtensions = false;
                  for (final lap in group.laps) {
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
                              (lap.distanceMeters ??
                                      activity.approximateDistance)
                                  .toStringAsFixed(1),
                        );
                        // Lap statistics in TCX schema order
                        // (MaximumSpeed, Calories, AvgHR, MaxHR, Cadence).
                        if (lap.maxSpeed != null) {
                          builder.element(
                            'MaximumSpeed',
                            nest: lap.maxSpeed!.toStringAsFixed(3),
                          );
                        }
                        if (lap.calories != null) {
                          builder.element(
                            'Calories',
                            nest: lap.calories!.round().toString(),
                          );
                        }
                        void writeHr(String tag, double? value) {
                          if (value == null) return;
                          builder.element(
                            tag,
                            nest: () {
                              builder.element(
                                'Value',
                                nest: value.round().toString(),
                              );
                            },
                          );
                        }

                        writeHr('AverageHeartRateBpm', lap.avgHeartRate);
                        writeHr('MaximumHeartRateBpm', lap.maxHeartRate);
                        if (lap.tcxIntensity != null) {
                          builder.element('Intensity', nest: lap.tcxIntensity!);
                        }
                        if (lap.avgCadence != null) {
                          builder.element(
                            'Cadence',
                            nest: lap.avgCadence!.round().toString(),
                          );
                        }
                        if (lap.tcxTriggerMethod != null) {
                          builder.element(
                            'TriggerMethod',
                            nest: lap.tcxTriggerMethod!,
                          );
                        }
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
                              final snapshot = channelCursor.snapshot(
                                point.time,
                              );
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
                              final speed = _valueWithin(
                                snapshot.valueFor(Channel.speed),
                                snapshot.deltaFor(Channel.speed),
                                speedDelta,
                              );
                              final watts = _valueWithin(
                                snapshot.valueFor(Channel.power),
                                snapshot.deltaFor(Channel.power),
                                powerDelta,
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
                                  cumulativeDistance += haversineMeters(
                                    prev,
                                    point,
                                  );
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
                                  if (speed != null || watts != null) {
                                    builder.element(
                                      'Extensions',
                                      nest: () {
                                        builder.element(
                                          'ns3:TPX',
                                          nest: () {
                                            if (speed != null) {
                                              builder.element(
                                                'ns3:Speed',
                                                nest: speed.toStringAsFixed(3),
                                              );
                                            }
                                            if (watts != null) {
                                              builder.element(
                                                'ns3:Watts',
                                                nest: watts.round().toString(),
                                              );
                                            }
                                          },
                                        );
                                      },
                                    );
                                  }
                                },
                              );
                            }
                          },
                        );
                        // LX lap extensions (ActivityExtension/v2) carry lap
                        // power and speed stats the base schema cannot hold.
                        if (lap.avgSpeed != null ||
                            lap.maxCadence != null ||
                            lap.avgPower != null ||
                            lap.maxPower != null) {
                          builder.element(
                            'Extensions',
                            nest: () {
                              builder.element(
                                'ns3:LX',
                                nest: () {
                                  if (lap.avgSpeed != null) {
                                    builder.element(
                                      'ns3:AvgSpeed',
                                      nest: lap.avgSpeed!.toStringAsFixed(3),
                                    );
                                  }
                                  if (lap.maxCadence != null) {
                                    builder.element(
                                      'ns3:MaxBikeCadence',
                                      nest: lap.maxCadence!.round().toString(),
                                    );
                                  }
                                  if (lap.avgPower != null) {
                                    builder.element(
                                      'ns3:AvgWatts',
                                      nest: lap.avgPower!.round().toString(),
                                    );
                                  }
                                  if (lap.maxPower != null) {
                                    builder.element(
                                      'ns3:MaxWatts',
                                      nest: lap.maxPower!.round().toString(),
                                    );
                                  }
                                },
                              );
                            },
                          );
                        }
                      },
                    );
                  }
                  // Notes and file-level metadata extensions belong to the file,
                  // so emit them only on the first activity.
                  if (groupIndex == 0) {
                    final notes = activity.tcxNotes;
                    if (notes != null && notes.trim().isNotEmpty) {
                      builder.element('Notes', nest: notes.trim());
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
            }
          },
        );
        // <Author> is a file-level property, emitted after <Activities>.
        final author = activity.tcxAuthor;
        if (author != null && author.trim().isNotEmpty) {
          builder.element(
            'Author',
            attributes: const {'xsi:type': 'Application_t'},
            nest: () {
              builder.element('Name', nest: author.trim());
            },
          );
        }
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

/// A run of consecutive laps sharing one sport, emitted as one `<Activity>`.
class _LapGroup {
  _LapGroup(this.sport, this.laps);
  final Sport sport;
  final List<Lap> laps;
}

/// Groups laps into consecutive same-sport runs. A single-sport activity
/// yields one group (one `<Activity>`); a triathlon yields one per leg.
List<_LapGroup> _groupLapsBySport(List<Lap> laps, Sport activitySport) {
  final groups = <_LapGroup>[];
  for (final lap in laps) {
    final sport = lap.sport ?? activitySport;
    if (groups.isNotEmpty && groups.last.sport == sport) {
      groups.last.laps.add(lap);
    } else {
      groups.add(_LapGroup(sport, [lap]));
    }
  }
  return groups.isEmpty ? [_LapGroup(activitySport, laps)] : groups;
}

String _round(double value, int precision) => value.toStringAsFixed(precision);
double? _valueWithin(double? value, Duration? delta, Duration tolerance) {
  if (value == null || delta == null) {
    return null;
  }
  return delta <= tolerance ? value : null;
}

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
