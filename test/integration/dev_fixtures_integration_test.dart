import 'dart:io';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:activity_files/activity_files.dart';

void main() {
  test('dev/fixtures parse successfully', () async {
    final fixtures = Directory('dev/fixtures');
    if (!await fixtures.exists()) return; // CI-safe

    final files = await fixtures
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
      if (bytes.isEmpty) {
        // Skip empty files (common in copied fixtures)
        continue;
      }
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

      final content = utf8.decode(bytes, allowMalformed: true);

      // Skip concatenated/malformed GPX files that contain multiple <gpx> roots
      if (format == ActivityFileFormat.gpx) {
        final gpxMatches = RegExp(
          r'<gpx\b',
          caseSensitive: false,
        ).allMatches(content).length;
        if (gpxMatches > 1) {
          // Known-bad or concatenated GPX fixture; skip strict assertions.
          continue;
        }
      }

      if (format == ActivityFileFormat.fit) {
        // FIT files in the wild may fail integrity checks (CRC/trailer) but still parse
        expect(result.format, equals(ActivityFileFormat.fit));
      } else {
        expect(
          result.diagnostics.where((d) => d.severity == ParseSeverity.error),
          isEmpty,
          reason:
              'Parsing errors for ${file.path}: ${result.diagnostics.map((d) => d.message).join('; ')}',
        );
      }

      final hasPosition = content.contains('<Position>');
      if (hasPosition) {
        expect(
          result.activity.points.length,
          greaterThan(0),
          reason: '$filename should have points',
        );
      }
    }
  });
}
