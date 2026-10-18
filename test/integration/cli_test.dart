// SPDX-License-Identifier: BSD-3-Clause
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

const _formats = ['gpx', 'tcx', 'fit', 'csv', 'geojson'];

late Directory _tempDir;
late String _cliPath;

/// Runs the compiled command-line tool the way a user does.
Future<ProcessResult> _cli(List<String> args) => Process.run(_cliPath, args);

String _temp(String name) => '${_tempDir.path}/$name';

ActivityFileFormat _format(String name) =>
    ActivityFileFormat.values.byName(name);

Future<ActivityImportResult> _importFile(String path, String format) =>
    ActivityFiles.import(
      File(path).readAsBytesSync(),
      format: _format(format),
      useIsolate: false,
    );

void _expectExit(ProcessResult result, int code) {
  expect(
    result.exitCode,
    code,
    reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
  );
}

void main() {
  /// One sample input per format; CSV and GeoJSON are made from the GPX.
  final samples = <String, String>{};

  setUpAll(() async {
    _tempDir = Directory.systemTemp.createTempSync('activity_files_cli');
    _cliPath = _temp(Platform.isWindows ? 'cli.exe' : 'cli');
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/activity_files.dart',
      '-o',
      _cliPath,
    ]);
    _expectExit(compile, 0);

    samples['gpx'] = 'example/assets/sample.gpx';
    samples['tcx'] = 'example/assets/sample.tcx';
    samples['fit'] = 'example/assets/sample.fit';
    for (final derived in ['csv', 'geojson']) {
      final path = _temp('sample.$derived');
      _expectExit(
        await _cli([
          'convert',
          '--from',
          'gpx',
          '--to',
          derived,
          '-i',
          samples['gpx']!,
          '-o',
          path,
        ]),
        0,
      );
      samples[derived] = path;
    }
  });

  tearDownAll(() {
    _tempDir.deleteSync(recursive: true);
  });

  List<String> gpxToTcx(String output) => [
    'convert',
    '--from',
    'gpx',
    '--to',
    'tcx',
    '-i',
    samples['gpx']!,
    '-o',
    output,
  ];

  group('help', () {
    test('without a command lists the commands', () async {
      final result = await _cli([]);
      _expectExit(result, 0);
      expect(result.stdout, contains('convert'));
      expect(result.stdout, contains('validate'));
    });

    test('--help lists the commands', () async {
      final result = await _cli(['--help']);
      _expectExit(result, 0);
      expect(result.stdout, contains('activity_files <command> --help'));
    });

    for (final (command, options) in [
      (
        'convert',
        [
          '--from',
          '--to',
          '--input',
          '--output',
          '--encoding',
          '--max-delta-seconds',
          '--precision-latlon',
          '--precision-ele',
          '--hr-max-delta',
          '--cadence-max-delta',
          '--power-max-delta',
          '--temp-max-delta',
          '--gpx-version',
          '--tcx-version',
        ],
      ),
      ('validate', ['--format', '--input', '--encoding', '--gap-threshold']),
    ]) {
      for (final flag in ['--help', '-h']) {
        test('$command $flag lists every option', () async {
          final result = await _cli([command, flag]);
          _expectExit(result, 0);
          expect(result.stdout, contains('activity_files $command'));
          for (final option in options) {
            expect(result.stdout, contains(option));
          }
        });
      }
    }

    test('an unknown option exits with 64', () async {
      _expectExit(await _cli(['convert', '--nope']), 64);
    });

    test('an unknown command exits with 64', () async {
      _expectExit(await _cli(['nope']), 64);
    });
  });

  group('convert', () {
    for (final from in _formats) {
      for (final to in _formats) {
        test('$from to $to writes what the library converts', () async {
          final output = _temp('out_${from}_to.$to');
          final result = await _cli([
            'convert',
            '--from',
            from,
            '--to',
            to,
            '-i',
            samples[from]!,
            '-o',
            output,
          ]);
          _expectExit(result, 0);
          final expected = await ActivityFiles.convert(
            source: File(samples[from]!).readAsBytesSync(),
            from: _format(from),
            to: _format(to),
            useIsolate: false,
          );
          expect(File(output).readAsBytesSync(), expected.asBytes());
        });
      }
    }

    test('writes FIT as binary', () async {
      final output = _temp('binary.fit');
      _expectExit(
        await _cli([
          'convert',
          '--from',
          'gpx',
          '--to',
          'fit',
          '-i',
          samples['gpx']!,
          '-o',
          output,
        ]),
        0,
      );
      final bytes = File(output).readAsBytesSync();
      expect(ascii.decode(bytes.sublist(8, 12)), '.FIT');
    });

    test('--precision-latlon limits the written digits', () async {
      final output = _temp('precision.gpx');
      _expectExit(
        await _cli([
          'convert',
          '--from',
          'gpx',
          '--to',
          'gpx',
          '-i',
          samples['gpx']!,
          '-o',
          output,
          '--precision-latlon',
          '2',
        ]),
        0,
      );
      final lats = RegExp(
        r'lat="([^"]+)"',
      ).allMatches(File(output).readAsStringSync()).map((m) => m[1]!);
      expect(lats, isNotEmpty);
      for (final lat in lats) {
        expect(lat.split('.').last.length, lessThanOrEqualTo(2));
      }
    });

    test('--gpx-version 1.0 writes GPX 1.0', () async {
      final output = _temp('v10.gpx');
      _expectExit(
        await _cli([
          'convert',
          '--from',
          'gpx',
          '--to',
          'gpx',
          '-i',
          samples['gpx']!,
          '-o',
          output,
          '--gpx-version',
          '1.0',
        ]),
        0,
      );
      expect(
        File(output).readAsStringSync(),
        contains('http://www.topografix.com/GPX/1/0'),
      );
    });

    test('--tcx-version 1 writes TCX v1', () async {
      final output = _temp('v1.tcx');
      _expectExit(await _cli([...gpxToTcx(output), '--tcx-version', '1']), 0);
      expect(
        File(output).readAsStringSync(),
        contains('TrainingCenterDatabase/v1'),
      );
    });

    test('accepts every matching tolerance', () async {
      final output = _temp('tolerances.tcx');
      _expectExit(
        await _cli([
          ...gpxToTcx(output),
          '--max-delta-seconds',
          '2',
          '--hr-max-delta',
          '1',
          '--cadence-max-delta',
          '1.5',
          '--power-max-delta',
          '0',
          '--temp-max-delta',
          '10',
          '--precision-ele',
          '1',
        ]),
        0,
      );
    });

    for (final (option, value) in [
      ('--precision-latlon', 'abc'),
      ('--precision-latlon', '-3'),
      ('--precision-latlon', '21'),
      ('--precision-ele', '2.5'),
      ('--max-delta-seconds', '-5'),
      ('--max-delta-seconds', 'NaN'),
      ('--hr-max-delta', 'x'),
      ('--cadence-max-delta', '-1'),
      ('--power-max-delta', 'Infinity'),
      ('--temp-max-delta', ''),
    ]) {
      test('rejects $option "$value" with 64', () async {
        final output = _temp('rejected.tcx');
        final result = await _cli([...gpxToTcx(output), option, value]);
        _expectExit(result, 64);
        expect(result.stderr, contains(option));
        expect(File(output).existsSync(), isFalse);
      });
    }

    test('requires --from, --to, --input and --output', () async {
      final result = await _cli([
        'convert',
        '--to',
        'tcx',
        '-i',
        samples['gpx']!,
        '-o',
        _temp('x.tcx'),
      ]);
      _expectExit(result, 64);
      expect(result.stderr, contains('--from'));
    });

    test('a missing input file exits with 66', () async {
      final result = await _cli([
        'convert',
        '--from',
        'gpx',
        '--to',
        'tcx',
        '-i',
        _temp('missing.gpx'),
        '-o',
        _temp('x.tcx'),
      ]);
      _expectExit(result, 66);
    });

    test(
      'a file the parser rejects exits with 65 and writes nothing',
      () async {
        final junk = _temp('junk.gpx');
        File(junk).writeAsStringSync('not an activity');
        final output = _temp('junk.tcx');
        final result = await _cli([
          'convert',
          '--from',
          'gpx',
          '--to',
          'tcx',
          '-i',
          junk,
          '-o',
          output,
        ]);
        _expectExit(result, 65);
        expect(File(output).existsSync(), isFalse);
      },
    );

    test('an unwritable output path exits with 70', () async {
      _expectExit(await _cli(gpxToTcx(_temp('no/such/dir/x.tcx'))), 70);
    });
  });

  group('encoding', () {
    late String latin1Gpx;

    setUpAll(() {
      final gpx = File(
        samples['gpx']!,
      ).readAsStringSync().replaceFirst('<name>', '<name>Müller ');
      latin1Gpx = _temp('latin1.gpx');
      File(latin1Gpx).writeAsBytesSync(latin1.encode(gpx));
    });

    test('convert works with the default encoding', () async {
      final output = _temp('default.tcx');
      _expectExit(await _cli(gpxToTcx(output)), 0);
      expect(File(output).existsSync(), isTrue);
    });

    for (final name in ['utf8', 'utf-8', 'UTF-8']) {
      test('convert accepts $name', () async {
        _expectExit(
          await _cli([...gpxToTcx(_temp('$name.tcx')), '--encoding', name]),
          0,
        );
      });
    }

    test('convert reads a Latin-1 file with --encoding latin1', () async {
      final output = _temp('latin1.gpx.out');
      _expectExit(
        await _cli([
          'convert',
          '--from',
          'gpx',
          '--to',
          'gpx',
          '-i',
          latin1Gpx,
          '-o',
          output,
          '--encoding',
          'latin1',
        ]),
        0,
      );
      expect(File(output).readAsStringSync(), contains('Müller'));
    });

    test('validate reads a Latin-1 file with --encoding latin1', () async {
      _expectExit(
        await _cli([
          'validate',
          '--format',
          'gpx',
          '-i',
          latin1Gpx,
          '--encoding',
          'latin1',
        ]),
        0,
      );
    });

    test('validate reports a wrong encoding as unreadable', () async {
      final result = await _cli([
        'validate',
        '--format',
        'gpx',
        '-i',
        latin1Gpx,
      ]);
      _expectExit(result, 65);
      expect(result.stdout, contains('could not be read'));
    });

    for (final command in ['convert', 'validate']) {
      test('$command rejects an unknown encoding with 64', () async {
        final output = _temp('unknown.tcx');
        final args = command == 'convert'
            ? gpxToTcx(output)
            : ['validate', '--format', 'gpx', '-i', samples['gpx']!];
        final result = await _cli([...args, '--encoding', 'klingon']);
        _expectExit(result, 64);
        expect(result.stderr, contains('Unknown encoding "klingon"'));
        expect(File(output).existsSync(), isFalse);
      });
    }
  });

  group('validate', () {
    for (final format in _formats) {
      test('judges the $format sample like the library', () async {
        final result = await _cli([
          'validate',
          '--format',
          format,
          '-i',
          samples[format]!,
        ]);
        final imported = await _importFile(samples[format]!, format);
        final validation = ActivityFiles.validate(imported.activity);
        if (validation.errors.isEmpty) {
          _expectExit(result, 0);
          expect(result.stdout, contains('Validation passed'));
        } else {
          _expectExit(result, 65);
          for (final error in validation.errors) {
            expect(result.stdout, contains(error));
          }
        }
      });
    }

    for (final (label, content) in [
      ('a junk file', 'not an activity'),
      ('an empty file', ''),
    ]) {
      test('fails $label with 65', () async {
        final path = _temp('invalid.gpx');
        File(path).writeAsStringSync(content);
        final result = await _cli(['validate', '--format', 'gpx', '-i', path]);
        _expectExit(result, 65);
        expect(result.stdout, contains('could not be read'));
        expect(result.stdout, isNot(contains('Validation passed')));
      });
    }

    test('fails a file given the wrong --format with 65', () async {
      final result = await _cli([
        'validate',
        '--format',
        'gpx',
        '-i',
        samples['fit']!,
      ]);
      _expectExit(result, 65);
    });

    test('--gap-threshold reports shorter gaps', () async {
      final result = await _cli([
        'validate',
        '--format',
        'gpx',
        '-i',
        samples['gpx']!,
        '--gap-threshold',
        '0.001',
      ]);
      _expectExit(result, 0);
      expect(result.stdout, contains('Warnings:'));
    });

    for (final value in ['0', '-1', 'abc']) {
      test('rejects --gap-threshold "$value" with 64', () async {
        final result = await _cli([
          'validate',
          '--format',
          'gpx',
          '-i',
          samples['gpx']!,
          '--gap-threshold',
          value,
        ]);
        _expectExit(result, 64);
        expect(result.stderr, contains('--gap-threshold'));
      });
    }

    test('requires --format and --input', () async {
      _expectExit(await _cli(['validate', '-i', samples['gpx']!]), 64);
    });

    test('a missing input file exits with 66', () async {
      _expectExit(
        await _cli(['validate', '--format', 'gpx', '-i', _temp('missing.gpx')]),
        66,
      );
    });
  });

  group('documentation', () {
    test('the package declares the activity_files executable', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec,
        matches(RegExp(r'executables:\s*\n\s+activity_files: activity_files')),
      );
    });

    test('every documented command and option exists', () async {
      final guide = File('doc/usage_guide.md').readAsStringSync();
      final section = guide.substring(guide.indexOf('## CLI usage'));
      final invocations = RegExp(
        r'dart run activity_files (\w+)((?:[^\n]*\\\n)*[^\n]*)',
      ).allMatches(section).toList();
      expect(invocations, isNotEmpty);
      expect(section, isNot(contains('activity_files:activity_files')));
      for (final invocation in invocations) {
        final command = invocation[1]!;
        final help = await _cli([command, '--help']);
        _expectExit(help, 0);
        for (final option in RegExp(
          r'--[a-z][a-z-]*',
        ).allMatches(invocation[2]!).map((m) => m[0]!)) {
          expect(
            help.stdout,
            contains(option),
            reason: '$command documents $option',
          );
        }
      }
    });
  });
}
