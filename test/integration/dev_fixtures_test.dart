// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// Local-only regression coverage against real device files in
/// `dev/fixtures` (gitignored, populated by contributors; see README "Call
/// for real-world files"). Runs one pass per file: parse, quality checks,
/// and round-trip conversion.
double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = (lat2 - lat1) * pi / 180.0;
  final dLon = (lon2 - lon1) * pi / 180.0;
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180.0) *
          cos(lat2 * pi / 180.0) *
          sin(dLon / 2) *
          sin(dLon / 2);
  return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a));
}

void main() {
  test(
    'dev/fixtures parse, round-trip, and pass quality checks',
    () async {
      final fixturesDir = Directory('dev/fixtures');
      if (!await fixturesDir.exists()) return; // local-only corpus, CI-safe

      final files = await fixturesDir
          .list(recursive: true)
          .where((e) => e is File)
          .cast<File>()
          .where(
            (f) =>
                f.path.endsWith('.gpx') ||
                f.path.endsWith('.tcx') ||
                f.path.endsWith('.fit'),
          )
          .toList();

      expect(files, isNotEmpty, reason: 'No test files found in dev/fixtures');

      for (final file in files) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue; // common in copied fixtures

        final filename = file.path.split('/').last;
        final format = filename.endsWith('.gpx')
            ? ActivityFileFormat.gpx
            : filename.endsWith('.tcx')
            ? ActivityFileFormat.tcx
            : ActivityFileFormat.fit;
        final content = utf8.decode(bytes, allowMalformed: true);

        // Skip concatenated/malformed GPX fixtures with multiple <gpx> roots.
        if (format == ActivityFileFormat.gpx) {
          final gpxRoots = RegExp(
            r'<gpx\b',
            caseSensitive: false,
          ).allMatches(content).length;
          if (gpxRoots > 1) continue;
        }

        final loaded = await ActivityFiles.load(
          bytes,
          format: format,
          useIsolate: false,
        );
        expect(loaded.format, equals(format));

        // FIT files in the wild may fail integrity checks but should still parse.
        if (format != ActivityFileFormat.fit) {
          expect(
            loaded.diagnostics.where((d) => d.severity == ParseSeverity.error),
            isEmpty,
            reason:
                'Parsing errors for $filename: '
                '${loaded.diagnostics.map((d) => d.message).join('; ')}',
          );
        }

        final points = loaded.activity.points;

        // TCX <Position> is unambiguous; require points when it's present.
        if (content.contains('<Position>')) {
          expect(points, isNotEmpty, reason: '$filename should have points');
        }

        // Timestamps should be non-decreasing, allowing a couple of outliers.
        if (points.isNotEmpty) {
          var violations = 0;
          for (var i = 1; i < points.length; i++) {
            if (points[i].time.isBefore(points[i - 1].time)) violations++;
          }
          expect(
            violations <= 2,
            isTrue,
            reason:
                '$filename: timestamps have $violations out-of-order samples',
          );
        }

        // Cumulative distance should be positive unless every point shares the
        // same coordinates (e.g. fixtures built to test elevation parsing).
        if (points.length > 1) {
          final distinctCoords = points
              .map((p) => '${p.latitude},${p.longitude}')
              .toSet();
          if (distinctCoords.length > 1) {
            var distance = 0.0;
            for (var i = 1; i < points.length; i++) {
              distance += _haversineMeters(
                points[i - 1].latitude,
                points[i - 1].longitude,
                points[i].latitude,
                points[i].longitude,
              );
            }
            expect(
              distance,
              greaterThan(0.0),
              reason: '$filename: cumulative distance should be > 0',
            );
          }
        }

        // Round-trip: convert to every other GPX/TCX/FIT target without
        // fatal errors, and check the reported source/target formats.
        final hasSamples =
            points.isNotEmpty ||
            loaded.activity.channels.values.any((c) => c.isNotEmpty);
        const targets = [
          ActivityFileFormat.gpx,
          ActivityFileFormat.tcx,
          ActivityFileFormat.fit,
        ];
        for (final target in targets) {
          if (target == format) continue;
          if (target == ActivityFileFormat.fit && !hasSamples) continue;

          final converted = await ActivityFiles.convert(
            source: bytes,
            to: target,
            useIsolate: false,
          );
          expect(
            converted.sourceFormat,
            equals(format),
            reason: '$filename -> ${target.name}: wrong source format reported',
          );
          expect(
            converted.targetFormat,
            equals(target),
            reason: '$filename -> ${target.name}: wrong target format reported',
          );
        }
      }
    },
    timeout: Timeout.factor(4),
  );
}
