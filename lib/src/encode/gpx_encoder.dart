// SPDX-License-Identifier: BSD-3-Clause
import 'package:xml/xml.dart';

import '../channel_mapper.dart';
import '../models.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';

/// Encoder for the GPX file format.
class GpxEncoder implements ActivityFormatEncoder {
  const GpxEncoder();
  @override
  String encode(RawActivity activity, EncoderOptions options) {
    final emitGpx10 = options.gpxVersion == GpxVersion.v1_0;
    final points = [...activity.points]
      ..sort((a, b) => a.time.compareTo(b.time));

    final metadataExtensions = activity.gpxMetadataExtensions;
    final tracks = [activity, ...activity.additionalTracks];
    final namespaceRegistry = <String, String>{};
    for (final extension in [
      ...metadataExtensions,
      for (final track in tracks) ...track.gpxTrackExtensions,
      for (final track in tracks)
        for (final point in track.points) ...?point.gpxExtensions,
    ]) {
      _collectExtensionNamespaces(extension, namespaceRegistry);
    }
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    final gpxNamespace = emitGpx10
        ? 'http://www.topografix.com/GPX/1/0'
        : 'http://www.topografix.com/GPX/1/1';
    final gpxSchemaLocation =
        '$gpxNamespace '
        '$gpxNamespace/gpx.xsd '
        'http://www.garmin.com/xmlschemas/TrackPointExtension/v2 '
        'http://www8.garmin.com/xmlschemas/TrackPointExtensionv2.xsd';
    final rootAttributes = <String, String>{
      'creator': activity.creator ?? 'activity_files',
      'version': emitGpx10 ? '1.0' : '1.1',
      'xmlns': gpxNamespace,
      'xmlns:xsi': 'http://www.w3.org/2001/XMLSchema-instance',
      'xmlns:gpxtpx': 'http://www.garmin.com/xmlschemas/TrackPointExtension/v2',
      'xsi:schemaLocation': gpxSchemaLocation,
    };
    namespaceRegistry.forEach(
      (prefix, uri) => rootAttributes.putIfAbsent('xmlns:$prefix', () => uri),
    );
    final deltas = <Channel, Duration>{
      for (final field in _tpxFields)
        field.channel: options.maxDeltaFor(field.channel),
    };
    final searchDelta = deltas.values.fold<Duration>(
      options.defaultMaxDelta,
      (previous, current) => current > previous ? current : previous,
    );
    builder.element(
      'gpx',
      attributes: rootAttributes,
      nest: () {
        final includeMetadata =
            points.isNotEmpty ||
            activity.creator != null ||
            _normalizeText(activity.gpxMetadataName) != null ||
            _normalizeText(activity.gpxMetadataDescription) != null ||
            (activity.device?.isNotEmpty ?? false) ||
            metadataExtensions.isNotEmpty;
        if (includeMetadata) {
          // Channel mapping validated at parse time by channel_mapper.dart
          final start = points.isNotEmpty
              ? points.first.time.toUtc()
              : DateTime.now().toUtc();
          final metadataName = _normalizeText(activity.gpxMetadataName);
          final metadataDescription = _normalizeText(
            activity.gpxMetadataDescription ??
                (activity.gpxIncludeCreatorMetadataDescription
                    ? activity.creator
                    : null),
          );
          final device = activity.device;
          final hasDevice = device?.isNotEmpty ?? false;
          void writeNameAndDescription() {
            if (metadataName != null) {
              builder.element('name', nest: metadataName);
            }
            if (metadataDescription != null) {
              builder.element('desc', nest: metadataDescription);
            }
          }

          void writeExtensionsBlock() {
            if (!hasDevice && metadataExtensions.isEmpty) {
              return;
            }
            builder.element(
              'extensions',
              nest: () {
                if (hasDevice) {
                  _writeDeviceExtension(builder, device!);
                }
                for (final extension in metadataExtensions) {
                  _writeExtensionNode(builder, extension);
                }
              },
            );
          }

          if (emitGpx10) {
            // GPX 1.0 places metadata fields directly under the root element.
            writeNameAndDescription();
            builder.element('time', nest: start.toIso8601String());
            writeExtensionsBlock();
          } else {
            builder.element(
              'metadata',
              nest: () {
                builder.element('time', nest: start.toIso8601String());
                writeNameAndDescription();
                writeExtensionsBlock();
              },
            );
          }
        }
        // Standalone waypoints and routes precede tracks in the GPX schema.
        for (final waypoint in activity.gpxWaypoints) {
          _writeWaypointElement(builder, 'wpt', waypoint, options);
        }
        for (final route in activity.gpxRoutes) {
          _writeRoute(builder, route, options);
        }
        for (final (index, track) in tracks.indexed) {
          _writeTrack(
            builder: builder,
            // The primary activity's points are already sorted above.
            points: index == 0
                ? points
                : ([...track.points]..sort((a, b) => a.time.compareTo(b.time))),
            channelCursor: ChannelMapper.cursor(
              track.channels,
              maxDelta: searchDelta,
            ),
            segmentStarts: track.gpxTrackSegments,
            trackName:
                _normalizeText(track.gpxTrackName) ??
                _normalizeText(track.gpxMetadataName) ??
                _normalizeText(track.creator) ??
                (index == 0 ? 'Workout' : 'Track'),
            trackDescription: _normalizeText(track.gpxTrackDescription),
            trackType:
                _normalizeText(track.gpxTrackType) ?? _sportLabel(track.sport),
            trackExtensions: track.gpxTrackExtensions,
            options: options,
            deltas: deltas,
          );
        }
      },
    );
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  void _writeTrack({
    required XmlBuilder builder,
    required List<GeoPoint> points,
    required ChannelCursor channelCursor,
    required String trackName,
    required String? trackDescription,
    required String trackType,
    required List<GpxExtensionNode> trackExtensions,
    required List<int> segmentStarts,
    required EncoderOptions options,
    required Map<Channel, Duration> deltas,
  }) {
    builder.element(
      'trk',
      nest: () {
        builder.element('name', nest: trackName);
        if (trackDescription != null) {
          builder.element('desc', nest: trackDescription);
        }
        builder.element('type', nest: trackType);
        if (trackExtensions.isNotEmpty) {
          builder.element(
            'extensions',
            nest: () {
              for (final extension in trackExtensions) {
                _writeExtensionNode(builder, extension);
              }
            },
          );
        }
        for (final (segStart, segEnd) in _segmentRanges(
          points.length,
          segmentStarts,
        )) {
          builder.element(
            'trkseg',
            nest: () {
              for (
                var pointIndex = segStart;
                pointIndex < segEnd;
                pointIndex++
              ) {
                final point = points[pointIndex];
                final snapshot = channelCursor.snapshot(point.time);
                final tpxValues = [
                  for (final field in _tpxFields)
                    if (_valueWithin(
                          snapshot.valueFor(field.channel),
                          snapshot.deltaFor(field.channel),
                          deltas[field.channel]!,
                        )
                        case final double value)
                      (tag: field.tag, text: field.format(value, options)),
                ];
                builder.element(
                  'trkpt',
                  attributes: {
                    'lat': _round(point.latitude, options.precisionLatLon),
                    'lon': _round(point.longitude, options.precisionLatLon),
                  },
                  nest: () {
                    if (point.elevation != null) {
                      builder.element(
                        'ele',
                        nest: _round(point.elevation!, options.precisionEle),
                      );
                    }
                    builder.element(
                      'time',
                      nest: point.time.toUtc().toIso8601String(),
                    );
                    _writeGpxAttributes(builder, point.gpxAttributes);
                    final pointExtensions = point.gpxExtensions;
                    final hasPointExtensions =
                        pointExtensions != null && pointExtensions.isNotEmpty;
                    if (tpxValues.isNotEmpty || hasPointExtensions) {
                      builder.element(
                        'extensions',
                        nest: () {
                          if (tpxValues.isNotEmpty) {
                            builder.element(
                              'gpxtpx:TrackPointExtension',
                              nest: () {
                                for (final entry in tpxValues) {
                                  builder.element(entry.tag, nest: entry.text);
                                }
                              },
                            );
                          }
                          // Preserved point-level extension elements from the
                          // source file (lossless round-trip).
                          if (hasPointExtensions) {
                            for (final extension in pointExtensions) {
                              _writeExtensionNode(builder, extension);
                            }
                          }
                        },
                      );
                    }
                  },
                );
              }
            },
          );
        }
      },
    );
  }

  /// Writes a `<wpt>` or `<rtept>` element from a [GeoPoint], re-emitting its
  /// standard child elements (from [GeoPoint.gpxAttributes]) and foreign
  /// extensions. Time is only written when the point carries a real one.
  void _writeWaypointElement(
    XmlBuilder builder,
    String tag,
    GeoPoint point,
    EncoderOptions options,
  ) {
    builder.element(
      tag,
      attributes: {
        'lat': _round(point.latitude, options.precisionLatLon),
        'lon': _round(point.longitude, options.precisionLatLon),
      },
      nest: () {
        if (point.elevation != null) {
          builder.element(
            'ele',
            nest: _round(point.elevation!, options.precisionEle),
          );
        }
        if (point.time.millisecondsSinceEpoch != 0) {
          builder.element('time', nest: point.time.toUtc().toIso8601String());
        }
        _writeGpxAttributes(builder, point.gpxAttributes);
        final extensions = point.gpxExtensions;
        if (extensions != null && extensions.isNotEmpty) {
          builder.element(
            'extensions',
            nest: () {
              for (final extension in extensions) {
                _writeExtensionNode(builder, extension);
              }
            },
          );
        }
      },
    );
  }

  void _writeRoute(XmlBuilder builder, GpxRoute route, EncoderOptions options) {
    builder.element(
      'rte',
      nest: () {
        final name = _normalizeText(route.name);
        if (name != null) {
          builder.element('name', nest: name);
        }
        for (final key in _routeElementOrder) {
          final value = route.metadata[key];
          if (value != null) builder.element(key, nest: value);
        }
        for (final point in route.points) {
          _writeWaypointElement(builder, 'rtept', point, options);
        }
      },
    );
  }

  String _sportLabel(Sport sport) => switch (sport) {
    Sport.running => 'Running',
    Sport.cycling => 'Cycling',
    Sport.swimming => 'Swimming',
    Sport.hiking => 'Hiking',
    Sport.walking => 'Walking',
    Sport.other => 'Other',
    Sport.unknown => 'Unknown',
  };
}

/// Standard GPX point child elements in schema order (excluding ele/time/
/// extensions, which are written separately).
const List<String> _gpxPointElementOrder = [
  'magvar',
  'geoidheight',
  'name',
  'cmt',
  'desc',
  'src',
  'sym',
  'type',
  'fix',
  'sat',
  'hdop',
  'vdop',
  'pdop',
  'ageofdgpsdata',
  'dgpsid',
];

/// Standard `<rte>` child elements (excluding name/rtept/extensions) in order.
const List<String> _routeElementOrder = [
  'cmt',
  'desc',
  'src',
  'number',
  'type',
];

/// Writes preserved standard GPX point child elements in schema order.
void _writeGpxAttributes(XmlBuilder builder, Map<String, String>? attributes) {
  if (attributes == null || attributes.isEmpty) return;
  for (final name in _gpxPointElementOrder) {
    final value = attributes[name];
    if (value != null) builder.element(name, nest: value);
  }
}

/// Returns `[start, end)` point index ranges for each track segment. Fewer
/// than two boundaries means a single segment spanning all points.
List<(int, int)> _segmentRanges(int count, List<int> starts) {
  if (count == 0) return const [];
  if (starts.length < 2) return [(0, count)];
  final ranges = <(int, int)>[];
  for (var i = 0; i < starts.length; i++) {
    final begin = starts[i].clamp(0, count);
    final end = i + 1 < starts.length ? starts[i + 1].clamp(0, count) : count;
    if (end > begin) ranges.add((begin, end));
  }
  return ranges.isEmpty ? [(0, count)] : ranges;
}

/// TrackPointExtension fields in schema order.
const List<_TpxField> _tpxFields = [
  _TpxField(Channel.heartRate, 'gpxtpx:hr', _formatWhole),
  _TpxField(Channel.cadence, 'gpxtpx:cad', _formatWhole),
  _TpxField(Channel.power, 'gpxtpx:power', _formatWhole),
  // The schema's DegreesCelsius_t is xsd:decimal — rounding temperatures to
  // whole numbers (as hr/cad's unsignedByte types require) would corrupt
  // fractional readings like 18.5 °C.
  _TpxField(Channel.temperature, 'gpxtpx:atemp', _formatTemperature),
  _TpxField(Channel.waterTemperature, 'gpxtpx:wtemp', _formatTemperature),
  _TpxField(Channel.depth, 'gpxtpx:depth', _formatElevation),
  _TpxField(Channel.speed, 'gpxtpx:speed', _formatSpeed),
  _TpxField(Channel.course, 'gpxtpx:course', _formatHeading),
  _TpxField(Channel.bearing, 'gpxtpx:bearing', _formatHeading),
];

class _TpxField {
  const _TpxField(this.channel, this.tag, this.format);
  final Channel channel;
  final String tag;
  final String Function(double value, EncoderOptions options) format;
}

String _formatWhole(double value, EncoderOptions _) => value.round().toString();
String _formatTemperature(double value, EncoderOptions _) => _round(value, 1);
String _formatElevation(double value, EncoderOptions options) =>
    _round(value, options.precisionEle);
String _formatSpeed(double value, EncoderOptions _) => _round(value, 2);
String _formatHeading(double value, EncoderOptions _) => _round(value, 1);

String? _normalizeText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
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

void _writeDeviceExtension(XmlBuilder builder, ActivityDeviceMetadata device) {
  if (device.isEmpty) {
    return;
  }
  void writeTag(String? value, String tag) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return;
    }
    builder.element(tag, nest: trimmed);
  }

  builder.element(
    'device',
    nest: () {
      writeTag(device.manufacturer, 'manufacturer');
      writeTag(device.model, 'model');
      writeTag(device.product, 'product');
      writeTag(device.serialNumber, 'serialNumber');
      writeTag(device.softwareVersion, 'softwareVersion');
    },
  );
}
