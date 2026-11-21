// SPDX-License-Identifier: BSD-3-Clause
/// An activity without points or samples exports to a valid FIT file with an
/// error diagnostic instead of throwing.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2024, 1, 1, 10);

void main() {
  test('an empty activity writes a valid FIT file and reports it', () async {
    final result = ActivityFiles.export(
      activity: RawActivity(),
      to: ActivityFileFormat.fit,
    );
    expect(
      result.diagnostics
          .where((d) => d.severity == ParseSeverity.error)
          .map((d) => d.code),
      contains('fit.export.no_records'),
    );

    final back = await ActivityFiles.import(
      result.asBytes(),
      format: ActivityFileFormat.fit,
    );
    expect(back.activity.points, isEmpty);
    expect(
      back.diagnostics.map((d) => d.code),
      isNot(contains(startsWith('fit.header'))),
    );
    expect(
      back.diagnostics.map((d) => d.code),
      isNot(contains(startsWith('fit.trailer'))),
    );
  });

  test('laps and the summary of an activity without records survive', () async {
    final activity = RawActivity(
      sport: Sport.cycling,
      laps: [
        Lap(
          startTime: _t0,
          endTime: _t0.add(const Duration(minutes: 10)),
          distanceMeters: 5000,
        ),
      ],
      summary: const ActivitySummary(calories: 120),
    );
    final result = ActivityFiles.export(
      activity: activity,
      to: ActivityFileFormat.fit,
      normalize: false,
    );
    final back = await ActivityFiles.import(
      result.asBytes(),
      format: ActivityFileFormat.fit,
    );
    expect(back.activity.laps.single.distanceMeters, closeTo(5000, 0.01));
    expect(back.activity.summary?.calories, 120);
    expect(back.activity.sport, Sport.cycling);
  });

  test('a GPX file with an empty track converts to FIT', () async {
    const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg></trkseg></trk>
</gpx>''';
    final result = await ActivityFiles.convert(
      source: gpx,
      from: ActivityFileFormat.gpx,
      to: ActivityFileFormat.fit,
    );
    expect(
      result.diagnostics.map((d) => d.code),
      contains('fit.export.no_records'),
    );
  });
}
