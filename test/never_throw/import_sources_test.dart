// SPDX-License-Identifier: BSD-3-Clause
/// `import` and `convert` never throw because of their source: every source
/// they cannot read comes back as an empty activity with one error.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/sample_data.dart';

late Directory _dir;

void _expectFailure(
  ActivityImportResult result,
  String code, {
  ActivityFileFormat? format,
}) {
  expect(result.activity.points, isEmpty);
  expect(result.format, format);
  expect(
    result.diagnostics
        .where((d) => d.severity == ParseSeverity.error)
        .map((d) => d.code),
    [code],
  );
}

void main() {
  setUpAll(() => _dir = Directory.systemTemp.createTempSync('never_throw'));
  tearDownAll(() => _dir.deleteSync(recursive: true));

  group('import reports', () {
    test('a missing file, with the format its extension names', () async {
      _expectFailure(
        await ActivityFiles.import(File('${_dir.path}/missing.gpx')),
        'import.source.unreadable',
        format: ActivityFileFormat.gpx,
      );
    });

    test('a missing file without an extension', () async {
      _expectFailure(
        await ActivityFiles.import(File('${_dir.path}/missing')),
        'import.source.unreadable',
      );
    });

    test('a directory passed as a file', () async {
      _expectFailure(
        await ActivityFiles.import(File(_dir.path)),
        'import.source.unreadable',
      );
    });

    test('an unsupported source type', () async {
      _expectFailure(
        await ActivityFiles.import(42),
        'import.source.unsupported',
      );
    });

    for (final (label, source) in [
      ('an empty string', ''),
      ('whitespace', '  \n\t'),
      ('arbitrary text', 'hello world'),
      ('empty bytes', <int>[]),
    ]) {
      test('$label with no format given', () async {
        _expectFailure(
          await ActivityFiles.import(source),
          'parser.format_undetected',
        );
      });
    }

    test('an empty file with no extension', () async {
      final file = File('${_dir.path}/empty')..writeAsBytesSync([]);
      _expectFailure(
        await ActivityFiles.import(file),
        'parser.format_undetected',
      );
    });

    test('a stream that is not an activity file, and lets it go', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      // A full sniffing window of text, and the stream never ends.
      controller.add(List<int>.filled(70 * 1024, 0x7E));
      _expectFailure(
        await ActivityFiles.import(controller.stream),
        'parser.format_undetected',
      );
      expect(cancelled, isTrue);
    });

    test('a stream that fails while it is read', () async {
      _expectFailure(
        await ActivityFiles.import(
          Stream<List<int>>.error(const FileSystemException('boom')),
          format: ActivityFileFormat.gpx,
        ),
        'import.source.read_failed',
        format: ActivityFileFormat.gpx,
      );
    });

    for (final (label, source) in [
      ('bytes', List<int>.filled(2048, 0x20) as Object),
      ('text', ' ' * 2048),
      ('a stream', Stream.value(List<int>.filled(2048, 0x20))),
    ]) {
      test('$label over an explicit maxPayloadBytes', () async {
        _expectFailure(
          await ActivityFiles.import(
            source,
            format: ActivityFileFormat.gpx,
            maxPayloadBytes: 1024,
          ),
          'import.payload.too_large',
          format: ActivityFileFormat.gpx,
        );
      });
    }

    test('a file over an explicit maxPayloadBytes', () async {
      final file = File('${_dir.path}/big.gpx')..writeAsStringSync(' ' * 2048);
      _expectFailure(
        await ActivityFiles.import(file, maxPayloadBytes: 1024),
        'import.payload.too_large',
        format: ActivityFileFormat.gpx,
      );
    });
  });

  group('the soft limit', () {
    const over = 64 * 1024 * 1024 + 1;

    test('reads an activity file over 64 MB with a warning', () async {
      final padded = sampleGpx.replaceFirst(
        '</gpx>',
        '<!--${' ' * over}--></gpx>',
      );
      final file = File('${_dir.path}/large.gpx')..writeAsStringSync(padded);
      final result = await ActivityFiles.import(file);
      expect(result.activity.points, isNotEmpty);
      expect(
        result.diagnostics.map((d) => d.code),
        contains('import.payload.large'),
      );
    });

    test('refuses a file over 64 MB of no known format without loading '
        'it', () async {
      final file = File('${_dir.path}/large.bin')
        ..writeAsBytesSync(List<int>.filled(over, 0x7E));
      _expectFailure(
        await ActivityFiles.import(file),
        'parser.format_undetected',
      );
    });

    test('an explicit 64 MB is a hard cap', () async {
      _expectFailure(
        await ActivityFiles.import(
          List<int>.filled(over, 0x20),
          format: ActivityFileFormat.gpx,
          maxPayloadBytes: ActivityFiles.defaultMaxPayloadBytes,
        ),
        'import.payload.too_large',
        format: ActivityFileFormat.gpx,
      );
    });
  });

  group('convert reports', () {
    test('a source of no known format with a null source format', () async {
      final result = await ActivityFiles.convert(
        source: 'hello world',
        to: ActivityFileFormat.gpx,
      );
      expect(result.sourceFormat, isNull);
      expect(
        result.diagnostics.map((d) => d.code),
        contains('parser.format_undetected'),
      );
    });

    test('an unsupported source type', () async {
      final result = await ActivityFiles.convert(
        source: 42,
        to: ActivityFileFormat.fit,
      );
      expect(
        result.diagnostics.map((d) => d.code),
        contains('import.source.unsupported'),
      );
    });
  });

  // The end-to-end case stage 1 of 0.9.0 is measured by.
  for (final to in [ActivityFileFormat.geojson, ActivityFileFormat.fit]) {
    test('a GPX elevation of 1e308 converts to ${to.name}', () async {
      const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="46" lon="13"><ele>1e308</ele><time>2024-01-01T10:00:00Z</time></trkpt>
    <trkpt lat="46.001" lon="13.001"><ele>500</ele><time>2024-01-01T10:00:10Z</time></trkpt>
  </trkseg></trk>
</gpx>''';
      final result = await ActivityFiles.convert(
        source: gpx,
        from: ActivityFileFormat.gpx,
        to: to,
      );
      final back = await ActivityFiles.import(
        to == ActivityFileFormat.fit ? result.asBytes() : result.encoded,
        format: to,
      );
      expect(back.activity.points, hasLength(2));
    });
  }

  test('text with a byte-order mark is never detected as FIT', () async {
    // UTF-32LE byte-order mark, then a code point past U+10FFFF.
    final bytes = [0xFF, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00];
    expect(ActivityFiles.detectFormat(bytes), isNull);
    _expectFailure(
      await ActivityFiles.import(bytes),
      'parser.format_undetected',
    );
  });

  test('detectFormat returns null for what it cannot read', () {
    expect(ActivityFiles.detectFormat(42), isNull);
    expect(ActivityFiles.detectFormat(''), isNull);
    expect(ActivityFiles.detectFormat(File('${_dir.path}/missing')), isNull);
  });
}
