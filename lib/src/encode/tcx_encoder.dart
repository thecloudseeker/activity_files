// SPDX-License-Identifier: BSD-3-Clause
import 'package:xml/xml.dart';

import '../channel_mapper.dart';
import '../geo_math.dart';
import '../library_namespace.dart';
import '../models.dart';
import '../stable_sort.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';
import 'encoder_utils.dart';

/// Namespace URI hardcoded to the `ns3` prefix for TPX/LX elements
/// everywhere this encoder writes them.
const _activityExtensionNamespace =
    'http://www.garmin.com/xmlschemas/ActivityExtension/v2';

/// Encoder for the TCX file format.
class TcxEncoder implements ActivityFormatEncoder {
  const TcxEncoder();
  @override
  String encode(RawActivity activity, EncoderOptions options) {
    // TCX cannot represent multiple tracks; merge them so no data is lost.
    activity = activity.flattened();
    final tcxVersion = options.tcxVersion;
    final emitV1 = tcxVersion == TcxVersion.v1;
    final points = [...activity.points];
    stableSort(points, (a, b) => a.time.compareTo(b.time));
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
    // The `ns3` prefix is reserved below for Garmin's own ActivityExtension
    // (TPX/LX), hardcoded at every write site rather than looked up, so it
    // can never be reassigned to whatever the source file happened to use
    // it for. TCX's ns2/ns3/ns4... numbering for foreign extensions isn't
    // standardized (assigned per authoring tool), so a source file's own
    // foreign <Extensions> content can legitimately claim `ns3` for a
    // different namespace; move it to a free prefix instead of silently
    // losing it (or silently rebinding it) on a hardcoded-prefix collision.
    var extensionPrefixRemap = const <String, String>{};
    final collidingUri = namespaceRegistry['ns3'];
    if (collidingUri != null && collidingUri != _activityExtensionNamespace) {
      var candidate = 4;
      while (namespaceRegistry.containsKey('ns$candidate')) {
        candidate++;
      }
      final freePrefix = 'ns$candidate';
      namespaceRegistry[freePrefix] = namespaceRegistry.remove('ns3')!;
      extensionPrefixRemap = {'ns3': freePrefix};
    }
    final unorderedLaps = activity.laps.isNotEmpty
        ? activity.laps
        : [
            Lap(
              startTime: points.first.time,
              endTime: points.last.time,
              distanceMeters: activity.approximateDistance,
              name: 'Lap 1',
            ),
          ];
    // _lapEffectiveStart/_lapEffectiveEnd below find each lap's true
    // chronological neighbor by adjacency in this list; callers normally
    // sort laps first (RawEditor.sortAndDedup(), applied by default on
    // convert()/export()), but nothing enforces that on a direct encode()
    // call, and an out-of-order neighbor would silently widen a lap's
    // window against the wrong boundary.
    final laps = [...unorderedLaps];
    if (!_isSortedByStart(laps)) {
      stableSort(laps, (a, b) => a.startTime.compareTo(b.startTime));
    }
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
      'xmlns:ns3': _activityExtensionNamespace,
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
        // Each group is a contiguous slice of the (now globally sorted)
        // `laps` list, so this maps a group's own lap index back to its
        // position in that full list -- needed so a lap's chronological
        // neighbor for boundary-widening is its true neighbor in the whole
        // activity, not just within its own sport group. Using the
        // group-local neighbor left a gap unwidened at every sport-to-sport
        // transition (a lap at the edge of its group has no group-local
        // neighbor even though the very next/previous lap, in the adjacent
        // group, is right there).
        final groupStartIndex = <int>[];
        var runningOffset = 0;
        for (final group in lapGroups) {
          groupStartIndex.add(runningOffset);
          runningOffset += group.laps.length;
        }
        builder.element(
          'Activities',
          nest: () {
            for (final (groupIndex, group) in lapGroups.indexed) {
              // Scoped per <Activity>: a point sitting exactly on a
              // sport-to-sport boundary must still be written to the next
              // sport's <Track>, not just deduplicated away because the
              // previous sport's adjacent lap already claimed it.
              final writtenPoints = Set<GeoPoint>.identity();
              builder.element(
                'Activity',
                attributes: {'Sport': _sportLabel(group.sport)},
                nest: () {
                  builder.element(
                    'Id',
                    nest: group.laps.first.startTime.toUtc().toIso8601String(),
                  );
                  for (final (lapIndex, lap) in group.laps.indexed) {
                    final globalIndex = groupStartIndex[groupIndex] + lapIndex;
                    final prevLap = globalIndex > 0
                        ? laps[globalIndex - 1]
                        : null;
                    final nextLap = globalIndex < laps.length - 1
                        ? laps[globalIndex + 1]
                        : null;
                    final effectiveStart = _lapEffectiveStart(
                      lap.startTime,
                      prevLap?.endTime,
                    );
                    final effectiveEnd = _lapEffectiveEnd(
                      lap.endTime,
                      nextLap?.startTime,
                    );
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
                        // Calories, Intensity and TriggerMethod are required
                        // by the schema: a lap without them gets the neutral
                        // value Garmin's tools write, marked as a default in
                        // the lap's extensions so it reads back as no value.
                        final defaulted = <String>[];
                        if (lap.calories == null) defaulted.add('Calories');
                        builder.element(
                          'Calories',
                          nest: (lap.calories?.round() ?? 0).toString(),
                        );
                        void writeHr(String tag, double? value) {
                          // The schema's heart rate starts at 1 bpm.
                          if (value == null || value.round() < 1) return;
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
                        if (lap.tcxIntensity == null) {
                          defaulted.add('Intensity');
                        }
                        builder.element(
                          'Intensity',
                          nest: lap.tcxIntensity ?? 'Active',
                        );
                        if (lap.avgCadence != null) {
                          builder.element(
                            'Cadence',
                            nest: lap.avgCadence!.round().toString(),
                          );
                        }
                        if (lap.tcxTriggerMethod == null) {
                          defaulted.add('TriggerMethod');
                        }
                        builder.element(
                          'TriggerMethod',
                          nest: lap.tcxTriggerMethod ?? 'Manual',
                        );
                        final lapPoints = [
                          for (final p in points)
                            if ((effectiveStart == null ||
                                    !p.time.isBefore(effectiveStart)) &&
                                (effectiveEnd == null ||
                                    !p.time.isAfter(effectiveEnd)) &&
                                !writtenPoints.contains(p))
                              p,
                        ];
                        // A <Track> needs a trackpoint; a lap without one
                        // has no <Track>, which the schema allows.
                        if (lapPoints.isNotEmpty) {
                          builder.element(
                            'Track',
                            nest: () {
                              var cumulativeDistance = 0.0;
                              GeoPoint? previous;
                              for (final point in lapPoints) {
                                writtenPoints.add(point);
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
                                    final step = haversineMeters(prev, point);
                                    // Coordinates far outside their range give
                                    // no usable distance; skip that step.
                                    if (step.isFinite) {
                                      cumulativeDistance += step;
                                    }
                                  }
                                }
                                previous = point;
                                builder.element(
                                  'Trackpoint',
                                  nest: () {
                                    builder.element(
                                      'Time',
                                      nest: point.time
                                          .toUtc()
                                          .toIso8601String(),
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
                                      nest: cumulativeDistance.toStringAsFixed(
                                        1,
                                      ),
                                    );
                                    // The schema's heart rate starts at 1 bpm.
                                    if (hr != null && hr.round() >= 1) {
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
                                                  nest: speed.toStringAsFixed(
                                                    3,
                                                  ),
                                                );
                                              }
                                              if (watts != null) {
                                                builder.element(
                                                  'ns3:Watts',
                                                  nest: watts
                                                      .round()
                                                      .toString(),
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
                        }
                        // LX lap extensions (ActivityExtension/v2) carry lap
                        // power and speed stats the base schema cannot hold.
                        final hasLx =
                            lap.avgSpeed != null ||
                            lap.maxCadence != null ||
                            lap.avgPower != null ||
                            lap.maxPower != null;
                        if (hasLx || defaulted.isNotEmpty) {
                          builder.element(
                            'Extensions',
                            nest: () {
                              if (defaulted.isNotEmpty) {
                                builder.element(
                                  tcxDefaultedFieldsElement,
                                  attributes: {'xmlns': libraryNamespace},
                                  nest: defaulted.join(' '),
                                );
                              }
                              if (!hasLx) return;
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
                  // Notes, creator and file-level extensions belong to the
                  // file, so emit them only on the first activity, in schema
                  // order: Notes, Creator, Extensions.
                  if (groupIndex == 0) {
                    final notes = activity.tcxNotes;
                    if (notes != null && notes.trim().isNotEmpty) {
                      builder.element('Notes', nest: notes.trim());
                    }
                    final device = activity.device;
                    final creatorLabel = activity.creator?.trim();
                    final creator = _tcxDeviceCreator(device, creatorLabel);
                    if (creator != null) {
                      builder.element(
                        'Creator',
                        attributes: const {'xsi:type': 'Device_t'},
                        nest: () {
                          builder.element('Name', nest: creator.name);
                          builder.element('UnitId', nest: '${creator.unitId}');
                          builder.element(
                            'ProductID',
                            nest: '${creator.productId}',
                          );
                          builder.element(
                            'Version',
                            nest: () {
                              final version = creator.version;
                              builder.element(
                                'VersionMajor',
                                nest: '${version[0]}',
                              );
                              builder.element(
                                'VersionMinor',
                                nest: '${version[1]}',
                              );
                              if (version.length > 2) {
                                builder.element(
                                  'BuildMajor',
                                  nest: '${version[2]}',
                                );
                              }
                              if (version.length > 3) {
                                builder.element(
                                  'BuildMinor',
                                  nest: '${version[3]}',
                                );
                              }
                            },
                          );
                        },
                      );
                    }
                    // Device_t has no manufacturer and a bare label fits no
                    // creator type, so both always go into the extensions
                    // too, where the parser reads them first.
                    final hasDevice = device != null && device.isNotEmpty;
                    final hasLabel =
                        creatorLabel != null && creatorLabel.isNotEmpty;
                    if (hasDevice ||
                        hasLabel ||
                        metadataExtensions.isNotEmpty ||
                        trackExtensions.isNotEmpty) {
                      builder.element(
                        'Extensions',
                        nest: () {
                          if (hasDevice) writeLibraryDevice(builder, device);
                          if (hasLabel) {
                            builder.element(
                              'creator',
                              attributes: const {'xmlns': libraryNamespace},
                              nest: creatorLabel,
                            );
                          }
                          for (final extension in metadataExtensions) {
                            _writeExtensionNode(
                              builder,
                              extension,
                              prefixRemap: extensionPrefixRemap,
                            );
                          }
                          // A <Track> holds only trackpoints, so a track's
                          // extensions are kept here, in the library's own
                          // wrapper.
                          if (trackExtensions.isNotEmpty) {
                            builder.element(
                              'trackExtensions',
                              attributes: const {'xmlns': libraryNamespace},
                              nest: () {
                                for (final extension in trackExtensions) {
                                  _writeExtensionNode(
                                    builder,
                                    extension,
                                    prefixRemap: extensionPrefixRemap,
                                  );
                                }
                              },
                            );
                          }
                        },
                      );
                    }
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
    _ => 'Other',
  };
}

bool _isSortedByStart(List<Lap> laps) {
  for (var i = 1; i < laps.length; i++) {
    if (laps[i].startTime.isBefore(laps[i - 1].startTime)) return false;
  }
  return true;
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

/// [prevLapEnd] is the chronologically previous lap's endTime across the
/// *whole* activity (null only when this is the very first lap overall);
/// widens the boundary halfway into a gap so a point sitting between two
/// laps still lands in one of them, or leaves it unbounded (null) when
/// there's truly no earlier lap to bound against.
///
/// The widened start sits one microsecond past the midpoint that
/// [_lapEffectiveEnd] hands the previous lap, so a point landing exactly on
/// the midpoint belongs to the earlier lap alone. Both windows are
/// inclusive, and `writtenPointTimes` only dedupes within one `<Activity>`,
/// so sharing that instant would write the point into both sports' tracks
/// when the gap straddles a sport change. A lap whose start already equals
/// or precedes [prevLapEnd] keeps its own start: overlapping laps are
/// deduped within the group, and the shared instant of two *touching* laps
/// is deliberately written to both sports (a transition point belongs to
/// each).
DateTime? _lapEffectiveStart(DateTime start, DateTime? prevLapEnd) {
  if (prevLapEnd == null) return null;
  if (prevLapEnd.isBefore(start)) {
    return prevLapEnd
        .add(start.difference(prevLapEnd) ~/ 2)
        .add(const Duration(microseconds: 1));
  }
  return start;
}

/// See [_lapEffectiveStart]; [nextLapStart] is likewise the whole
/// activity's next lap, not just this `<Activity>` group's.
DateTime? _lapEffectiveEnd(DateTime end, DateTime? nextLapStart) {
  if (nextLapStart == null) return null;
  if (end.isBefore(nextLapStart)) {
    return end.add(nextLapStart.difference(end) ~/ 2);
  }
  return end;
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
    registry[prefix] = extensionNamespaceForExport(uri);
  }
  for (final child in node.children) {
    _collectExtensionNamespaces(child, registry);
  }
}

void _writeExtensionNode(
  XmlBuilder builder,
  GpxExtensionNode node, {
  Map<String, String> prefixRemap = const {},
}) {
  final prefix = prefixRemap[node.namespacePrefix] ?? node.namespacePrefix;
  final qualified = prefix != null ? '$prefix:${node.name}' : node.name;
  builder.element(
    qualified,
    attributes: node.attributes,
    nest: () {
      if (node.value != null) {
        builder.text(node.value!);
      }
      for (final child in node.children) {
        _writeExtensionNode(builder, child, prefixRemap: prefixRemap);
      }
    },
  );
}

/// The `<Creator xsi:type="Device_t">` fields, or null unless all four are
/// known: the schema requires Name, UnitId, ProductID and Version, and none
/// is invented.
({String name, int unitId, int productId, List<int> version})?
_tcxDeviceCreator(ActivityDeviceMetadata? device, String? creatorLabel) {
  if (device == null) return null;
  final name = (creatorLabel != null && creatorLabel.isNotEmpty)
      ? creatorLabel
      : device.model?.trim();
  final unitId = int.tryParse(device.serialNumber?.trim() ?? '');
  final productId =
      int.tryParse(device.product?.trim() ?? '') ?? device.fitProductId;
  final versionText = device.softwareVersion?.trim();
  if (name == null ||
      name.isEmpty ||
      unitId == null ||
      unitId < 0 ||
      unitId > 0xFFFFFFFF ||
      productId == null ||
      productId < 0 ||
      productId > 0xFFFF ||
      versionText == null) {
    return null;
  }
  // "major.minor" with an optional "+buildMajor.buildMinor".
  final parts = versionText.split('+');
  final numbers = [
    for (final part in [
      ...parts.first.split('.'),
      if (parts.length > 1) ...parts[1].split('.'),
    ])
      int.tryParse(part),
  ];
  if (parts.length > 2 ||
      parts.first.split('.').length != 2 ||
      numbers.length < 2 ||
      numbers.length > 4 ||
      numbers.any((n) => n == null || n < 0 || n > 0xFFFF)) {
    return null;
  }
  return (
    name: name,
    unitId: unitId,
    productId: productId,
    version: numbers.cast<int>(),
  );
}
