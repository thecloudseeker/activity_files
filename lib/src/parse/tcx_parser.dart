// SPDX-License-Identifier: BSD-3-Clause
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';
import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

/// Parser for the TCX file format.
///
/// Supports multi-sport activities (e.g., triathlons) by parsing all
/// `<Activity>` elements and merging them into a single [RawActivity] with
/// sport-specific laps.
class TcxParser implements ActivityFormatParser {
  const TcxParser();

  static final _sportCache = <String, Sport>{};
  static const _sportMap = {
    'running': Sport.running,
    'biking': Sport.cycling,
    'cycling': Sport.cycling,
    'bike': Sport.cycling,
    'swimming': Sport.swimming,
    'swim': Sport.swimming,
    'walking': Sport.walking,
    'other': Sport.other,
  };
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
          code: 'tcx.parse.xml_error',
          message: 'Malformed TCX XML: $reason',
          node: const ParseNodeReference(path: 'tcx.document'),
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
          code: 'tcx.parse.format_error',
          message: 'Failed to parse TCX payload: $reason',
          node: const ParseNodeReference(path: 'tcx.document'),
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }
    final activities = document.findAllElements('Activity');
    if (activities.isEmpty) {
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }

    // Merge all <Activity> elements into one activity; each lap keeps its own
    // sport, so the multi-activity/multi-sport structure survives — the encoder
    // re-splits laps by sport back into separate <Activity> elements.
    final allPoints = <GeoPoint>[];
    final allHrSamples = <Sample>[];
    final allCadenceSamples = <Sample>[];
    final allDistanceSamples = <Sample>[];
    final allSpeedSamples = <Sample>[];
    final allPowerSamples = <Sample>[];
    final allLaps = <Lap>[];
    final metadataExtensions = <GpxExtensionNode>[];
    final trackExtensions = <GpxExtensionNode>[];
    Sport? overallSport;
    String? creator;
    String? notes;
    ActivityDeviceMetadata? device;
    // <Author> lives at the TrainingCenterDatabase root, not per activity.
    final authorElement = document.findAllElements('Author').firstOrNull;
    final author = authorElement != null
        ? _firstText(authorElement, 'Name')
        : null;

    if (activities.length > 1) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.info,
          code: 'tcx.multi_activity',
          message:
              'Multi-activity TCX file detected (${activities.length} '
              'activities); merged into one activity with sport-specific laps '
              '(re-split by sport on encode).',
          node: const ParseNodeReference(path: 'tcx.activities'),
        ),
      );
    }

    for (final activityElement in activities) {
      final activitySport = _sportFromString(
        activityElement.getAttribute('Sport'),
      );
      overallSport ??= activitySport;
      notes ??= _firstText(activityElement, 'Notes');

      for (final child in activityElement.childElements) {
        if (child.name.local == 'Extensions') {
          metadataExtensions.addAll(_parseExtensionChildren(child));
        }
      }

      final creatorInfo = _extractCreatorInfo(activityElement);
      creator ??= creatorInfo.creator;
      device ??= creatorInfo.device;

      for (final lapElement in _childElements(activityElement, 'Lap')) {
        final lapStartAttribute = lapElement.getAttribute('StartTime');
        DateTime? lapStart;
        if (lapStartAttribute != null) {
          try {
            lapStart = DateTime.parse(lapStartAttribute).toUtc();
          } catch (_) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'tcx.lap.invalid_start_time',
                message:
                    'Invalid Lap StartTime "$lapStartAttribute"; lap ignored.',
                node: ParseNodeReference(
                  path: 'tcx.activities.activity.lap',
                  description: lapStartAttribute,
                ),
              ),
            );
            continue;
          }
        }
        final lapDistanceText = _firstText(lapElement, 'DistanceMeters');
        final lapDistance = lapDistanceText != null
            ? double.tryParse(lapDistanceText)
            : null;
        // Lap statistics: plain elements plus HR wrappers (<...Bpm><Value>)
        // and LX lap extensions (ActivityExtension/v2).
        double? lapValueOf(String name) {
          final text = _firstText(lapElement, name);
          return text != null ? double.tryParse(text) : null;
        }

        double? lapHrOf(String name) {
          final node = _firstChild(lapElement, name);
          final text = node != null ? _firstText(node, 'Value') : null;
          return text != null ? double.tryParse(text) : null;
        }

        double? lapAvgSpeed;
        double? lapAvgWatts;
        double? lapMaxWatts;
        double? lapMaxBikeCadence;
        for (final extensions in _childElements(lapElement, 'Extensions')) {
          for (final lx in extensions.childElements) {
            if (lx.name.local != 'LX') continue;
            lapAvgSpeed ??= double.tryParse(_firstText(lx, 'AvgSpeed') ?? '');
            lapAvgWatts ??= double.tryParse(_firstText(lx, 'AvgWatts') ?? '');
            lapMaxWatts ??= double.tryParse(_firstText(lx, 'MaxWatts') ?? '');
            lapMaxBikeCadence ??= double.tryParse(
              _firstText(lx, 'MaxBikeCadence') ?? '',
            );
          }
        }
        final track = _childElements(lapElement, 'Track').firstOrNull;
        if (track == null) {
          diagnostics.add(
            ParseDiagnostic(
              severity: ParseSeverity.warning,
              code: 'tcx.lap.missing_track',
              message: 'Lap missing Track element; skipped.',
              node: ParseNodeReference(path: 'tcx.activities.activity.lap'),
            ),
          );
          continue;
        }
        DateTime? firstTime;
        DateTime? lastTime;
        for (final child in track.childElements) {
          if (child.name.local == 'Extensions') {
            trackExtensions.addAll(_parseExtensionChildren(child));
          }
        }
        for (final trackpoint in _childElements(track, 'Trackpoint')) {
          final timeText = _firstText(trackpoint, 'Time');
          if (timeText == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'tcx.trackpoint.missing_time',
                message: 'Trackpoint without Time skipped.',
                node: ParseNodeReference(
                  path: 'tcx.activities.activity.lap.track.trackpoint',
                ),
              ),
            );
            continue;
          }
          DateTime time;
          try {
            time = DateTime.parse(timeText).toUtc();
          } catch (_) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'tcx.trackpoint.invalid_time',
                message: 'Invalid Time "$timeText"; trackpoint skipped.',
                node: ParseNodeReference(
                  path: 'tcx.activities.activity.lap.track.trackpoint',
                  description: timeText,
                ),
              ),
            );
            continue;
          }
          final position = _firstChild(trackpoint, 'Position');
          final latText = position != null
              ? _firstText(position, 'LatitudeDegrees')
              : null;
          final lonText = position != null
              ? _firstText(position, 'LongitudeDegrees')
              : null;
          final lat = latText != null ? double.tryParse(latText) : null;
          final lon = lonText != null ? double.tryParse(lonText) : null;
          if (lat == null || lon == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'tcx.trackpoint.missing_coordinates',
                message:
                    'Trackpoint at $time missing coordinates; GPS point skipped.',
                node: ParseNodeReference(
                  path: 'tcx.activities.activity.lap.track.trackpoint',
                  description: time.toIso8601String(),
                ),
              ),
            );
          }
          final altText = _firstText(trackpoint, 'AltitudeMeters');
          final altitude = altText != null ? double.tryParse(altText) : null;
          if (altText != null && altitude == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'tcx.trackpoint.invalid_altitude',
                message:
                    'Invalid AltitudeMeters "$altText" at $time; using null.',
                node: ParseNodeReference(
                  path: 'tcx.activities.activity.lap.track.trackpoint',
                  description: time.toIso8601String(),
                ),
              ),
            );
          }
          if (lat != null && lon != null) {
            allPoints.add(
              GeoPoint(
                latitude: lat,
                longitude: lon,
                elevation: altitude,
                time: time,
              ),
            );
          }
          final hrNode = _firstChild(trackpoint, 'HeartRateBpm');
          final hrValueText = hrNode != null
              ? _firstText(hrNode, 'Value')
              : null;
          final hrValue = hrValueText != null
              ? double.tryParse(hrValueText)
              : null;
          if (hrValueText != null && hrValue == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'tcx.trackpoint.invalid_heartrate',
                message: 'Invalid HeartRate "$hrValueText" at $time.',
                node: ParseNodeReference(
                  path:
                      'tcx.activities.activity.lap.track.trackpoint.HeartRateBpm',
                  description: time.toIso8601String(),
                ),
              ),
            );
          } else if (hrValue != null) {
            allHrSamples.add(Sample(time: time, value: hrValue));
          }
          final cadenceText = _firstText(trackpoint, 'Cadence');
          final cadenceValue = cadenceText != null
              ? double.tryParse(cadenceText)
              : null;
          if (cadenceText != null && cadenceValue == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'tcx.trackpoint.invalid_cadence',
                message: 'Invalid Cadence "$cadenceText" at $time.',
                node: ParseNodeReference(
                  path: 'tcx.activities.activity.lap.track.trackpoint.Cadence',
                  description: time.toIso8601String(),
                ),
              ),
            );
          } else if (cadenceValue != null) {
            allCadenceSamples.add(Sample(time: time, value: cadenceValue));
          }
          final distanceText = _firstText(trackpoint, 'DistanceMeters');
          final distanceValue = distanceText != null
              ? double.tryParse(distanceText)
              : null;
          if (distanceText != null && distanceValue == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'tcx.trackpoint.invalid_distance',
                message: 'Invalid DistanceMeters "$distanceText" at $time.',
                node: ParseNodeReference(
                  path:
                      'tcx.activities.activity.lap.track.trackpoint.DistanceMeters',
                  description: time.toIso8601String(),
                ),
              ),
            );
          } else if (distanceValue != null) {
            allDistanceSamples.add(Sample(time: time, value: distanceValue));
          }
          // TPX trackpoint extensions (ActivityExtension/v2): the standard
          // way Garmin TCX carries speed, power, and run cadence.
          for (final extensions in _childElements(trackpoint, 'Extensions')) {
            for (final tpx in extensions.childElements) {
              if (tpx.name.local != 'TPX') continue;
              for (final child in tpx.childElements) {
                final value = double.tryParse(child.innerText.trim());
                if (value == null) continue;
                switch (child.name.local) {
                  case 'Speed':
                    allSpeedSamples.add(Sample(time: time, value: value));
                    break;
                  case 'Watts':
                    allPowerSamples.add(Sample(time: time, value: value));
                    break;
                  case 'RunCadence':
                    // Plain <Cadence> wins when both are present.
                    if (cadenceValue == null) {
                      allCadenceSamples.add(Sample(time: time, value: value));
                    }
                    break;
                }
              }
            }
          }
          firstTime ??= time;
          lastTime = time;
        }
        final first = firstTime;
        final last = lastTime;
        if (first != null && last != null) {
          final start = lapStart ?? first;
          allLaps.add(
            Lap(
              startTime: start,
              endTime: last,
              distanceMeters: lapDistance,
              name: 'Lap ${allLaps.length + 1}',
              sport: activitySport,
              calories: lapValueOf('Calories'),
              maxSpeed: lapValueOf('MaximumSpeed'),
              avgHeartRate: lapHrOf('AverageHeartRateBpm'),
              maxHeartRate: lapHrOf('MaximumHeartRateBpm'),
              avgCadence: lapValueOf('Cadence'),
              maxCadence: lapMaxBikeCadence,
              avgSpeed: lapAvgSpeed,
              avgPower: lapAvgWatts,
              maxPower: lapMaxWatts,
              tcxIntensity: _firstText(lapElement, 'Intensity'),
              tcxTriggerMethod: _firstText(lapElement, 'TriggerMethod'),
            ),
          );
        }
      }
    }

    // Build the merged activity.
    final channelMap = <Channel, Iterable<Sample>>{};
    if (allHrSamples.isNotEmpty) {
      channelMap[Channel.heartRate] = allHrSamples;
    }
    if (allCadenceSamples.isNotEmpty) {
      channelMap[Channel.cadence] = allCadenceSamples;
    }
    if (allDistanceSamples.isNotEmpty) {
      channelMap[Channel.distance] = allDistanceSamples;
    }
    if (allSpeedSamples.isNotEmpty) {
      channelMap[Channel.speed] = allSpeedSamples;
    }
    if (allPowerSamples.isNotEmpty) {
      channelMap[Channel.power] = allPowerSamples;
    }
    final activity = RawActivity(
      points: allPoints,
      channels: channelMap,
      laps: allLaps,
      sport: overallSport ?? Sport.unknown,
      creator: creator,
      device: device,
      tcxNotes: notes,
      tcxAuthor: author,
      gpxMetadataExtensions: metadataExtensions,
      gpxTrackExtensions: trackExtensions,
    );
    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
  }

  Sport _sportFromString(String? sport) {
    if (sport == null || sport.isEmpty) {
      return Sport.unknown;
    }

    // Check cache first
    final cached = TcxParser._sportCache[sport];
    if (cached != null) {
      return cached;
    }

    final normalized = sport.trim().toLowerCase();
    final result = TcxParser._sportMap[normalized] ?? Sport.unknown;

    // Cache for future lookups
    TcxParser._sportCache[sport] = result;

    return result;
  }

  ({String? creator, ActivityDeviceMetadata? device}) _extractCreatorInfo(
    XmlElement element,
  ) {
    final creatorElement = _firstChild(element, 'Creator');
    if (creatorElement == null) {
      return (creator: null, device: null);
    }

    // Batch lookup: fetch all needed fields in one pass
    final creatorTexts = _batchTexts(creatorElement, [
      'Name',
      'Manufacturer',
      'ProductID',
      'Product',
      'UnitId',
      'SerialNumber',
    ]);

    final name = creatorTexts['Name'];
    final manufacturer = creatorTexts['Manufacturer'];
    final product = creatorTexts['ProductID'] ?? creatorTexts['Product'];
    final serial = creatorTexts['UnitId'] ?? creatorTexts['SerialNumber'];

    String? version;
    final versionElement = _firstChild(creatorElement, 'Version');
    if (versionElement != null) {
      final versionTexts = _batchTexts(versionElement, [
        'VersionMajor',
        'VersionMinor',
        'BuildMajor',
        'BuildMinor',
      ]);
      final major = versionTexts['VersionMajor'];
      final minor = versionTexts['VersionMinor'];
      final buildMajor = versionTexts['BuildMajor'];
      final buildMinor = versionTexts['BuildMinor'];

      final coreParts = [
        if (major != null && major.isNotEmpty) major,
        if (minor != null && minor.isNotEmpty) minor,
      ];
      final buildParts = [
        if (buildMajor != null && buildMajor.isNotEmpty) buildMajor,
        if (buildMinor != null && buildMinor.isNotEmpty) buildMinor,
      ];
      if (coreParts.isNotEmpty) {
        version = coreParts.join('.');
      }
      if (buildParts.isNotEmpty) {
        final build = buildParts.join('.');
        version = version == null ? build : '$version+$build';
      }
    }

    final device = ActivityDeviceMetadata(
      manufacturer: manufacturer,
      model: name,
      product: product,
      serialNumber: serial,
      softwareVersion: version,
    );

    var creatorLabel = name?.trim();
    if (creatorLabel == null || creatorLabel.isEmpty) {
      final raw = (creatorElement.value ?? "").trim().trim();
      if (raw.isNotEmpty) {
        creatorLabel = raw;
      } else {
        creatorLabel = null;
      }
    }
    return (creator: creatorLabel, device: device.isNotEmpty ? device : null);
  }
}

/// Cache for frequent element lookups to avoid repeated traversals.
/// Uses Expando so cache keys are weak and don't retain parsed XML trees.
final _elementCache = Expando<Map<String, XmlElement>>('tcx_element_cache');
final _textCache = Expando<Map<String, String?>>('tcx_text_cache');

/// Batch-retrieves child elements by local name. Faster than repeated _firstChild calls.
/// Use this when you need multiple children from the same element.
Map<String, XmlElement> _batchChildElements(XmlElement element) {
  // Check cache first
  final cached = _elementCache[element];
  if (cached != null) {
    return cached;
  }

  // Build cache on first access
  final children = <String, XmlElement>{};
  for (final child in element.childElements) {
    final localName = child.name.local;
    // Keep first occurrence of each name
    children.putIfAbsent(localName, () => child);
  }

  _elementCache[element] = children;
  return children;
}

/// Batch-retrieves text values for multiple child elements.
/// Faster than multiple _firstText calls.
Map<String, String?> _batchTexts(XmlElement element, List<String> localNames) {
  final texts = _textCache[element] ?? <String, String?>{};
  final childMap = _batchChildElements(element);

  for (final localName in localNames) {
    if (texts.containsKey(localName)) {
      continue;
    }
    final child = childMap[localName];
    if (child != null) {
      final text = child.innerText.trim();
      texts[localName] = text.isEmpty ? null : text;
    }
  }

  _textCache[element] = texts;
  return texts;
}

Iterable<XmlElement> _childElements(XmlElement element, String localName) {
  // Direct iteration without whereType is faster
  return element.childElements.where((child) => child.name.local == localName);
}

XmlElement? _firstChild(XmlElement element, String localName) =>
    _batchChildElements(element)[localName];

String? _firstText(XmlElement element, String localName) {
  final child = _firstChild(element, localName);
  if (child == null) return null;
  final text = child.innerText.trim();
  return text.isEmpty ? null : text;
}

List<GpxExtensionNode> _parseExtensionChildren(XmlElement extensionsElement) {
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
