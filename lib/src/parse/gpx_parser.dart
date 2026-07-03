// SPDX-License-Identifier: BSD-3-Clause
import '../geo_math.dart';
import 'package:xml/xml.dart';
import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

/// Parser for the GPX file format.
class GpxParser implements ActivityFormatParser {
  const GpxParser();

  /// Standard GPX point child elements (per the GPX schema) that have no
  /// dedicated [GeoPoint] field and are preserved raw in
  /// [GeoPoint.gpxAttributes] — GPS quality/fix data and waypoint metadata.
  static const Set<String> _pointAttributeElements = {
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
  };

  /// TrackPointExtension tag names mapped to channels (Garmin schema).
  static const Map<String, Channel> _tpxTagToChannel = {
    'hr': Channel.heartRate,
    'cad': Channel.cadence,
    'cadence': Channel.cadence,
    'power': Channel.power,
    'atemp': Channel.temperature,
    'temp': Channel.temperature,
    'wtemp': Channel.waterTemperature,
    'depth': Channel.depth,
    'speed': Channel.speed,
    'course': Channel.course,
    'bearing': Channel.bearing,
  };

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
    // Parse each <trk> element independently so that multi-track files can be
    // round-tripped without structural loss.
    final parsedTracks = <_GpxTrackData>[];
    var overallSport = Sport.unknown;

    for (final trk in root.childElements) {
      if (trk.name.local != 'trk') continue;

      final trackTexts = _batchTrackTexts(trk);
      final trkName = trackTexts['name'];
      final trkDesc = trackTexts['desc'];
      final trkType = trackTexts['type'];
      var trkSport = Sport.unknown;
      if (trkType != null && trkType.trim().isNotEmpty) {
        trkSport = _sportFromString(trkType);
      }

      final trkExtensions = <GpxExtensionNode>[];
      for (final child in trk.childElements) {
        if (child.name.local == 'extensions') {
          trkExtensions.addAll(_extensionChildrenToNodes(child));
        }
      }

      final trkPoints = <GeoPoint>[];
      final trkChannels = <Channel, List<Sample>>{};
      final trkLaps = <Lap>[];
      final segmentStarts = <int>[];

      for (final trkseg in trk.childElements) {
        if (trkseg.name.local != 'trkseg') continue;
        final segmentStartIndex = trkPoints.length;

        DateTime? segmentStart;
        DateTime? segmentEnd;
        var segmentDistance = 0.0;
        GeoPoint? previous;
        var index = 0;

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

          String? timeText;
          String? eleText;
          final extensionNodes = <XmlElement>[];
          Map<String, String>? pointAttributes;

          for (final child in trkpt.childElements) {
            final local = child.name.local;
            switch (local) {
              case 'time':
                timeText ??= child.innerText.trim();
                break;
              case 'ele':
                eleText ??= child.innerText.trim();
                break;
              case 'extensions':
                extensionNodes.add(child);
                break;
              default:
                if (_pointAttributeElements.contains(local)) {
                  final value = child.innerText.trim();
                  if (value.isNotEmpty) {
                    (pointAttributes ??= {})[local] = value;
                  }
                }
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
          List<GpxExtensionNode>? pointExtensions;
          for (final extChild in extensionNodes) {
            for (final tpext in extChild.childElements) {
              if (tpext.name.local == 'TrackPointExtension') {
                for (final child in tpext.childElements) {
                  final name = child.name.local;
                  final valueText = child.innerText.trim();
                  if (valueText.isEmpty) continue;
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
                  // Known tags map to built-in channels; unknown numeric
                  // tags are preserved as custom channels.
                  final channel =
                      _tpxTagToChannel[name] ?? Channel.custom(name);
                  trkChannels
                      .putIfAbsent(channel, () => [])
                      .add(Sample(time: time, value: parsed));
                }
              } else {
                // Preserve unrecognized point-level extension elements for
                // lossless round-trips.
                (pointExtensions ??= []).add(_extensionNodeFromXml(tpext));
              }
            }
          }
          final point = GeoPoint(
            latitude: lat,
            longitude: lon,
            elevation: elevation,
            time: time,
            gpxExtensions: pointExtensions,
            gpxAttributes: pointAttributes,
          );
          trkPoints.add(point);
          segmentStart ??= time;
          segmentEnd = time;
          final prev = previous;
          if (prev != null) {
            segmentDistance += haversineMeters(prev, point);
          }
          previous = point;
        } // end trkpt loop
        if (trkPoints.length > segmentStartIndex) {
          // A non-empty segment: remember where it begins so the encoder can
          // re-split the flat point list back into <trkseg> boundaries.
          segmentStarts.add(segmentStartIndex);
        }
        if (segmentStart != null && segmentEnd != null) {
          trkLaps.add(
            Lap(
              startTime: segmentStart,
              endTime: segmentEnd,
              distanceMeters: segmentDistance > 0 ? segmentDistance : null,
              name: 'Segment ${trkLaps.length + 1}',
            ),
          );
        }
      } // end trkseg loop

      parsedTracks.add(
        _GpxTrackData(
          points: trkPoints,
          channels: trkChannels,
          laps: trkLaps,
          name: trkName,
          description: trkDesc,
          type: trkType,
          sport: trkSport,
          extensions: trkExtensions,
          segmentStarts: segmentStarts.length > 1 ? segmentStarts : const [],
        ),
      );

      if (trkSport != Sport.unknown && overallSport == Sport.unknown) {
        overallSport = trkSport;
      }
    } // end trk loop

    if (parsedTracks.length > 1) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.info,
          code: 'gpx.multi_track',
          message:
              'Multi-track GPX file (${parsedTracks.length} tracks); '
              'additional tracks preserved in RawActivity.additionalTracks.',
          node: const ParseNodeReference(path: 'gpx.trk'),
        ),
      );
    }

    // Root-level waypoints (<wpt>) and routes (<rte>) are preserved as
    // structured data (with their names, symbols, and other metadata) rather
    // than folded into the track, so their identity survives a round-trip.
    final waypoints = <GeoPoint>[];
    final routes = <GpxRoute>[];
    for (final child in root.childElements) {
      if (child.name.local == 'wpt') {
        final point = _parseGpxPoint(
          child,
          diagnostics,
          'gpx.wpt.invalid_timestamp',
          'gpx.wpt',
        );
        if (point != null) waypoints.add(point);
      } else if (child.name.local == 'rte') {
        final rtePoints = <GeoPoint>[];
        final routeMeta = <String, String>{};
        String? routeName;
        for (final rteChild in child.childElements) {
          final local = rteChild.name.local;
          if (local == 'rtept') {
            final point = _parseGpxPoint(
              rteChild,
              diagnostics,
              'gpx.rtept.invalid_timestamp',
              'gpx.rte.rtept',
            );
            if (point != null) rtePoints.add(point);
          } else if (local == 'name') {
            routeName = rteChild.innerText.trim();
          } else if (local != 'extensions') {
            final value = rteChild.innerText.trim();
            if (value.isNotEmpty) routeMeta[local] = value;
          }
        }
        routes.add(
          GpxRoute(name: routeName, points: rtePoints, metadata: routeMeta),
        );
      }
    }

    // Build primary activity from first track (or empty if no tracks).
    final primary = parsedTracks.isNotEmpty ? parsedTracks.first : null;

    final additionalTracks = parsedTracks.length > 1
        ? parsedTracks
              .skip(1)
              .map(
                (t) => RawActivity(
                  points: t.points,
                  channels: t.channels,
                  laps: t.laps,
                  sport: t.sport,
                  creator: creator,
                  gpxMetadataName: metadataName,
                  gpxMetadataDescription: metadataDescription,
                  gpxMetadataExtensions: metadataExtensions,
                  gpxTrackName: t.name,
                  gpxTrackDescription: t.description,
                  gpxTrackType: t.type,
                  gpxTrackExtensions: t.extensions,
                  gpxTrackSegments: t.segmentStarts,
                ),
              )
              .toList()
        : <RawActivity>[];

    final activity = RawActivity(
      points: primary?.points ?? const [],
      channels: primary?.channels ?? const {},
      laps: primary?.laps ?? const [],
      sport: overallSport,
      creator: creator,
      gpxMetadataName: metadataName,
      gpxMetadataDescription: metadataDescription,
      gpxMetadataExtensions: metadataExtensions,
      gpxTrackName: primary?.name,
      gpxTrackDescription: primary?.description,
      gpxTrackType: primary?.type,
      gpxTrackExtensions: primary?.extensions ?? const [],
      additionalTracks: additionalTracks,
      gpxWaypoints: waypoints,
      gpxRoutes: routes,
      gpxTrackSegments: primary?.segmentStarts ?? const [],
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

/// Parses a `<wpt>`/`<rtept>` element into a [GeoPoint], preserving its
/// standard child elements (name, sym, desc, …) in [GeoPoint.gpxAttributes]
/// and foreign `<extensions>` children in [GeoPoint.gpxExtensions]. Points
/// without a parsable timestamp keep a deterministic UTC-epoch fallback.
GeoPoint? _parseGpxPoint(
  XmlElement element,
  List<ParseDiagnostic> diagnostics,
  String code,
  String path,
) {
  final lat = double.tryParse(element.getAttribute('lat') ?? '');
  final lon = double.tryParse(element.getAttribute('lon') ?? '');
  if (lat == null || lon == null) return null;
  String? timeText;
  String? eleText;
  Map<String, String>? attributes;
  List<GpxExtensionNode>? extensions;
  for (final child in element.childElements) {
    final local = child.name.local;
    switch (local) {
      case 'time':
        timeText ??= child.innerText.trim();
        break;
      case 'ele':
        eleText ??= child.innerText.trim();
        break;
      case 'extensions':
        for (final ext in child.childElements) {
          (extensions ??= []).add(_extensionNodeFromXml(ext));
        }
        break;
      default:
        if (GpxParser._pointAttributeElements.contains(local)) {
          final value = child.innerText.trim();
          if (value.isNotEmpty) (attributes ??= {})[local] = value;
        }
    }
  }
  DateTime? time;
  if (timeText != null && timeText.isNotEmpty) {
    try {
      time = DateTime.parse(timeText).toUtc();
    } catch (_) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: code,
          message:
              'Invalid timestamp "$timeText" on <${element.name.local}>; '
              'point kept with epoch fallback time.',
          node: ParseNodeReference(path: path),
        ),
      );
    }
  }
  return GeoPoint(
    latitude: lat,
    longitude: lon,
    elevation: eleText != null ? double.tryParse(eleText) : null,
    time: time ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    gpxAttributes: attributes,
    gpxExtensions: extensions,
  );
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

/// Internal data holder for one parsed GPX `<trk>` element.
class _GpxTrackData {
  _GpxTrackData({
    required this.points,
    required this.channels,
    required this.laps,
    required this.name,
    required this.description,
    required this.type,
    required this.sport,
    required this.extensions,
    required this.segmentStarts,
  });

  final List<GeoPoint> points;
  final Map<Channel, Iterable<Sample>> channels;
  final List<Lap> laps;
  final String? name;
  final String? description;
  final String? type;
  final Sport sport;
  final List<GpxExtensionNode> extensions;
  final List<int> segmentStarts;
}
