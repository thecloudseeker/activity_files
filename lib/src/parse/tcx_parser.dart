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
    final warnings = <String>[];
    final document = XmlDocument.parse(input);
    final activities = document.findAllElements('Activity');
    if (activities.isEmpty) {
      return ActivityParseResult(activity: RawActivity(), warnings: warnings);
    }
    final activityElement = activities.first;
    final sport = _sportFromString(activityElement.getAttribute('Sport'));
    final points = <GeoPoint>[];
    final hrSamples = <Sample>[];
    final cadenceSamples = <Sample>[];
    final distanceSamples = <Sample>[];
    final laps = <Lap>[];
    for (final lapElement in activityElement.findElements('Lap')) {
      final lapStartAttribute = lapElement.getAttribute('StartTime');
      DateTime? lapStart;
      if (lapStartAttribute != null) {
        try {
          lapStart = DateTime.parse(lapStartAttribute).toUtc();
        } catch (_) {
          warnings
              .add('Invalid Lap StartTime "$lapStartAttribute"; lap ignored.');
          continue;
        }
      }
      final lapDistanceText = _firstText(lapElement, 'DistanceMeters');
      final lapDistance =
          lapDistanceText != null ? double.tryParse(lapDistanceText) : null;
      final track = lapElement.findElements('Track').firstOrNull;
      if (track == null) {
        warnings.add('Lap missing Track element; skipped.');
        continue;
      }
      DateTime? firstTime;
      DateTime? lastTime;
      for (final trackpoint in track.findElements('Trackpoint')) {
        final timeText = _firstText(trackpoint, 'Time');
        if (timeText == null) {
          warnings.add('Trackpoint without Time skipped.');
          continue;
        }
        DateTime time;
        try {
          time = DateTime.parse(timeText).toUtc();
        } catch (_) {
          warnings.add('Invalid Time "$timeText"; trackpoint skipped.');
          continue;
        }
        final position = trackpoint.getElement('Position');
        final latText =
            position != null ? _firstText(position, 'LatitudeDegrees') : null;
        final lonText =
            position != null ? _firstText(position, 'LongitudeDegrees') : null;
        final lat = latText != null ? double.tryParse(latText) : null;
        final lon = lonText != null ? double.tryParse(lonText) : null;
        if (lat == null || lon == null) {
          warnings.add('Trackpoint at $time missing coordinates; skipped.');
          continue;
        }
        final altText = _firstText(trackpoint, 'AltitudeMeters');
        final altitude = altText != null ? double.tryParse(altText) : null;
        if (altText != null && altitude == null) {
          warnings
              .add('Invalid AltitudeMeters "$altText" at $time; using null.');
        }
        points.add(
          GeoPoint(
            latitude: lat,
            longitude: lon,
            elevation: altitude,
            time: time,
          ),
        );
        final hrValueText = trackpoint
            .getElement('HeartRateBpm')
            ?.getElement('Value')
            ?.innerText
            .trim();
        final hrValue =
            hrValueText != null ? double.tryParse(hrValueText) : null;
        if (hrValueText != null && hrValue == null) {
          warnings.add('Invalid HeartRate "$hrValueText" at $time.');
        } else if (hrValue != null) {
          hrSamples.add(Sample(time: time, value: hrValue));
        }
        final cadenceText = _firstText(trackpoint, 'Cadence');
        final cadenceValue =
            cadenceText != null ? double.tryParse(cadenceText) : null;
        if (cadenceText != null && cadenceValue == null) {
          warnings.add('Invalid Cadence "$cadenceText" at $time.');
        } else if (cadenceValue != null) {
          cadenceSamples.add(Sample(time: time, value: cadenceValue));
        }
        final distanceText = _firstText(trackpoint, 'DistanceMeters');
        final distanceValue =
            distanceText != null ? double.tryParse(distanceText) : null;
        if (distanceText != null && distanceValue == null) {
          warnings.add('Invalid DistanceMeters "$distanceText" at $time.');
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
      creator: _extractCreator(activityElement),
    );
    return ActivityParseResult(activity: activity, warnings: warnings);
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
  String? _extractCreator(XmlElement element) {
    final creator = element.getElement('Creator');
    final name = creator?.getElement('Name');
    if (name != null && name.innerText.trim().isNotEmpty) {
      return name.innerText.trim();
    }
    if (creator != null && creator.innerText.trim().isNotEmpty) {
      return creator.innerText.trim();
    }
    return null;
  }
}
String? _firstText(XmlElement element, String localName) {
  for (final child in element.findElements(localName)) {
    final text = child.innerText.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }
  return null;
}
