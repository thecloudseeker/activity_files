// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests using real activity files from fixtures.
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

    test('sundaygreenloop FIT fails gracefully with a clear error', () async {
      // TODO(0.5.5)(fit): Upgrade this regression to assert best-effort point/channel extraction once redefinition timeline decoding lands.
      final file = File('scripts/test_files/user_data/sundaygreenloop.fit');
      final bytes = await file.readAsBytes();

      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      expect(result.activity.points, isEmpty);
      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isNotEmpty,
      );
      expect(
        result.diagnostics.any(
          (d) =>
              d.code == 'fit.no_usable_data' ||
              d.code == 'fit.data.unknown_definition',
        ),
        isTrue,
      );
    });
  });
}
