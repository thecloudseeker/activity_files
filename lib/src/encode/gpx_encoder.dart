// SPDX-License-Identifier: BSD-3-Clause
import 'package:xml/xml.dart';

import '../channel_mapper.dart';
import '../models.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';

/// Encoder for the GPX file format.
// TODO(0.7.0)(feature): Encode waypoints/routes and richer metadata (author/email/link/copyright/keywords/bounds).
// TODO(0.7.0)(feature): Support exporting multiple tracks/segments without flattening.
class GpxEncoder implements ActivityFormatEncoder {
  const GpxEncoder();
  @override
  String encode(RawActivity activity, EncoderOptions options) {
    final gpxVersion = options.gpxVersion;
    final emitGpx10 = gpxVersion == GpxVersion.v1_0;
    final points = [...activity.points]
      ..sort((a, b) => a.time.compareTo(b.time));
    String? normalizeText(String? value) {
      if (value == null) {
        return null;
      }
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
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
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    final gpxNamespace = emitGpx10
        ? 'http://www.topografix.com/GPX/1/0'
        : 'http://www.topografix.com/GPX/1/1';
    final gpxSchemaLocation = emitGpx10
        ? 'http://www.topografix.com/GPX/1/0 '
              'http://www.topografix.com/GPX/1/0/gpx.xsd '
              'http://www.garmin.com/xmlschemas/TrackPointExtension/v1 '
              'http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd'
        : 'http://www.topografix.com/GPX/1/1 '
              'http://www.topografix.com/GPX/1/1/gpx.xsd '
              'http://www.garmin.com/xmlschemas/TrackPointExtension/v1 '
              'http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd';
    final rootAttributes = <String, String>{
      'creator': activity.creator ?? 'activity_files',
      'version': emitGpx10 ? '1.0' : '1.1',
      'xmlns': gpxNamespace,
      'xmlns:xsi': 'http://www.w3.org/2001/XMLSchema-instance',
      'xmlns:gpxtpx': 'http://www.garmin.com/xmlschemas/TrackPointExtension/v1',
      'xsi:schemaLocation': gpxSchemaLocation,
    };
    namespaceRegistry.forEach((prefix, uri) {
      final key = 'xmlns:$prefix';
      rootAttributes.putIfAbsent(key, () => uri);
    });
    builder.element(
      'gpx',
      attributes: rootAttributes,
      nest: () {
        final includeMetadata =
            points.isNotEmpty ||
            activity.creator != null ||
            normalizeText(activity.gpxMetadataName) != null ||
            normalizeText(activity.gpxMetadataDescription) != null ||
            (activity.device?.isNotEmpty ?? false) ||
            metadataExtensions.isNotEmpty;
        if (includeMetadata) {
          // TODO(0.6.0)(feature): Derive metadata time from channels/laps when
          // no points exist instead of falling back to `DateTime.now()`.
          final start = points.isNotEmpty
              ? points.first.time.toUtc()
              : DateTime.now().toUtc();
          final metadataName = normalizeText(activity.gpxMetadataName);
          final metadataDescription = normalizeText(
            activity.gpxMetadataDescription ??
                (activity.gpxIncludeCreatorMetadataDescription
                    ? activity.creator
                    : null),
          );
          final hasDevice = activity.device?.isNotEmpty ?? false;
          if (emitGpx10) {
            if (metadataName != null) {
              builder.element('name', nest: metadataName);
            }
            if (metadataDescription != null) {
              builder.element('desc', nest: metadataDescription);
            }
            builder.element('time', nest: start.toIso8601String());
            if (hasDevice || metadataExtensions.isNotEmpty) {
              builder.element(
                'extensions',
                nest: () {
                  if (hasDevice && activity.device != null) {
                    _writeDeviceExtension(builder, activity.device!);
                  }
                  for (final extension in metadataExtensions) {
                    _writeExtensionNode(builder, extension);
                  }
                },
              );
            }
          } else {
            builder.element(
              'metadata',
              nest: () {
                builder.element('time', nest: start.toIso8601String());
                if (metadataName != null) {
                  builder.element('name', nest: metadataName);
                }
                if (metadataDescription != null) {
                  builder.element('desc', nest: metadataDescription);
                }
                if (hasDevice || metadataExtensions.isNotEmpty) {
                  builder.element(
                    'extensions',
                    nest: () {
                      if (hasDevice && activity.device != null) {
                        _writeDeviceExtension(builder, activity.device!);
                      }
                      for (final extension in metadataExtensions) {
                        _writeExtensionNode(builder, extension);
                      }
                    },
                  );
                }
              },
            );
          }
        }
        final hrDelta = options.maxDeltaFor(Channel.heartRate);
        final cadenceDelta = options.maxDeltaFor(Channel.cadence);
        final powerDelta = options.maxDeltaFor(Channel.power);
        final tempDelta = options.maxDeltaFor(Channel.temperature);
        final speedDelta = options.maxDeltaFor(Channel.speed);
        final searchDelta =
            [
              hrDelta,
              cadenceDelta,
              powerDelta,
              tempDelta,
              speedDelta,
              options.defaultMaxDelta,
            ].nonNulls.fold<Duration>(
              options.defaultMaxDelta,
              (previous, current) => current > previous ? current : previous,
            );
        final channelCursor = ChannelMapper.cursor(
          activity.channels,
          maxDelta: searchDelta,
        );
        builder.element(
          'trk',
          nest: () {
            final trackName =
                normalizeText(activity.gpxTrackName) ??
                normalizeText(activity.gpxMetadataName) ??
                normalizeText(activity.creator) ??
                'Workout';
            builder.element('name', nest: trackName);
            final trackDescription = normalizeText(
              activity.gpxTrackDescription,
            );
            if (trackDescription != null) {
              builder.element('desc', nest: trackDescription);
            }
            final trackType =
                normalizeText(activity.gpxTrackType) ??
                _sportLabel(activity.sport);
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
            builder.element(
              'trkseg',
              nest: () {
                for (final point in points) {
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
                  final power = _valueWithin(
                    snapshot.power,
                    snapshot.powerDelta,
                    powerDelta,
                  );
                  final temperature = _valueWithin(
                    snapshot.temperature,
                    snapshot.temperatureDelta,
                    tempDelta,
                  );
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
                      if (hr != null ||
                          cadence != null ||
                          power != null ||
                          temperature != null) {
                        builder.element(
                          'extensions',
                          nest: () {
                            builder.element(
                              'gpxtpx:TrackPointExtension',
                              nest: () {
                                if (hr != null) {
                                  builder.element(
                                    'gpxtpx:hr',
                                    nest: hr.round().toString(),
                                  );
                                }
                                if (cadence != null) {
                                  builder.element(
                                    'gpxtpx:cad',
                                    nest: cadence.round().toString(),
                                  );
                                }
                                if (power != null) {
                                  builder.element(
                                    'gpxtpx:power',
                                    nest: power.round().toString(),
                                  );
                                }
                                if (temperature != null) {
                                  builder.element(
                                    'gpxtpx:atemp',
                                    nest: temperature.round().toString(),
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
          },
        );
      },
    );
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
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
    if (value == null) {
      return;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
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
