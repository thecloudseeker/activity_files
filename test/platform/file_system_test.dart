// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for file system platform adapters.
library;

import 'dart:io';

import 'package:activity_files/src/platform/file_system.dart' as file_system;
import 'package:activity_files/src/platform/file_system_io.dart' as fs_io;
import 'package:activity_files/src/platform/file_system_stub.dart' as fs_stub;
import 'package:test/test.dart';

void main() {
  group('File system adapters', () {
    test('file system stub returns safe fallbacks for web targets', () async {
      expect(fs_stub.isPlatformFile(Object()), isFalse);
      expect(fs_stub.platformFilePath(Object()), isNull);
      expect(await fs_stub.readPlatformFile(Object()), isNull);
      expect(fs_stub.platformPathExists('missing'), isFalse);
      await expectLater(
        fs_stub.readPlatformPath('missing'),
        throwsUnsupportedError,
      );
    });

    test('file system IO handles platform files on non-web targets', () async {
      final tempDir = await Directory.systemTemp.createTemp('af_fs_test');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final file = File('${tempDir.path}/sample.txt');
      await file.writeAsString('hello world');

      expect(fs_io.isPlatformFile(file), isTrue);
      expect(fs_io.platformFilePath(file), equals(file.path));

      final fromFile = await fs_io.readPlatformFile(file);
      expect(fromFile, isNotNull);
      expect(fromFile!.path, equals(file.path));
      expect(fromFile.bytes.length, greaterThan(0));

      expect(fs_io.platformPathExists(file.path), isTrue);
      final pathBytes = await fs_io.readPlatformPath(file.path);
      expect(pathBytes.length, greaterThan(0));

      expect(file_system.isPlatformFile(file), isTrue);
      expect(file_system.platformFilePath(file), equals(file.path));
    });
  });
}
