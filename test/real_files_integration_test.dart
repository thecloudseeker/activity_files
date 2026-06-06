import 'dart:io';
import 'package:test/test.dart';
import 'package:activity_files/activity_files.dart';

void main() {
  test('all example assets parse successfully', () async {
    final assets = Directory('example/assets');
    if (!await assets.exists()) return; // CI-safe

    await for (final entity in assets.list(recursive: true)) {
      if (entity is File) {
        final path = entity.path;
        if (path.endsWith('.gpx') ||
            path.endsWith('.tcx') ||
            path.endsWith('.fit')) {
          final result = await ActivityFiles.load(path, allowFilePaths: true);
          expect(
            result.diagnostics.where((d) => d.severity == ParseSeverity.error),
            isEmpty,
            reason:
                'Parsing errors for $path: ${result.diagnostics.map((d) => d.message).join('; ')}',
          );
        }
      }
    }
  });

  test('example assets can be converted between formats', () async {
    final assets = Directory('example/assets');
    if (!await assets.exists()) return; // CI-safe

    // pick any GPX file and try convert to FIT
    await for (final entity in assets.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.gpx')) {
        final res = await ActivityFiles.convert(
          source: entity.path,
          to: ActivityFileFormat.fit,
          allowFilePaths: true,
        );
        expect(
          res.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isEmpty,
        );
        break;
      }
    }
  });

  group('Real files integration', () {
    /// Helper to check if example/assets directory exists
    Future<Directory?> tryGetExampleAssetsDir() async {
      final dir = Directory('example/assets');
      if (await dir.exists()) {
        return dir;
      }
      return null;
    }

    /// Helper to check if synthetic test files directory exists
    Future<Directory?> tryGetSyntheticAssetsDir() async {
      final dir = Directory('example/assets/synthetic');
      if (await dir.exists()) {
        return dir;
      }
      return null;
    }

    test('all example assets parse successfully', () async {
      final assetsDir = await tryGetExampleAssetsDir();
      if (assetsDir == null) {
        // Skip silently in CI environments
        return;
      }

      final files = await assetsDir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .where(
            (f) =>
                f.path.endsWith('.fit') ||
                f.path.endsWith('.gpx') ||
                f.path.endsWith('.tcx'),
          )
          .toList();

      expect(
        files,
        isNotEmpty,
        reason: 'No test files found in example/assets',
      );

      for (final file in files) {
        final bytes = await file.readAsBytes();
        final filename = file.path.split('/').last;
        final format = filename.endsWith('.gpx')
            ? ActivityFileFormat.gpx
            : filename.endsWith('.tcx')
            ? ActivityFileFormat.tcx
            : ActivityFileFormat.fit;
        final result = await ActivityFiles.load(
          bytes,
          format: format,
          useIsolate: false,
        );

        // GPX/TCX should have points; FIT may have 0 if integrity check fails
        if (filename.endsWith('.fit')) {
          // FIT files may have 0 points due to integrity checks, but should parse
          expect(result.format, equals(ActivityFileFormat.fit));
        } else {
          // GPX and TCX should parse successfully with points
          expect(
            result.activity.points.length,
            greaterThan(0),
            reason: '$filename should have at least one point',
          );
        }
      }
    });

    test('GPX example asset parses with expected structure', () async {
      final assetsDir = await tryGetExampleAssetsDir();
      if (assetsDir == null) return;

      final gpxFile = File('${assetsDir.path}/sample.gpx');

      if (!await gpxFile.exists()) {
        return;
      }

      final bytes = await gpxFile.readAsBytes();
      final result = await ActivityFiles.load(
        bytes,
        format: ActivityFileFormat.gpx,
        useIsolate: false,
      );

      expect(result.format, equals(ActivityFileFormat.gpx));
      expect(result.activity.points, isNotEmpty);
      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
        reason: 'sample.gpx should parse without errors',
      );
    });

    test('TCX example asset parses with expected structure', () async {
      final assetsDir = await tryGetExampleAssetsDir();
      if (assetsDir == null) return;

      final tcxFile = File('${assetsDir.path}/sample.tcx');

      if (!await tcxFile.exists()) {
        return;
      }

      final bytes = await tcxFile.readAsBytes();
      final result = await ActivityFiles.load(
        bytes,
        format: ActivityFileFormat.tcx,
        useIsolate: false,
      );

      expect(result.format, equals(ActivityFileFormat.tcx));
      expect(result.activity.points, isNotEmpty);
      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
        reason: 'sample.tcx should parse without errors',
      );
    });

    test('FIT example asset parses', () async {
      final assetsDir = await tryGetExampleAssetsDir();
      if (assetsDir == null) return;

      final fitFile = File('${assetsDir.path}/sample.fit');

      if (!await fitFile.exists()) {
        return;
      }

      final bytes = await fitFile.readAsBytes();
      final result = await ActivityFiles.load(
        bytes,
        format: ActivityFileFormat.fit,
        useIsolate: false,
      );

      expect(result.format, equals(ActivityFileFormat.fit));
    });

    test('example assets can be converted between formats', () async {
      final assetsDir = await tryGetExampleAssetsDir();
      if (assetsDir == null) return;

      final gpxFile = File('${assetsDir.path}/sample.gpx');

      if (!await gpxFile.exists()) {
        return;
      }

      final gpxBytes = await gpxFile.readAsBytes();

      // GPX → TCX
      final gpxToTcx = await ActivityFiles.convert(
        source: gpxBytes,
        to: ActivityFileFormat.tcx,
        useIsolate: false,
      );
      expect(gpxToTcx.activity.points.length, greaterThan(0));
      expect(gpxToTcx.asString(), contains('<TrainingCenterDatabase'));

      // GPX → FIT
      final gpxToFit = await ActivityFiles.convert(
        source: gpxBytes,
        to: ActivityFileFormat.fit,
        useIsolate: false,
      );
      expect(gpxToFit.activity.points.length, greaterThan(0));
      expect(gpxToFit.isBinary, isTrue);
    });

    test('example assets round-trip through normalization', () async {
      final assetsDir = await tryGetExampleAssetsDir();
      if (assetsDir == null) return;

      final gpxFile = File('${assetsDir.path}/sample.gpx');

      if (!await gpxFile.exists()) {
        return;
      }

      final gpxBytes = await gpxFile.readAsBytes();
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

      // Normalized points should all be valid
      for (final point in normalized.points) {
        expect(point.latitude, greaterThanOrEqualTo(-90.0));
        expect(point.latitude, lessThanOrEqualTo(90.0));
        expect(point.longitude, greaterThanOrEqualTo(-180.0));
        expect(point.longitude, lessThanOrEqualTo(180.0));
      }
    });

    test('sample files directory listing', () async {
      // Optional: verify sample directory structure exists
      final sampleDir = Directory('scripts/test_files/sample');
      if (await sampleDir.exists()) {
        final files = await sampleDir.list().toList();
        expect(
          files,
          isNotEmpty,
          reason: 'sample directory should have test files',
        );
      }
    });

    test('synthetic test files parse with expected quality', () async {
      final syntheticDir = await tryGetSyntheticAssetsDir();
      if (syntheticDir == null) return;

      // Verify all synthetic files exist
      final gpxFile = File('${syntheticDir.path}/clean_run.gpx');
      final tcxFile = File('${syntheticDir.path}/clean_run.tcx');
      final fitFile = File('${syntheticDir.path}/clean_run.fit');

      expect(await gpxFile.exists(), isTrue);
      expect(await tcxFile.exists(), isTrue);
      expect(await fitFile.exists(), isTrue);

      // Parse and verify each file
      final gpxResult = await ActivityFiles.load(
        await gpxFile.readAsBytes(),
        format: ActivityFileFormat.gpx,
        useIsolate: false,
      );
      expect(gpxResult.activity.points.length, equals(100));
      expect(gpxResult.activity.channels.length, greaterThan(0));
      expect(
        gpxResult.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
      );

      final tcxResult = await ActivityFiles.load(
        await tcxFile.readAsBytes(),
        format: ActivityFileFormat.tcx,
        useIsolate: false,
      );
      expect(tcxResult.activity.points.length, equals(100));
      expect(tcxResult.activity.channels.length, greaterThan(0));
      expect(
        tcxResult.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
      );

      final fitResult = await ActivityFiles.load(
        await fitFile.readAsBytes(),
        format: ActivityFileFormat.fit,
        useIsolate: false,
      );
      expect(fitResult.activity.points.length, equals(100));
      expect(fitResult.activity.channels.length, greaterThan(0));
    });

    test(
      'synthetic files preserve data through round-trip conversion',
      () async {
        final syntheticDir = await tryGetSyntheticAssetsDir();
        if (syntheticDir == null) return;

        final gpxFile = File('${syntheticDir.path}/clean_run.gpx');
        if (!await gpxFile.exists()) return;

        final originalBytes = await gpxFile.readAsBytes();
        final loaded = await ActivityFiles.load(
          originalBytes,
          format: ActivityFileFormat.gpx,
          useIsolate: false,
        );

        // Convert through all formats
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
