// SPDX-License-Identifier: BSD-3-Clause
import 'dart:math' as math;
import 'package:xml/xml.dart';
import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

/// Parser for the GPX file format.
// TODO(0.7.0)(feature): Preserve waypoints/routes instead of discarding them during parsing.
// TODO(0.7.0)(feature): Capture rich metadata (author/email/link/copyright/keywords/bounds).
// TODO(0.7.0)(feature): Keep multiple tracks/segments distinct instead of flattening into one stream.
class GpxParser implements ActivityFormatParser {
  const GpxParser();
  @override
  ActivityParseResult parse(String input) {
    final diagnostics = <ParseDiagnostic>[];
    XmlDocument document;
    try {
      document = XmlDocument.parse(input);
    } on XmlParserException catch (error) {
      final reason = error.message.trim();
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'gpx.parse.xml_error',
          message: 'Malformed GPX XML: $reason',
          node: const ParseNodeReference(path: 'gpx.document'),
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    } on FormatException catch (error) {
      final trimmed = error.message.trim();
      final reason = trimmed.isEmpty ? error.toString() : trimmed;
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'gpx.parse.format_error',
          message: 'Failed to parse GPX payload: $reason',
          node: const ParseNodeReference(path: 'gpx.document'),
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }
    final root = document.rootElement;
    final creator = root.getAttribute('creator');
    var metadataName = _firstText(root, 'name');
    var metadataDescription = _firstText(root, 'desc');
    final metadataExtensions = <GpxExtensionNode>[];
    // GPX 1.1 wraps metadata; GPX 1.0 keeps name/desc/time at the root.
    final metadataElement = root.childElements.firstWhere(
      (element) => element.name.local.toLowerCase() == 'metadata',
      orElse: () => XmlElement(XmlName('')),
    );
    if (metadataElement.name.local.isNotEmpty) {
      metadataName = _firstText(metadataElement, 'name') ?? metadataName;
      metadataDescription =
          _firstText(metadataElement, 'desc') ?? metadataDescription;
      for (final extensions in metadataElement.childElements.where(
        (e) => e.name.local.toLowerCase() == 'extensions',
      )) {
        metadataExtensions.addAll(_extensionChildrenToNodes(extensions));
      }
    }
    for (final extensions in root.childElements.where(
      (e) => e.name.local.toLowerCase() == 'extensions',
    )) {
      metadataExtensions.addAll(_extensionChildrenToNodes(extensions));
    }
    final points = <GeoPoint>[];
    final hrSamples = <Sample>[];
    final cadenceSamples = <Sample>[];
    final powerSamples = <Sample>[];
    final temperatureSamples = <Sample>[];
    final laps = <Lap>[];
    final trackExtensions = <GpxExtensionNode>[];
    String? trackName;
    String? trackDescription;
    String? trackType;
    var sport = Sport.unknown;
    for (final trk
        in root.findElements('*').where((e) => e.name.local == 'trk')) {
      trackName ??= _firstText(trk, 'name');
      trackDescription ??= _firstText(trk, 'desc');
      trackType ??= _firstText(trk, 'type');
      final typeText = _firstText(trk, 'type');
      if (typeText != null && typeText.trim().isNotEmpty) {
        sport = _sportFromString(typeText);
      }
      for (final extensions in trk.childElements.where(
        (e) => e.name.local.toLowerCase() == 'extensions',
      )) {
        trackExtensions.addAll(_extensionChildrenToNodes(extensions));
      }
      for (final trkseg
          in trk.findElements('*').where((e) => e.name.local == 'trkseg')) {
        DateTime? segmentStart;
        DateTime? segmentEnd;
        var segmentDistance = 0.0;
        GeoPoint? previous;
        var index = 0;
        for (final trkpt
            in trkseg.findElements('*').where((e) => e.name.local == 'trkpt')) {
          index++;
          final latText = trkpt.getAttribute('lat');
          final lonText = trkpt.getAttribute('lon');
          final lat = latText != null ? double.tryParse(latText) : null;
          final lon = lonText != null ? double.tryParse(lonText) : null;
          if (lat == null || lon == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'gpx.trackpoint.missing_coordinates',
                message:
                    'Skipping GPX trackpoint missing coordinates (index $index).',
                node: ParseNodeReference(
                  path: 'gpx.trk.trkseg.trkpt',
                  index: index - 1,
                ),
              ),
            );
            continue;
          }
          final timeText = _firstText(trkpt, 'time');
          if (timeText == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'gpx.trackpoint.missing_timestamp',
                message:
                    'Skipping GPX trackpoint without timestamp at $lat,$lon.',
                node: ParseNodeReference(
                  path: 'gpx.trk.trkseg.trkpt',
                  index: index - 1,
                  description: 'lat=$lat,lon=$lon',
                ),
              ),
            );
            continue;
          }
          DateTime? time;
          try {
            time = DateTime.parse(timeText).toUtc();
          } catch (_) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'gpx.trackpoint.invalid_timestamp',
                message: 'Invalid timestamp "$timeText"; trackpoint ignored.',
                node: ParseNodeReference(
                  path: 'gpx.trk.trkseg.trkpt',
                  index: index - 1,
                ),
              ),
            );
            continue;
          }
          final eleText = _firstText(trkpt, 'ele');
          final elevation = eleText != null ? double.tryParse(eleText) : null;
          if (eleText != null && elevation == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'gpx.trackpoint.invalid_elevation',
                message:
                    'Invalid elevation "$eleText" at $time; treating as null.',
                node: ParseNodeReference(
                  path: 'gpx.trk.trkseg.trkpt',
                  index: index - 1,
                  description: time.toIso8601String(),
                ),
              ),
            );
          }
          final point = GeoPoint(
            latitude: lat,
            longitude: lon,
            elevation: elevation,
            time: time,
          );
          points.add(point);
          segmentStart ??= time;
          segmentEnd = time;
          final prev = previous;
          if (prev != null) {
            segmentDistance += _haversine(prev, point);
          }
          previous = point;
          final extensionElements = trkpt
              .findElements('*')
              .where((e) => e.name.local.toLowerCase() == 'extensions')
              .expand(
                (ext) => ext.children.whereType<XmlElement>().where(
                  (element) =>
                      element.name.local.toLowerCase() == 'trackpointextension',
                ),
              );
          for (final ext in extensionElements) {
            for (final child in ext.childElements) {
              final name = child.name.local.toLowerCase();
              final valueText = child.innerText.trim();
              if (valueText.isEmpty) {
                continue;
              }
              final parsed = double.tryParse(valueText);
              if (parsed == null) {
                diagnostics.add(
                  ParseDiagnostic(
                    severity: ParseSeverity.warning,
                    code: 'gpx.extension.invalid_number',
                    message:
                        'Unparsable extension value "$valueText" for $name at $time.',
                    node: ParseNodeReference(
                      path: 'gpx.trk.trkseg.trkpt.extensions.$name',
                      index: index - 1,
                    ),
                  ),
                );
                continue;
              }
              switch (name) {
                case 'hr':
                  hrSamples.add(Sample(time: time, value: parsed));
                  break;
                case 'cad':
                case 'cadence':
                  cadenceSamples.add(Sample(time: time, value: parsed));
                  break;
                case 'power':
                  powerSamples.add(Sample(time: time, value: parsed));
                  break;
                case 'atemp':
                case 'temp':
                  temperatureSamples.add(Sample(time: time, value: parsed));
                  break;
                default:
                  // Unknown extension; ignore.
                  break;
              }
            }
          }
        }
        if (segmentStart != null && segmentEnd != null) {
          laps.add(
            Lap(
              startTime: segmentStart,
              endTime: segmentEnd,
              distanceMeters: segmentDistance > 0 ? segmentDistance : null,
              name: 'Segment ${laps.length + 1}',
            ),
          );
        }
      }
    }
    final channelMap = <Channel, Iterable<Sample>>{};
    if (hrSamples.isNotEmpty) {
      channelMap[Channel.heartRate] = hrSamples;
    }
    if (cadenceSamples.isNotEmpty) {
      channelMap[Channel.cadence] = cadenceSamples;
    }
    if (powerSamples.isNotEmpty) {
      channelMap[Channel.power] = powerSamples;
    }
    if (temperatureSamples.isNotEmpty) {
      channelMap[Channel.temperature] = temperatureSamples;
    }
    final activity = RawActivity(
      points: points,
      channels: channelMap,
      laps: laps,
      sport: sport,
      creator: creator,
      gpxMetadataName: metadataName,
      gpxMetadataDescription: metadataDescription,
      gpxMetadataExtensions: metadataExtensions,
      gpxTrackName: trackName,
      gpxTrackDescription: trackDescription,
      gpxTrackType: trackType,
      gpxTrackExtensions: trackExtensions,
    );
    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
  }

  Sport _sportFromString(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'running' => Sport.running,
      'cycling' || 'biking' || 'bike' => Sport.cycling,
      'swimming' => Sport.swimming,
      'hiking' => Sport.hiking,
      'walking' => Sport.walking,
      'other' => Sport.other,
      _ => Sport.unknown,
    };
  }
}

String? _firstText(XmlElement element, String localName) {
  for (final child in element.childElements) {
    if (child.name.local.toLowerCase() == localName.toLowerCase()) {
      return child.innerText.isEmpty ? null : child.innerText.trim();
    }
  }
  return null;
}

List<GpxExtensionNode> _extensionChildrenToNodes(XmlElement extensionsElement) {
  final nodes = <GpxExtensionNode>[];
  for (final child in extensionsElement.children.whereType<XmlElement>()) {
    nodes.add(_extensionNodeFromXml(child));
  }
  return nodes;
}

GpxExtensionNode _extensionNodeFromXml(XmlElement element) {
  final attributes = <String, String>{
    for (final attribute in element.attributes)
      attribute.name.prefix != null && attribute.name.prefix!.isNotEmpty
              ? '${attribute.name.prefix}:${attribute.name.local}'
              : attribute.name.local:
          attribute.value,
  };
  final textContent = element.children
      .whereType<XmlText>()
      .map((node) => node.value.trim())
      .where((value) => value.isNotEmpty)
      .join();
  return GpxExtensionNode(
    name: element.name.local,
    namespacePrefix: element.name.prefix,
    namespaceUri: element.name.namespaceUri,
    value: textContent.isEmpty ? null : textContent,
    attributes: attributes,
    children: element.children.whereType<XmlElement>().map(
      _extensionNodeFromXml,
    ),
  );
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
