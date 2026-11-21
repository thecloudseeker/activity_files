// SPDX-License-Identifier: BSD-3-Clause
/// Damaged copies of the public fixtures go through `import` and every
/// export: none may throw, and each runs in its own isolate with a time
/// limit, so a hang fails like a throw does.
///
/// The seed is fixed so CI is repeatable; set `ACTIVITY_FILES_FUZZ_SEED` to
/// explore others. A failing input belongs in `test/fixtures/fuzz/` as a
/// regression case.
@TestOn('vm')
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

const _defaultSeed = 20261021;
const _timeLimit = Duration(seconds: 30);

const _sources = {
  'example/assets/sample.gpx': ActivityFileFormat.gpx,
  'example/assets/sample.tcx': ActivityFileFormat.tcx,
  'example/assets/sample.fit': ActivityFileFormat.fit,
  'example/assets/synthetic/clean_run.gpx': ActivityFileFormat.gpx,
  'example/assets/synthetic/clean_run.tcx': ActivityFileFormat.tcx,
  'example/assets/synthetic/clean_run.fit': ActivityFileFormat.fit,
  'test/fixtures/real_world/garmin-fenix-5-bike.fit': ActivityFileFormat.fit,
  'test/fixtures/fuzz_seeds/sample.csv': ActivityFileFormat.csv,
  'test/fixtures/fuzz_seeds/sample.geojson': ActivityFileFormat.geojson,
};

const _nonFinite = ['NaN', 'Infinity', '-Infinity', '1e308', '1e999', '-0'];

final _number = RegExp(r'-?\d+(\.\d+)?');

/// Damaged variants of [bytes], each with a label for the failure report.
Map<String, Uint8List> _mutants(Uint8List bytes, bool text, Random random) {
  final mutants = <String, Uint8List>{};
  int at() => random.nextInt(max(bytes.length, 1));
  for (var i = 0; i < 4; i++) {
    final cut = at();
    mutants['truncated at $cut'] = Uint8List.sublistView(bytes, 0, cut);
  }
  for (var i = 0; i < 6; i++) {
    final copy = Uint8List.fromList(bytes);
    final flips = 1 + random.nextInt(8);
    final where = <int>[];
    for (var f = 0; f < flips && copy.isNotEmpty; f++) {
      final p = at();
      copy[p] ^= 1 << random.nextInt(8);
      where.add(p);
    }
    mutants['bits flipped at $where'] = copy;
  }
  for (var i = 0; i < 3; i++) {
    final from = at();
    final to = min(bytes.length, from + 1 + random.nextInt(512));
    mutants['bytes $from..$to deleted'] = Uint8List.fromList([
      ...bytes.sublist(0, from),
      ...bytes.sublist(to),
    ]);
  }
  for (var i = 0; i < 2; i++) {
    final from = at();
    final to = min(bytes.length, from + 1 + random.nextInt(512));
    mutants['bytes $from..$to doubled'] = Uint8List.fromList([
      ...bytes.sublist(0, to),
      ...bytes.sublist(from),
    ]);
  }
  if (text) {
    final source = String.fromCharCodes(bytes);
    for (final literal in _nonFinite) {
      var count = 0;
      final replaced = source.replaceAllMapped(_number, (m) {
        if (random.nextInt(4) != 0) return m[0]!;
        count++;
        return literal;
      });
      mutants['$count numbers set to $literal'] = Uint8List.fromList(
        replaced.codeUnits,
      );
    }
    final p = at();
    mutants['invalid UTF-8 at $p'] = Uint8List.fromList([
      ...bytes.sublist(0, p),
      0xC3,
      0x28,
      0xFF,
      ...bytes.sublist(p),
    ]);
  } else {
    // FIT header: header size, protocol, data size and the ".FIT" tag.
    for (final (offset, value) in [(0, 255), (0, 2), (4, 255), (7, 255)]) {
      final copy = Uint8List.fromList(bytes)..[offset] = value;
      mutants['header byte $offset set to $value'] = copy;
    }
    for (var i = 0; i < 2; i++) {
      // A second copy of the data section after the first, so definitions
      // and records repeat.
      mutants['data section repeated $i'] = Uint8List.fromList([
        ...bytes.sublist(0, bytes.length - 2),
        ...bytes.sublist(14, bytes.length - 2),
        ...bytes.sublist(bytes.length - 2),
      ]);
    }
  }
  return mutants;
}

/// Runs every entry point on [bytes] and returns what threw.
Future<List<String>> _exercise(
  Uint8List bytes,
  ActivityFileFormat format,
) async {
  final failures = <String>[];
  Future<void> guard(String step, Future<void> Function() body) async {
    try {
      await body();
    } catch (error) {
      failures.add('$step: ${error.runtimeType}: $error'.split('\n').first);
    }
  }

  RawActivity? activity;
  await guard('import', () async {
    final result = await ActivityFiles.import(
      bytes,
      format: format,
      useIsolate: false,
    );
    activity = result.activity;
  });
  await guard('import (detected)', () async {
    await ActivityFiles.import(bytes, useIsolate: false);
  });
  await guard('detectFormat', () async {
    ActivityFiles.detectFormat(bytes);
  });
  final parsed = activity;
  if (parsed == null) return failures;
  for (final to in ActivityFileFormat.values) {
    for (final normalize in [true, false]) {
      await guard('export to ${to.name} (normalize: $normalize)', () async {
        ActivityFiles.export(activity: parsed, to: to, normalize: normalize);
      });
    }
  }
  return failures;
}

const _formatByExtension = {
  'gpx': ActivityFileFormat.gpx,
  'tcx': ActivityFileFormat.tcx,
  'fit': ActivityFileFormat.fit,
  'csv': ActivityFileFormat.csv,
  'geojson': ActivityFileFormat.geojson,
};

void main() {
  group('regression inputs found by fuzzing', () {
    final files = Directory('test/fixtures/fuzz').listSync().whereType<File>();
    for (final file in files) {
      final format = _formatByExtension[file.path.split('.').last]!;
      test(file.uri.pathSegments.last, () async {
        final bytes = file.readAsBytesSync();
        final failures = await Isolate.run(
          () => _exercise(bytes, format),
        ).timeout(_timeLimit);
        expect(failures, isEmpty);
      });
    }
  });

  final seed =
      int.tryParse(Platform.environment['ACTIVITY_FILES_FUZZ_SEED'] ?? '') ??
      _defaultSeed;

  group('fuzzed fixtures (seed $seed)', () {
    for (final MapEntry(key: name, value: format) in _sources.entries) {
      final bytes = File(name).readAsBytesSync();
      final random = Random(seed ^ name.hashCode);
      final mutants = _mutants(bytes, format != ActivityFileFormat.fit, random);
      for (final MapEntry(key: label, value: mutant) in mutants.entries) {
        test('$name, $label', () async {
          final failures = await Isolate.run(
            () => _exercise(mutant, format),
          ).timeout(_timeLimit);
          expect(failures, isEmpty);
        });
      }
    }
  });
}
