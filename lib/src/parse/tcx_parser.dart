// SPDX-License-Identifier: BSD-3-Clause
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';
import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

/// Parser for the TCX file format.
class TcxParser implements ActivityFormatParser {
  const TcxParser();
  @override
  ActivityParseResult parse(String input) {
    final diagnostics = <ParseDiagnostic>[];
    final document = XmlDocument.parse(input);
    final activities = document.findAllElements('Activity');
    if (activities.isEmpty) {
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }
    final activityElement = activities.first;
    final sport = _sportFromString(activityElement.getAttribute('Sport'));
    final points = <GeoPoint>[];
    final hrSamples = <Sample>[];
    final cadenceSamples = <Sample>[];
    final distanceSamples = <Sample>[];
    final laps = <Lap>[];
    final metadataExtensions = <GpxExtensionNode>[];
    final trackExtensions = <GpxExtensionNode>[];
    for (final extensions
        in activityElement.children.whereType<XmlElement>().where(
          (e) => e.name.local == 'Extensions',
        )) {
      metadataExtensions.addAll(_parseExtensionChildren(extensions));
    }
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
      for (final extensions in track.children.whereType<XmlElement>().where(
        (e) => e.name.local == 'Extensions',
      )) {
        trackExtensions.addAll(_parseExtensionChildren(extensions));
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
              message: 'Trackpoint at $time missing coordinates; skipped.',
              node: ParseNodeReference(
                path: 'tcx.activities.activity.lap.track.trackpoint',
                description: time.toIso8601String(),
              ),
            ),
          );
          continue;
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
        points.add(
          GeoPoint(
            latitude: lat,
            longitude: lon,
            elevation: altitude,
            time: time,
          ),
        );
        final hrNode = _firstChild(trackpoint, 'HeartRateBpm');
        final hrValueText = hrNode != null ? _firstText(hrNode, 'Value') : null;
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
          hrSamples.add(Sample(time: time, value: hrValue));
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
          cadenceSamples.add(Sample(time: time, value: cadenceValue));
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
          distanceSamples.add(Sample(time: time, value: distanceValue));
        }
        firstTime ??= time;
        lastTime = time;
      }
      final first = firstTime;
      final last = lastTime;
      if (first != null && last != null) {
        final start = lapStart ?? first;
        laps.add(
          Lap(
            startTime: start,
            endTime: last,
            distanceMeters: lapDistance,
            name: 'Lap ${laps.length + 1}',
          ),
        );
      }
    }
    final creatorInfo = _extractCreatorInfo(activityElement);
    final channelMap = <Channel, Iterable<Sample>>{};
    if (hrSamples.isNotEmpty) {
      channelMap[Channel.heartRate] = hrSamples;
    }
    if (cadenceSamples.isNotEmpty) {
      channelMap[Channel.cadence] = cadenceSamples;
    }
    if (distanceSamples.isNotEmpty) {
      channelMap[Channel.distance] = distanceSamples;
    }
    final activity = RawActivity(
      points: points,
      channels: channelMap,
      laps: laps,
      sport: sport,
      creator: creatorInfo.creator,
      device: creatorInfo.device,
      gpxMetadataExtensions: metadataExtensions,
      gpxTrackExtensions: trackExtensions,
    );
    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
  }

  Sport _sportFromString(String? sport) {
    if (sport == null) {
      return Sport.unknown;
    }
    final normalized = sport.trim().toLowerCase();
    return switch (normalized) {
      'running' => Sport.running,
      'biking' || 'cycling' || 'bike' => Sport.cycling,
      'walking' => Sport.walking,
      'other' => Sport.other,
      _ => Sport.unknown,
    };
  }

  ({String? creator, ActivityDeviceMetadata? device}) _extractCreatorInfo(
    XmlElement element,
  ) {
    final creatorElement = _firstChild(element, 'Creator');
    if (creatorElement == null) {
      return (creator: null, device: null);
    }
    final name = _firstText(creatorElement, 'Name');
    final manufacturer = _firstText(creatorElement, 'Manufacturer');
    final product =
        _firstText(creatorElement, 'ProductID') ??
        _firstText(creatorElement, 'Product');
    final serial =
        _firstText(creatorElement, 'UnitId') ??
        _firstText(creatorElement, 'SerialNumber');
    String? version;
    final versionElement = _firstChild(creatorElement, 'Version');
    if (versionElement != null) {
      final major = _firstText(versionElement, 'VersionMajor');
      final minor = _firstText(versionElement, 'VersionMinor');
      final buildMajor = _firstText(versionElement, 'BuildMajor');
      final buildMinor = _firstText(versionElement, 'BuildMinor');
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

Iterable<XmlElement> _childElements(XmlElement element, String localName) =>
    element.children.whereType<XmlElement>().where(
      (child) => child.name.local == localName,
    );

XmlElement? _firstChild(XmlElement element, String localName) =>
    _childElements(element, localName).firstOrNull;

String? _firstText(XmlElement element, String localName) {
  for (final child in _childElements(element, localName)) {
    final text = child.innerText.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }
  return null;
}

List<GpxExtensionNode> _parseExtensionChildren(XmlElement extensionsElement) {
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
