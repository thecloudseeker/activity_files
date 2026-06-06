import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:test/test.dart';
import 'package:activity_files/activity_files.dart';

double _haversine(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371000.0; // meters
  final dLat = (lat2 - lat1) * pi / 180.0;
  final dLon = (lon2 - lon1) * pi / 180.0;
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180.0) *
          cos(lat2 * pi / 180.0) *
          sin(dLon / 2) *
          sin(dLon / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return R * c;
}

void main() {
  group('dev/fixtures extended checks', () {
    final fixturesDir = Directory('dev/fixtures');
    test('roundtrip conversion and quality checks', () async {
      if (!await fixturesDir.exists()) return;

      await for (final entity in fixturesDir.list(recursive: true)) {
        if (entity is! File) continue;
        final file = entity;
        final path = file.path;
        if (!(path.endsWith('.gpx') ||
            path.endsWith('.tcx') ||
            path.endsWith('.fit'))) {
          continue;
        }

        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;

        final content = utf8.decode(bytes, allowMalformed: true);

        final filename = path.split('/').last;
        final format = filename.endsWith('.gpx')
            ? ActivityFileFormat.gpx
            : filename.endsWith('.tcx')
            ? ActivityFileFormat.tcx
            : ActivityFileFormat.fit;

        final loaded = await ActivityFiles.load(
          bytes,
          format: format,
          useIsolate: false,
        );

        // Ensure basic parsing completed (FIT may report diagnostics but still identify format)
        expect(loaded.format, equals(format));

        final hasPosition =
            content.contains('<Position>') ||
            content.contains('<trkpt') ||
            content.contains('lat="');

        // Time monotonicity: points timestamps must be non-decreasing
        if (loaded.activity.points.isNotEmpty) {
          DateTime? prev;
          var violations = 0;
          for (final p in loaded.activity.points) {
            if (prev != null) {
              if (p.time.isBefore(prev)) {
                violations++;
              }
            }
            prev = p.time;
          }
          expect(
            violations <= 2,
            isTrue,
            reason:
                '$filename: timestamps have $violations out-of-order samples',
          );
        }

        // Distance validation: if positions exist, cumulative distance should be > 0
        if (hasPosition && loaded.activity.points.isNotEmpty) {
          double sum = 0.0;
          double? lastLat, lastLon;
          for (final p in loaded.activity.points) {
            if (lastLat != null && lastLon != null) {
              sum += _haversine(lastLat, lastLon, p.latitude, p.longitude);
            }
            lastLat = p.latitude;
            lastLon = p.longitude;
          }
          expect(
            sum,
            greaterThan(0.0),
            reason:
                '$filename: cumulative distance should be > 0 when positions present',
          );
        }

        // Conversion roundtrip: convert to other formats and ensure no fatal errors
        final targets = <ActivityFileFormat>[
          ActivityFileFormat.gpx,
          ActivityFileFormat.tcx,
          ActivityFileFormat.fit,
        ];
        final hasAnySamples =
            loaded.activity.points.isNotEmpty ||
            loaded.activity.channels.values.any((c) => c.isNotEmpty);

        for (final t in targets) {
          if (t == format) continue;
          // FIT encoding requires at least some points or sensor samples
          if (t == ActivityFileFormat.fit && !hasAnySamples) continue;

          final converted = await ActivityFiles.convert(
            source: bytes,
            to: t,
            allowFilePaths: false,
            useIsolate: false,
          );
          expect(
            converted.sourceFormat,
            equals(format),
            reason:
                '$filename -> ${t.name} conversion reported wrong source format',
          );
          expect(
            converted.targetFormat,
            equals(t),
            reason:
                '$filename -> ${t.name} conversion produced wrong target format',
          );
        }
      }
    }, timeout: Timeout.factor(4));
  });
}
