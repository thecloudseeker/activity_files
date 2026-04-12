// SPDX-License-Identifier: BSD-3-Clause
import 'dart:math' as math;
import 'package:xml/xml.dart';
import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

/// Parser for the GPX file format.
// TODO(0.7.0): GPX: Implement round-trip preservation for waypoints/routes/metadata and multiple tracks.
class GpxParser implements ActivityFormatParser {
  const GpxParser();

  static final _gpxSportCache = <String, Sport>{};
  static const _gpxSportMap = {
    'running': Sport.running,
    'cycling': Sport.cycling,
    'biking': Sport.cycling,
    'bike': Sport.cycling,
    'swimming': Sport.swimming,
    'hiking': Sport.hiking,
    'walking': Sport.walking,
    'other': Sport.other,
  };
  @override
  ActivityParseResult parse(String input) {
    // For large files, we could add event-based parsing here in the future
    // Current threshold: files > 1MB might benefit from streaming
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
    final metadataElement = root.getElement('metadata');
    if (metadataElement != null) {
      metadataName = _firstText(metadataElement, 'name') ?? metadataName;
      metadataDescription =
          _firstText(metadataElement, 'desc') ?? metadataDescription;
      for (final child in metadataElement.childElements) {
        if (child.name.local == 'extensions') {
          metadataExtensions.addAll(_extensionChildrenToNodes(child));
        }
      }
    }
    for (final child in root.childElements) {
      if (child.name.local == 'extensions') {
        metadataExtensions.addAll(_extensionChildrenToNodes(child));
      }
    }
    final points = <GeoPoint>[];
    final hrSamples = <Sample>[];
    final cadenceSamples = <Sample>[];
    final powerSamples = <Sample>[];
    final temperatureSamples = <Sample>[];
    final waterTemperatureSamples = <Sample>[];
    final depthSamples = <Sample>[];
    final speedSamples = <Sample>[];
    final courseSamples = <Sample>[];
    final bearingSamples = <Sample>[];
    final laps = <Lap>[];
    final trackExtensions = <GpxExtensionNode>[];
    String? trackName;
    String? trackDescription;
    String? trackType;
    var sport = Sport.unknown;

    // Direct iteration instead of .where() to avoid creating iterables
    for (final trk in root.childElements) {
      if (trk.name.local != 'trk') continue;

      // Batch lookup for track metadata to avoid repeated scans
      if (trackName == null || trackDescription == null || trackType == null) {
        final trackTexts = _batchTrackTexts(trk);
        trackName ??= trackTexts['name'];
        trackDescription ??= trackTexts['desc'];
        trackType ??= trackTexts['type'];
        final typeText = trackTexts['type'];
        if (typeText != null && typeText.trim().isNotEmpty) {
          sport = _sportFromString(typeText);
        }
      }
      for (final child in trk.childElements) {
        if (child.name.local == 'extensions') {
          trackExtensions.addAll(_extensionChildrenToNodes(child));
        }
      }

      // Direct iteration for track segments
      for (final trkseg in trk.childElements) {
        if (trkseg.name.local != 'trkseg') continue;

        DateTime? segmentStart;
        DateTime? segmentEnd;
        var segmentDistance = 0.0;
        GeoPoint? previous;
        var index = 0;

        // Direct iteration for trackpoints
        for (final trkpt in trkseg.childElements) {
          if (trkpt.name.local != 'trkpt') continue;

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

          // Parse child elements in one pass for efficiency
          String? timeText;
          String? eleText;
          final extensionNodes = <XmlElement>[];

          for (final child in trkpt.childElements) {
            switch (child.name.local) {
              case 'time':
                timeText ??= child.innerText.trim();
                break;
              case 'ele':
                eleText ??= child.innerText.trim();
                break;
              case 'extensions':
                extensionNodes.add(child);
                break;
            }
          }

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

          // Parse extensions efficiently (already collected in first pass)
          for (final extChild in extensionNodes) {
            for (final tpext in extChild.childElements) {
              if (tpext.name.local == 'TrackPointExtension') {
                // Cache child elements for efficient access
                for (final child in tpext.childElements) {
                  final name = child.name.local;
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
                  // Use case-sensitive comparison (Garmin uses lowercase)
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
                    case 'wtemp':
                      waterTemperatureSamples.add(
                        Sample(time: time, value: parsed),
                      );
                      break;
                    case 'depth':
                      depthSamples.add(Sample(time: time, value: parsed));
                      break;
                    case 'speed':
                      speedSamples.add(Sample(time: time, value: parsed));
                      break;
                    case 'course':
                      courseSamples.add(Sample(time: time, value: parsed));
                      break;
                    case 'bearing':
                      bearingSamples.add(Sample(time: time, value: parsed));
                      break;
                    default:
                      // Unknown extension; ignore.
                      break;
                  }
                }
              }
            }
          }
        } // End of trkpt loop
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
    if (waterTemperatureSamples.isNotEmpty) {
      channelMap[Channel.waterTemperature] = waterTemperatureSamples;
    }
    if (depthSamples.isNotEmpty) {
      channelMap[Channel.depth] = depthSamples;
    }
    if (speedSamples.isNotEmpty) {
      channelMap[Channel.speed] = speedSamples;
    }
    if (courseSamples.isNotEmpty) {
      channelMap[Channel.course] = courseSamples;
    }
    if (bearingSamples.isNotEmpty) {
      channelMap[Channel.bearing] = bearingSamples;
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
    if (value.isEmpty) {
      return Sport.unknown;
    }

    // Check cache first
    final cached = GpxParser._gpxSportCache[value];
    if (cached != null) {
      return cached;
    }

    final normalized = value.trim().toLowerCase();
    final result = GpxParser._gpxSportMap[normalized] ?? Sport.unknown;

    // Cache for future lookups
    GpxParser._gpxSportCache[value] = result;

    return result;
  }
}

String? _firstText(XmlElement element, String localName) {
  // Direct case-sensitive lookup (XML is case-sensitive anyway)
  for (final child in element.childElements) {
    if (child.name.local == localName) {
      return child.innerText.isEmpty ? null : child.innerText.trim();
    }
  }
  return null;
}

/// Batch lookup for track metadata to avoid repeated element scans
Map<String, String?> _batchTrackTexts(XmlElement trackElement) {
  final texts = <String, String?>{};
  for (final child in trackElement.childElements) {
    final localName = child.name.local;
    if (localName == 'name' || localName == 'desc' || localName == 'type') {
      final trimmed = child.innerText.trim();
      texts[localName] = trimmed.isEmpty ? null : trimmed;
    }
  }
  return texts;
}

List<GpxExtensionNode> _extensionChildrenToNodes(XmlElement extensionsElement) {
  // Use childElements directly instead of children.whereType for efficiency
  final nodes = <GpxExtensionNode>[];
  for (final child in extensionsElement.childElements) {
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
  // Optimize text content extraction
  String? textContent;
  for (final child in element.children) {
    if (child is XmlText) {
      final trimmed = child.value.trim();
      if (trimmed.isNotEmpty) {
        textContent = (textContent ?? '') + trimmed;
      }
    }
  }
  return GpxExtensionNode(
    name: element.name.local,
    namespacePrefix: element.name.prefix,
    namespaceUri: element.name.namespaceUri,
    value: textContent,
    attributes: attributes,
    children: element.childElements.map(_extensionNodeFromXml),
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
