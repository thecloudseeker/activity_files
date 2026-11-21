// SPDX-License-Identifier: BSD-3-Clause
/// Points that share a timestamp keep their order through the encoders: the
/// order is the only thing that tells them apart.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2024, 1, 1, 10);
  // Two runs of 60 points, each run sharing one timestamp.
  final points = [
    for (var i = 0; i < 120; i++)
      GeoPoint(
        latitude: 46 + i / 1e4,
        longitude: 13,
        time: t0.add(Duration(seconds: i < 60 ? 10 : 0)),
      ),
  ];
  final expected = [
    for (final p in [...points.skip(60), ...points.take(60)])
      p.latitude.toStringAsFixed(4),
  ];

  for (final format in [ActivityFileFormat.gpx, ActivityFileFormat.tcx]) {
    test('${format.name} keeps tied points in order', () {
      final encoded = ActivityEncoder.encode(
        RawActivity(points: points),
        format,
      );
      final pattern = format == ActivityFileFormat.gpx
          ? RegExp(r'lat="([0-9.]+)"')
          : RegExp(r'<LatitudeDegrees>([0-9.]+)</LatitudeDegrees>');
      final written = [
        for (final m in pattern.allMatches(encoded))
          double.parse(m[1]!).toStringAsFixed(4),
      ];
      expect(written, expected);
    });
  }
}
