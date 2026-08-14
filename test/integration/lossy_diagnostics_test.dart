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

    test('TCX reports and names channels outside its five handled ones', () {
      final activity = RawActivity(
        points: [
          for (var i = 0; i < 3; i++)
            GeoPoint(
              latitude: 47.0 + i * 0.001,
              longitude: 11.0,
              time: t0.add(Duration(seconds: i * 5)),
            ),
        ],
        channels: {
          Channel.temperature: [Sample(time: t0, value: 18.5)],
          Channel.custom('grade'): [Sample(time: t0, value: 3.2)],
          Channel.heartRate: [Sample(time: t0, value: 140)],
        },
        sport: Sport.running,
      );
      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.tcx,
        normalize: false,
        runValidation: false,
      );

      final dropped = result.diagnostics.where(
        (d) => d.code == 'lossy.channels_dropped',
      );
      expect(dropped, hasLength(1));
      expect(dropped.single.message, contains('grade'));
      expect(dropped.single.message, contains('temperature'));
      // heart_rate is one of TCX's five handled channels, not dropped.
      expect(dropped.single.message, isNot(contains('heart_rate')));
    });

    test('TCX reports no channel diagnostic when only its five handled '
        'channels are present', () {
      final activity = RawActivity(
        points: [
          for (var i = 0; i < 3; i++)
            GeoPoint(
              latitude: 47.0 + i * 0.001,
              longitude: 11.0,
              time: t0.add(Duration(seconds: i * 5)),
            ),
        ],
        channels: {
          Channel.heartRate: [Sample(time: t0, value: 140)],
          Channel.cadence: [Sample(time: t0, value: 80)],
        },
        sport: Sport.running,
      );
      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.tcx,
        normalize: false,
        runValidation: false,
      );

      expect(
        result.diagnostics.where((d) => d.code == 'lossy.channels_dropped'),
        isEmpty,
      );
    });

    test('GeoJSON keeps lap aggregates but drops the FIT-only features', () {
      final codes = lossyCodes(exportTo(ActivityFileFormat.geojson));
      expect(codes, contains('lossy.events_dropped'));
      expect(codes, isNot(contains('lossy.laps_dropped')));
    });

    test('GeoJSON reports no diagnostic for channel data (holds it all)', () {
      final activity = RawActivity(
        points: [
          for (var i = 0; i < 3; i++)
            GeoPoint(
              latitude: 47.0 + i * 0.001,
              longitude: 11.0,
              time: t0.add(Duration(seconds: i * 5)),
            ),
        ],
        channels: {
          Channel.heartRate: [
            for (var i = 0; i < 3; i++)
              Sample(time: t0.add(Duration(seconds: i * 5)), value: 140.0),
          ],
          Channel.custom('running_smoothness'): [Sample(time: t0, value: 5.2)],
        },
        sport: Sport.running,
      );
      final result = ActivityFiles.export(
        activity: activity,
        to: ActivityFileFormat.geojson,
        normalize: false,
        runValidation: false,
      );
      expect(
        result.diagnostics.where((d) => d.code.contains('channel')),
        isEmpty,
      );
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
