// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// The pipeline must report — never silently swallow — data that the target
/// format cannot represent, via `lossy.*` diagnostics.
void main() {
  final t0 = DateTime.utc(2024, 5, 1, 6, 0, 0);

  RawActivity fullActivity() => RawActivity(
    points: [
      for (var i = 0; i < 4; i++)
        GeoPoint(
          latitude: 47.0 + i * 0.001,
          longitude: 11.0 + i * 0.001,
          elevation: 500.0 + i,
          time: t0.add(Duration(seconds: i * 10)),
        ),
    ],
    sport: Sport.swimming,
    summary: const ActivitySummary(totalDistanceMeters: 1000.0, calories: 90.0),
    laps: [Lap(startTime: t0, endTime: t0.add(const Duration(minutes: 2)))],
    sets: [
      WorkoutSet(
        startTime: t0,
        endTime: t0.add(const Duration(seconds: 30)),
        isRest: false,
        repetitions: 10,
      ),
    ],
    events: [ActivityEvent(time: t0, event: 0, eventType: 0)],
    lengths: [
      SwimLength(
        startTime: t0,
        endTime: t0.add(const Duration(seconds: 20)),
        isActive: true,
      ),
    ],
    additionalSessions: const [ActivitySummary(totalDistanceMeters: 500.0)],
  );

  Set<String> lossyCodes(ActivityExportResult result) => result.diagnostics
      .where((d) => d.code.startsWith('${DiagnosticCategory.lossy}.'))
      .map((d) => d.code)
      .toSet();

  ActivityExportResult exportTo(ActivityFileFormat to) => ActivityFiles.export(
    activity: fullActivity(),
    to: to,
    normalize: false,
    runValidation: false,
  );

  group('lossy.* diagnostics on export', () {
    test('FIT loses nothing (holds every feature)', () {
      expect(lossyCodes(exportTo(ActivityFileFormat.fit)), isEmpty);
    });

    test('GPX reports the FIT-only features plus laps', () {
      expect(lossyCodes(exportTo(ActivityFileFormat.gpx)), {
        'lossy.sets_dropped',
        'lossy.events_dropped',
        'lossy.lengths_dropped',
        'lossy.sessions_dropped',
        'lossy.summary_dropped',
        'lossy.laps_dropped',
      });
    });

    test('CSV reports the FIT-only features plus laps', () {
      expect(lossyCodes(exportTo(ActivityFileFormat.csv)), {
        'lossy.sets_dropped',
        'lossy.events_dropped',
        'lossy.lengths_dropped',
        'lossy.sessions_dropped',
        'lossy.summary_dropped',
        'lossy.laps_dropped',
      });
    });

    test('TCX keeps laps but drops the FIT-only features', () {
      final codes = lossyCodes(exportTo(ActivityFileFormat.tcx));
      expect(codes, contains('lossy.sets_dropped'));
      expect(codes, contains('lossy.summary_dropped'));
      expect(codes, isNot(contains('lossy.laps_dropped')));
    });

    test('GeoJSON keeps lap aggregates but drops the FIT-only features', () {
      final codes = lossyCodes(exportTo(ActivityFileFormat.geojson));
      expect(codes, contains('lossy.events_dropped'));
      expect(codes, isNot(contains('lossy.laps_dropped')));
    });

    test('an activity with no extra features yields no lossy diagnostics', () {
      final plain = RawActivity(
        points: [
          for (var i = 0; i < 3; i++)
            GeoPoint(
              latitude: 47.0 + i * 0.001,
              longitude: 11.0,
              time: t0.add(Duration(seconds: i * 5)),
            ),
        ],
        sport: Sport.running,
      );
      final result = ActivityFiles.export(
        activity: plain,
        to: ActivityFileFormat.gpx,
        normalize: false,
        runValidation: false,
      );
      expect(lossyCodes(result), isEmpty);
    });

    test('diagnostics are emitted once, not duplicated', () {
      final codes = exportTo(
        ActivityFileFormat.gpx,
      ).diagnostics.where((d) => d.code == 'lossy.sets_dropped').toList();
      expect(codes, hasLength(1));
    });

    test('convert() surfaces lossy diagnostics exactly once', () async {
      final fitBytes = ActivityEncoder.encode(
        fullActivity(),
        ActivityFileFormat.fit,
      );
      final result = await ActivityFiles.convert(
        source: base64.decode(fitBytes),
        from: ActivityFileFormat.fit,
        to: ActivityFileFormat.gpx,
        useIsolate: false,
      );
      final setsDropped = result.diagnostics
          .where((d) => d.code == 'lossy.sets_dropped')
          .toList();
      expect(setsDropped, hasLength(1));
    });
  });
}
