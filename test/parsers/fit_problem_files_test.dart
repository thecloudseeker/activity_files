// SPDX-License-Identifier: BSD-3-Clause
/// Regression tests for problematic real-world FIT files.
library;

import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('FIT problem files', () {
    test('sundaygreenloop keeps best-effort extraction stable', () async {
      final candidates = [
        'dev/fixtures/user_data/sundaygreenloop.fit',
        'scripts/test_files/user_data/sundaygreenloop.fit',
      ];
      File? file;
      for (final path in candidates) {
        final candidate = File(path);
        if (await candidate.exists()) {
          file = candidate;
          break;
        }
      }
      if (file == null) {
        // Optional local fixture; keep CI green when private data is absent.
        return;
      }
      final resolvedFile = file;

      final bytes = await resolvedFile.readAsBytes();
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      expect(
        result.activity.points.length,
        greaterThanOrEqualTo(5),
        reason:
            'Expected stable best-effort point extraction for sundaygreenloop.fit',
      );
      expect(result.activity.channels, isNotEmpty);
      expect(
        result.diagnostics.where((d) => d.severity == ParseSeverity.error),
        isEmpty,
      );
      expect(
        result.diagnostics.any(
          (d) =>
              d.code == 'fit.record.recovered_timestamp' ||
              d.code == 'fit.data.unknown_definition',
        ),
        isTrue,
      );
    });
  });
}
