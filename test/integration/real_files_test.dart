// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests using real activity files from `example/assets` and
/// (optionally) local fixtures in `dev/fixtures`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Fixture assets', () {
    const assets = {
      'sample.gpx': ActivityFileFormat.gpx,
      'sample.tcx': ActivityFileFormat.tcx,
      'sample.fit': ActivityFileFormat.fit,
    };

    Future<String> assetPath(String name) async {
      final directory = Directory('example/assets');
      if (!await directory.exists()) {
        throw StateError('example/assets directory not found');
      }
      return '${directory.path}${Platform.pathSeparator}$name';
    }

    test('detectFormat identifies fixture formats', () async {
      for (final entry in assets.entries) {
        final path = await assetPath(entry.key);
        final detected = ActivityFiles.detectFormat(path, allowFilePaths: true);
        expect(detected, equals(entry.value));

        final loaded = await ActivityFiles.load(
          path,
          useIsolate: false,
          allowFilePaths: true,
        );
        expect(loaded.format, equals(entry.value));
        if (entry.value != ActivityFileFormat.fit) {
          expect(
            loaded.activity.points,
            isNotEmpty,
            reason: 'Expected points for ${entry.key}',
          );
        }
        final errors = loaded.diagnostics
            .where((d) => d.severity == ParseSeverity.error)
            .toList();
        expect(errors, isEmpty, reason: 'Unexpected errors for ${entry.key}');
      }
    });

    test('load handles FIT bytes and base64 payload', () async {
      final fitPath = await assetPath('sample.fit');
      final fitBytes = await File(fitPath).readAsBytes();

      final detectedBytes = ActivityFiles.detectFormat(fitBytes);
      expect(detectedBytes, equals(ActivityFileFormat.fit));

      final bytesResult = await ActivityFiles.load(fitBytes, useIsolate: false);
      expect(bytesResult.format, equals(ActivityFileFormat.fit));

      final base64Payload = base64Encode(fitBytes);
      final base64Result = await ActivityFiles.load(
        base64Payload,
        useIsolate: false,
      );
      expect(base64Result.format, equals(ActivityFileFormat.fit));
      expect(
        base64Result.activity.points.length,
        equals(bytesResult.activity.points.length),
      );
    });

    test('load enforces strict FIT integrity when requested', () async {
      final fitPath = await assetPath('sample.fit');
      final fitBytes = await File(fitPath).readAsBytes();
      final result = await ActivityFiles.load(
        fitBytes,
        useIsolate: false,
        strictFitIntegrity: true,
      );
      expect(result.hasErrors, isFalse);
    });

    test('convert can round-trip GPX fixture to FIT', () async {
      final gpxPath = await assetPath('sample.gpx');
      final loaded = await ActivityFiles.load(
        gpxPath,
        useIsolate: false,
        allowFilePaths: true,
      );

      final conversion = await ActivityFiles.convert(
        source: gpxPath,
        to: ActivityFileFormat.fit,
        useIsolate: false,
        allowFilePaths: true,
      );
      expect(conversion.isBinary, isTrue);

      final roundTrip = await ActivityFiles.load(
        conversion.asBytes(),
        useIsolate: false,
      );
      expect(roundTrip.format, equals(ActivityFileFormat.fit));
      expect(
        roundTrip.activity.points.length,
        equals(loaded.activity.points.length),
      );
    });

    test('example assets round-trip through normalization', () async {
      final gpxPath = await assetPath('sample.gpx');
      final gpxBytes = await File(gpxPath).readAsBytes();
      final loaded = await ActivityFiles.load(
        gpxBytes,
        format: ActivityFileFormat.gpx,
        useIsolate: false,
      );
      final normalized = ActivityFiles.normalizeActivity(loaded.activity);

      expect(normalized.points, isNotEmpty);
      expect(
        normalized.points.length,
        lessThanOrEqualTo(loaded.activity.points.length),
      );
      for (final point in normalized.points) {
        expect(point.latitude, greaterThanOrEqualTo(-90.0));
        expect(point.latitude, lessThanOrEqualTo(90.0));
        expect(point.longitude, greaterThanOrEqualTo(-180.0));
        expect(point.longitude, lessThanOrEqualTo(180.0));
      }
    });

    test('sundaygreenloop FIT supports best-effort extraction', () async {
      // Optional local fixture (see README "Call for real-world files");
      // keep CI green when private data is absent.
      final file = File('dev/fixtures/user_data/sundaygreenloop.fit');
      if (!await file.exists()) return;

      final bytes = await file.readAsBytes();
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      expect(
        result.activity.points.length,
        greaterThanOrEqualTo(5),
        reason: 'Best-effort FIT support should recover a meaningful point set',
      );
      expect(result.activity.channels, isNotEmpty);
      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
      );
      expect(
        result.diagnostics.any(
          (d) => d.code == 'fit.record.recovered_timestamp',
        ),
        isTrue,
      );
    });
  });

  group('Synthetic fixtures', () {
    Future<Directory?> syntheticDir() async {
      final dir = Directory('example/assets/synthetic');
      return await dir.exists() ? dir : null;
    }

    test('synthetic files parse with expected quality', () async {
      final dir = await syntheticDir();
      if (dir == null) return;

      for (final format in [
        ActivityFileFormat.gpx,
        ActivityFileFormat.tcx,
        ActivityFileFormat.fit,
      ]) {
        final file = File('${dir.path}/clean_run.${format.name}');
        final result = await ActivityFiles.load(
          await file.readAsBytes(),
          format: format,
          useIsolate: false,
        );
        expect(result.activity.points.length, equals(100));
        expect(result.activity.channels, isNotEmpty);
        if (format != ActivityFileFormat.fit) {
          expect(
            result.diagnostics.where((d) => d.severity == ParseSeverity.error),
            isEmpty,
          );
        }
      }
    });

    test(
      'synthetic files preserve point count through round-trip conversion',
      () async {
        final dir = await syntheticDir();
        if (dir == null) return;

        final gpxFile = File('${dir.path}/clean_run.gpx');
        final originalBytes = await gpxFile.readAsBytes();
        final loaded = await ActivityFiles.load(
          originalBytes,
          format: ActivityFileFormat.gpx,
          useIsolate: false,
        );

        for (final format in [ActivityFileFormat.tcx, ActivityFileFormat.fit]) {
          final converted = await ActivityFiles.convert(
            source: originalBytes,
            to: format,
            useIsolate: false,
          );
          expect(
            converted.activity.points.length,
            equals(loaded.activity.points.length),
          );
          expect(converted.hasErrors, isFalse);
        }
      },
    );
  });
}
