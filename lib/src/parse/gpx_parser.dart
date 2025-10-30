// SPDX-License-Identifier: BSD-3-Clause
import 'dart:math' as math;
import 'package:xml/xml.dart';
import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';
/// Parser for the GPX file format.
class GpxParser implements ActivityFormatParser {
  const GpxParser();
  @override
  ActivityParseResult parse(String input) {
    final warnings = <String>[];
    final document = XmlDocument.parse(input);
    final root = document.rootElement;
    final creator = root.getAttribute('creator');
    final points = <GeoPoint>[];
    final hrSamples = <Sample>[];
    final cadenceSamples = <Sample>[];
    final powerSamples = <Sample>[];
    final temperatureSamples = <Sample>[];
    final laps = <Lap>[];
    var sport = Sport.unknown;
    for (final trk
        in root.findElements('*').where((e) => e.name.local == 'trk')) {
      final typeText = _firstText(trk, 'type');
      if (typeText != null && typeText.trim().isNotEmpty) {
        sport = _sportFromString(typeText);
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
            warnings.add(
                'Skipping GPX trackpoint missing coordinates (index $index).');
            continue;
          }
          final timeText = _firstText(trkpt, 'time');
          if (timeText == null) {
            warnings
                .add('Skipping GPX trackpoint without timestamp at $lat,$lon.');
            continue;
          }
          DateTime? time;
          try {
            time = DateTime.parse(timeText).toUtc();
          } catch (_) {
            warnings.add('Invalid timestamp "$timeText"; trackpoint ignored.');
            continue;
          }
          final eleText = _firstText(trkpt, 'ele');
          final elevation = eleText != null ? double.tryParse(eleText) : null;
          if (eleText != null && elevation == null) {
            warnings.add(
                'Invalid elevation "$eleText" at $time; treating as null.');
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
              .expand((ext) => ext.children.whereType<XmlElement>().where(
                    (element) =>
                        element.name.local.toLowerCase() ==
                        'trackpointextension',
                  ));
          for (final ext in extensionElements) {
            for (final child in ext.childElements) {
              final name = child.name.local.toLowerCase();
              final valueText = child.innerText.trim();
              if (valueText.isEmpty) {
                continue;
              }
              final parsed = double.tryParse(valueText);
              if (parsed == null) {
                warnings.add(
                    'Unparsable extension value "$valueText" for $name at $time.');
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
    );
    return ActivityParseResult(activity: activity, warnings: warnings);
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
