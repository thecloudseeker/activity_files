// MIT License
//
// Copyright (c) 2024 activity_files
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import 'package:collection/collection.dart';
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
    final points = [...activity.points]
      ..sort((a, b) => a.time.compareTo(b.time));

    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'gpx',
      attributes: {
        'creator': activity.creator ?? 'activity_files',
        'version': '1.1',
        'xmlns': 'http://www.topografix.com/GPX/1/1',
        'xmlns:xsi': 'http://www.w3.org/2001/XMLSchema-instance',
        'xmlns:gpxtpx':
            'http://www.garmin.com/xmlschemas/TrackPointExtension/v1',
        'xsi:schemaLocation': 'http://www.topografix.com/GPX/1/1 '
            'http://www.topografix.com/GPX/1/1/gpx.xsd '
            'http://www.garmin.com/xmlschemas/TrackPointExtension/v1 '
            'http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd',
      },
      nest: () {
        if (points.isNotEmpty || activity.creator != null) {
          builder.element('metadata', nest: () {
            final start = points.isNotEmpty
                ? points.first.time.toUtc()
                : DateTime.now().toUtc();
            builder.element('time', nest: start.toIso8601String());
            if (activity.creator != null) {
              builder.element('desc', nest: activity.creator!);
            }
          });
        }

        final hrDelta = options.maxDeltaFor(Channel.heartRate);
        final cadenceDelta = options.maxDeltaFor(Channel.cadence);
        final powerDelta = options.maxDeltaFor(Channel.power);
        final tempDelta = options.maxDeltaFor(Channel.temperature);
        final speedDelta = options.maxDeltaFor(Channel.speed);
        final searchDelta = [
          hrDelta,
          cadenceDelta,
          powerDelta,
          tempDelta,
          speedDelta,
          options.defaultMaxDelta,
        ].whereNotNull().fold<Duration>(
              options.defaultMaxDelta,
              (previous, current) => current > previous ? current : previous,
            );

        builder.element('trk', nest: () {
          builder.element('name', nest: () => builder.text('Workout'));
          builder.element('type', nest: _sportLabel(activity.sport));
          builder.element('trkseg', nest: () {
            for (final point in points) {
              final snapshot = ChannelMapper.mapAt(
                point.time,
                activity.channels,
                maxDelta: searchDelta,
              );

              final hr = _valueWithin(
                  snapshot.heartRate, snapshot.heartRateDelta, hrDelta);
              final cadence = _valueWithin(
                  snapshot.cadence, snapshot.cadenceDelta, cadenceDelta);
              final power =
                  _valueWithin(snapshot.power, snapshot.powerDelta, powerDelta);
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
                  builder.element('time',
                      nest: point.time.toUtc().toIso8601String());

                  if (hr != null ||
                      cadence != null ||
                      power != null ||
                      temperature != null) {
                    builder.element('extensions', nest: () {
                      builder.element('gpxtpx:TrackPointExtension', nest: () {
                        if (hr != null) {
                          builder.element('gpxtpx:hr',
                              nest: hr.round().toString());
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
                      });
                    });
                  }
                },
              );
            }
          });
        });
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

double? _valueWithin(
  double? value,
  Duration? delta,
  Duration tolerance,
) {
  if (value == null || delta == null) {
    return null;
  }
  return delta <= tolerance ? value : null;
}
