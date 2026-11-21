// SPDX-License-Identifier: BSD-3-Clause
/// Each auto-fix option does its own repair and no other, and gap filling
/// leaves no interval longer than the threshold.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2024, 1, 1, 10);

GeoPoint _point(int seconds, {double lat = 46.0, double lon = 13.0}) =>
    GeoPoint(
      latitude: lat,
      longitude: lon,
      time: _t0.add(Duration(seconds: seconds)),
    );

const _none = ActivityAutoFixOptions(
  fixInvalidGps: false,
  fixChannelDrift: false,
  fixDistanceDrift: false,
  fixTimestampGaps: false,
);

ActivityAutoFixOptions _only({
  bool fixInvalidGps = false,
  bool fixChannelDrift = false,
  bool fixDistanceDrift = false,
  bool fixTimestampGaps = false,
  Duration gapThreshold = const Duration(minutes: 5),
}) => ActivityAutoFixOptions(
  fixInvalidGps: fixInvalidGps,
  fixChannelDrift: fixChannelDrift,
  fixDistanceDrift: fixDistanceDrift,
  fixTimestampGaps: fixTimestampGaps,
  gapThreshold: gapThreshold,
);

void main() {
  // A Null Island point inside the track, and a heart-rate sample after the
  // last point.
  final activity = RawActivity(
    points: [_point(0), _point(10, lat: 0, lon: 0), _point(20)],
    channels: {
      Channel.heartRate: [
        Sample(time: _t0, value: 140),
        Sample(time: _t0.add(const Duration(seconds: 60)), value: 150),
      ],
    },
  );

  test('the options without a repair change nothing', () {
    final fixed = ActivityFiles.edit(activity).autoFix(_none).activity;
    expect(fixed.points, hasLength(3));
    expect(fixed.channel(Channel.heartRate), hasLength(2));
  });

  test('fixChannelDrift alone keeps the Null Island point', () {
    final fixed = ActivityFiles.edit(
      activity,
    ).autoFix(_only(fixChannelDrift: true)).activity;
    expect(fixed.points, hasLength(3));
    expect(fixed.channel(Channel.heartRate), hasLength(1));
  });

  test('fixInvalidGps alone keeps the drifting sample', () {
    final fixed = ActivityFiles.edit(
      activity,
    ).autoFix(_only(fixInvalidGps: true)).activity;
    expect(fixed.points, hasLength(2));
    expect(fixed.channel(Channel.heartRate), hasLength(2));
  });

  group('gap filling', () {
    for (final (gap, threshold) in [
      (const Duration(minutes: 6), const Duration(minutes: 5)),
      (const Duration(minutes: 5), const Duration(minutes: 3)),
      (const Duration(minutes: 20), const Duration(minutes: 5)),
      (const Duration(minutes: 21), const Duration(minutes: 5)),
    ]) {
      test('a ${gap.inMinutes}-minute gap with a ${threshold.inMinutes}-'
          'minute threshold leaves no longer interval', () {
        final gappy = RawActivity(
          points: [_point(0), _point(gap.inSeconds, lat: 46.01)],
        );
        final fixed = ActivityFiles.edit(gappy)
            .autoFix(_only(fixTimestampGaps: true, gapThreshold: threshold))
            .activity;
        for (var i = 1; i < fixed.points.length; i++) {
          final interval = fixed.points[i].time.difference(
            fixed.points[i - 1].time,
          );
          expect(interval, lessThanOrEqualTo(threshold));
        }
      });
    }

    test('a gap at the threshold is left alone', () {
      final gappy = RawActivity(points: [_point(0), _point(300, lat: 46.01)]);
      final fixed = ActivityFiles.edit(
        gappy,
      ).autoFix(_only(fixTimestampGaps: true)).activity;
      expect(fixed.points, hasLength(2));
    });

    test('filled points get distance and speed when those are recomputed', () {
      final gappy = RawActivity(
        points: [_point(0), _point(20 * 60, lat: 46.01)],
      );
      final fixed = ActivityFiles.edit(
        gappy,
      ).autoFix(_only(fixTimestampGaps: true, fixDistanceDrift: true)).activity;
      expect(fixed.points.length, greaterThan(2));
      expect(fixed.channel(Channel.distance), hasLength(fixed.points.length));
      expect(fixed.channel(Channel.speed), hasLength(fixed.points.length));
    });
  });

  group('convert', () {
    // Seven points; two share a neighbour's timestamp.
    final gpx = StringBuffer(
      '<?xml version="1.0"?><gpx version="1.1" '
      'xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>',
    );
    for (final (i, s) in [0, 10, 10, 20, 30, 30, 40].indexed) {
      final time = _t0.add(Duration(seconds: s)).toIso8601String();
      gpx.write(
        '<trkpt lat="${46 + i / 1e4}" lon="13"><time>$time</time></trkpt>',
      );
    }
    gpx.write('</trkseg></trk></gpx>');

    test(
      'trimmed points are reported even when gap filling adds more',
      () async {
        final source = StringBuffer(
          '<?xml version="1.0"?><gpx version="1.1" '
          'xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>',
        );
        for (final (s, lat, lon) in [
          (0, 46.0, 13.0),
          (10, 0.0, 0.0),
          (20, 0.0, 0.0),
          (30, 0.0, 0.0),
          (40, 46.001, 13.0),
          (3640, 46.01, 13.0),
        ]) {
          final time = _t0.add(Duration(seconds: s)).toIso8601String();
          source.write(
            '<trkpt lat="$lat" lon="$lon"><time>$time</time></trkpt>',
          );
        }
        source.write('</trkseg></trk></gpx>');
        final converted = await ActivityFiles.convert(
          source: source.toString(),
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.gpx,
          normalize: false,
          autoFix: const ActivityAutoFixOptions(),
          useIsolate: false,
        );
        expect(converted.activity.points.length, greaterThan(6));
        expect(
          converted.diagnostics
              .singleWhere((d) => d.code == 'autofix.invalid_gps.trimmed')
              .message,
          contains('removed 3 '),
        );
      },
    );

    for (final normalize in [true, false]) {
      test('auto-fix deduplicates with normalize: $normalize', () async {
        final converted = await ActivityFiles.convert(
          source: gpx.toString(),
          from: ActivityFileFormat.gpx,
          to: ActivityFileFormat.gpx,
          normalize: normalize,
          autoFix: const ActivityAutoFixOptions(),
          useIsolate: false,
        );
        expect(converted.activity.points, hasLength(5));
      });
    }
  });
}
