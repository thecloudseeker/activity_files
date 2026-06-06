import 'dart:io';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';
import 'package:activity_files/activity_files.dart';

void main() {
  test('pubspec.yaml has semantic version', () {
    final pub = File('pubspec.yaml');
    expect(pub.existsSync(), isTrue);
    final content = pub.readAsStringSync();
    final doc = loadYaml(content);
    final version = doc['version'] as String?;
    expect(version, isNotNull);
    expect(RegExp(r'^\d+\.\d+\.\d+').hasMatch(version!), isTrue);
  });

  test('CHANGELOG.md exists and mentions current version', () {
    final changelog = File('CHANGELOG.md');
    expect(changelog.existsSync(), isTrue);
    final pub = File('pubspec.yaml');
    final version = loadYaml(pub.readAsStringSync())['version'] as String;
    final text = changelog.readAsStringSync();
    expect(text.contains(version), isTrue);
  });

  group('Release readiness', () {
    test('pubspec.yaml has semantic version', () async {
      final pubspecFile = File('pubspec.yaml');
      expect(pubspecFile.existsSync(), isTrue);

      final content = await pubspecFile.readAsString();
      final versionMatch = RegExp(r'version:\s*([0-9.]+)').firstMatch(content);
      final version = versionMatch?.group(1);

      expect(version, isNotNull);
      expect(
        version,
        matches(RegExp(r'^\d+\.\d+\.\d+(?:-[\w.]+)?(?:\+[\w.]+)?$')),
        reason: 'Version should be semantic (e.g., 0.4.3 or 1.0.0-beta+meta)',
      );
    });

    test('CHANGELOG.md exists and is not empty', () async {
      final changelogFile = File('CHANGELOG.md');
      expect(changelogFile.existsSync(), isTrue);

      final content = await changelogFile.readAsString();
      expect(content, isNotEmpty);
      expect(
        content,
        contains('##'),
        reason: 'CHANGELOG should have version headers',
      );
    });

    test('CHANGELOG contains current version', () async {
      final pubspecFile = File('pubspec.yaml');
      final changelogFile = File('CHANGELOG.md');

      final pubspecContent = await pubspecFile.readAsString();
      final changelogContent = await changelogFile.readAsString();

      final versionMatch = RegExp(
        r'version:\s*([0-9.]+)',
      ).firstMatch(pubspecContent);
      final version = versionMatch?.group(1);

      expect(version, isNotNull);
      expect(
        changelogContent,
        contains(version!),
        reason: 'CHANGELOG.md should reference the version in pubspec.yaml',
      );
    });

    test('example assets directory exists', () async {
      final assetsDir = Directory('example/assets');
      expect(
        assetsDir.existsSync(),
        isTrue,
        reason: 'example/assets directory should exist',
      );

      final files = await assetsDir.list().toList();
      expect(
        files,
        isNotEmpty,
        reason: 'example/assets should contain sample files',
      );
    });

    test('sample files are accessible and loadable', () async {
      const sampleFiles = ['sample.gpx', 'sample.tcx', 'sample.fit'];

      for (final filename in sampleFiles) {
        final file = File('example/assets/$filename');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'example/assets/$filename should exist',
        );

        final bytes = await file.readAsBytes();
        expect(bytes, isNotEmpty, reason: '$filename should not be empty');

        // Verify file is readable by the parser
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
        expect(result.format, equals(format));
      }
    });

    test('README.md exists and documents key features', () async {
      final readmeFile = File('README.md');
      expect(readmeFile.existsSync(), isTrue);

      final content = await readmeFile.readAsString();
      expect(content, contains('activity_files'));
      expect(content.toLowerCase(), contains('gpx'));
      expect(content.toLowerCase(), contains('fit'));
      expect(content.toLowerCase(), contains('tcx'));
    });

    test('LICENSE file exists', () async {
      final licenseFile = File('LICENSE');
      expect(licenseFile.existsSync(), isTrue);

      final content = await licenseFile.readAsString();
      expect(content, isNotEmpty);
      final upper = content.toUpperCase();
      expect(upper.contains('BSD') || upper.contains('LICENSE'), isTrue);
    });

    test('lib/activity_files.dart main export exists', () async {
      final mainFile = File('lib/activity_files.dart');
      expect(mainFile.existsSync(), isTrue);

      final content = await mainFile.readAsString();
      expect(content.toLowerCase(), contains('export'));
    });

    test('pubspec.yaml has required metadata', () async {
      final pubspecFile = File('pubspec.yaml');
      final content = await pubspecFile.readAsString();

      expect(content, contains('name:'));
      expect(content, contains('version:'));
      expect(content, contains('description:'));
      expect(content, contains('dependencies:'));
    });
  });
}
