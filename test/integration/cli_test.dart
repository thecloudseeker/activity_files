// SPDX-License-Identifier: BSD-3-Clause
/// Runs the compiled `activity_files` command line and holds it to the
/// library: wherever the command line does what a library call does, its
/// output must equal the library's byte for byte.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../helpers/fit_helpers.dart';

const _formats = ['gpx', 'tcx', 'fit', 'csv', 'geojson'];
const _commands = ['convert', 'edit', 'merge', 'split', 'validate', 'inspect'];

late Directory _tempDir;
late String _cliPath;

/// One sample input per format; CSV and GeoJSON are made from the GPX.
final _samples = <String, String>{};

Future<ProcessResult> _cli(List<String> args) => Process.run(_cliPath, args);

/// Runs the command line with [input] on stdin; stdout comes back as bytes.
Future<ProcessResult> _cliWithStdin(List<String> args, List<int> input) async {
  final process = await Process.start(_cliPath, args);
  process.stdin.add(input);
  await process.stdin.close();
  final out = <int>[];
  final err = StringBuffer();
  await Future.wait([
    process.stdout.forEach(out.addAll),
    process.stderr.transform(utf8.decoder).forEach(err.write),
  ]);
  return ProcessResult(process.pid, await process.exitCode, out, '$err');
}

String _temp(String name) => '${_tempDir.path}/$name';

ActivityFileFormat _format(String name) =>
    ActivityFileFormat.values.byName(name);

Future<ActivityImportResult> _import(String path, [String? format]) =>
    ActivityFiles.import(
      File(path),
      format: format == null ? null : _format(format),
      useIsolate: false,
    );

void _expectExit(ProcessResult result, int code) {
  expect(
    result.exitCode,
    code,
    reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
  );
}

/// The first and last recorded sample, as the command line's times use them.
({DateTime start, DateTime end}) _bounds(RawActivity activity) {
  final times = [
    for (final point in activity.points) point.time,
    for (final samples in activity.channels.values)
      for (final sample in samples) sample.time,
  ]..sort();
  return (start: times.first, end: times.last);
}

Future<String> _help(String command) async =>
    (await _cli([command, '--help'])).stdout as String;

/// Every option a command's `--help` lists, without `--[no-]`.
Set<String> _optionsIn(String help) => {
  for (final match in RegExp(
    r'--(?:\[no-\])?([a-z0-9][a-z0-9-]*)',
  ).allMatches(help))
    match[1]!,
};

void main() {
  setUpAll(() async {
    _tempDir = Directory.systemTemp.createTempSync('activity_files_cli');
    _cliPath = _temp(Platform.isWindows ? 'cli.exe' : 'cli');
    _expectExit(
      await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'bin/activity_files.dart',
        '-o',
        _cliPath,
      ]),
      0,
    );
    _samples['gpx'] = 'example/assets/sample.gpx';
    _samples['tcx'] = 'example/assets/sample.tcx';
    _samples['fit'] = 'example/assets/sample.fit';
    for (final derived in ['csv', 'geojson']) {
      final path = _temp('sample.$derived');
      _expectExit(
        await _cli([
          'convert',
          '--to',
          derived,
          '-i',
          _samples['gpx']!,
          '-o',
          path,
        ]),
        0,
      );
      _samples[derived] = path;
    }
  });

  tearDownAll(() {
    _tempDir.deleteSync(recursive: true);
  });

  List<String> gpxTo(String to, String output) => [
    'convert',
    '--to',
    to,
    '-i',
    _samples['gpx']!,
    '-o',
    output,
  ];

  group('help and version', () {
    test('without a command lists every command', () async {
      final result = await _cli([]);
      _expectExit(result, 0);
      for (final command in _commands) {
        expect(result.stdout, contains(command));
      }
    });

    test('--version prints the pubspec version', () async {
      final result = await _cli(['--version']);
      _expectExit(result, 0);
      final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as Map;
      expect(
        (result.stdout as String).trim(),
        'activity_files ${pubspec['version']}',
      );
    });

    for (final command in _commands) {
      for (final flag in ['--help', '-h']) {
        test('$command $flag shows its usage', () async {
          final result = await _cli([command, flag]);
          _expectExit(result, 0);
          expect(result.stdout, contains('activity_files $command'));
          expect(result.stdout, contains('--input'));
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
          _expectExit(
            await _cli([
              'convert',
              '--from',
              from,
              '--to',
              to,
              '-i',
              _samples[from]!,
              '-o',
              output,
            ]),
            0,
          );
          final expected = await ActivityFiles.convert(
            source: File(_samples[from]!),
            from: _format(from),
            to: _format(to),
            useIsolate: false,
          );
          expect(File(output).readAsBytesSync(), expected.asBytes());
        });
      }
    }

    test('detects the input format when --from is left out', () async {
      final output = _temp('detected.tcx');
      _expectExit(
        await _cli([
          'convert',
          '--to',
          'tcx',
          '-i',
          _samples['fit']!,
          '-o',
          output,
        ]),
        0,
      );
      final expected = await ActivityFiles.convert(
        source: File(_samples['fit']!),
        to: ActivityFileFormat.tcx,
        useIsolate: false,
      );
      expect(File(output).readAsBytesSync(), expected.asBytes());
    });

    test('writes FIT as binary', () async {
      final output = _temp('binary.fit');
      _expectExit(await _cli(gpxTo('fit', output)), 0);
      expect(
        ascii.decode(File(output).readAsBytesSync().sublist(8, 12)),
        '.FIT',
      );
    });

    test('every EncoderOptions field matches the library', () async {
      final output = _temp('options.geojson');
      _expectExit(
        await _cli([
          ...gpxTo('geojson', output),
          '--precision-latlon',
          '3',
          '--precision-ele',
          '1',
          '--max-delta-seconds',
          '2',
          '--channel-max-delta',
          'heart_rate=1',
          '--channel-max-delta',
          'my_custom=500ms',
          '--geojson-geometry',
          'points',
          '--geojson-channels',
        ]),
        0,
      );
      final expected = await ActivityFiles.convert(
        source: File(_samples['gpx']!),
        to: ActivityFileFormat.geojson,
        options: EncoderOptions(
          precisionLatLon: 3,
          precisionEle: 1,
          defaultMaxDelta: const Duration(seconds: 2),
          maxDeltaPerChannel: {
            Channel.heartRate: const Duration(seconds: 1),
            Channel.custom('my_custom'): const Duration(milliseconds: 500),
          },
          geojsonGeometry: GeojsonGeometry.points,
          geojsonIncludeChannels: true,
        ),
        useIsolate: false,
      );
      expect(File(output).readAsBytesSync(), expected.asBytes());
    });

    for (final (option, value, version, marker) in [
      ('--gpx-version', '1.0', 'gpx', 'http://www.topografix.com/GPX/1/0'),
      ('--tcx-version', '1', 'tcx', 'TrainingCenterDatabase/v1'),
    ]) {
      test('$option $value', () async {
        final output = _temp('version.$version');
        _expectExit(await _cli([...gpxTo(version, output), option, value]), 0);
        expect(File(output).readAsStringSync(), contains(marker));
      });
    }

    test('--no-normalize and --no-validate match the library', () async {
      final output = _temp('raw.gpx');
      _expectExit(
        await _cli([
          'convert',
          '--to',
          'gpx',
          '-i',
          _samples['tcx']!,
          '-o',
          output,
          '--no-normalize',
          '--no-validate',
        ]),
        0,
      );
      final expected = await ActivityFiles.convert(
        source: File(_samples['tcx']!),
        to: ActivityFileFormat.gpx,
        normalize: false,
        runValidation: false,
        useIsolate: false,
      );
      expect(File(output).readAsBytesSync(), expected.asBytes());
    });

    test('--auto-fix with its options matches the library', () async {
      final output = _temp('autofix.gpx');
      _expectExit(
        await _cli([
          ...gpxTo('gpx', output),
          '--auto-fix',
          '--no-fix-timestamp-gaps',
          '--auto-lap',
          '--auto-lap-always',
          '--auto-lap-distance',
          '50',
        ]),
        0,
      );
      final expected = await ActivityFiles.convert(
        source: File(_samples['gpx']!),
        to: ActivityFileFormat.gpx,
        autoFix: const ActivityAutoFixOptions(
          fixTimestampGaps: false,
          autoLapByDistance: true,
          autoLapOnlyWhenMissing: false,
          autoLapDistanceMeters: 50,
        ),
        useIsolate: false,
      );
      expect(File(output).readAsBytesSync(), expected.asBytes());
    });

    test('auto-fix options without --auto-fix exit with 64', () async {
      final result = await _cli([
        ...gpxTo('gpx', _temp('x.gpx')),
        '--auto-lap',
      ]);
      _expectExit(result, 64);
      expect(result.stderr, contains('--auto-fix'));
    });

    test('--strict-fit refuses a damaged FIT file with 65', () async {
      final damaged = File(_samples['fit']!).readAsBytesSync();
      damaged[damaged.length - 1] ^= 0xFF;
      final path = _temp('damaged.fit');
      File(path).writeAsBytesSync(damaged);
      final output = _temp('damaged.gpx');
      _expectExit(
        await _cli(['convert', '--to', 'gpx', '-i', path, '-o', output]),
        0,
      );
      _expectExit(
        await _cli([
          'convert',
          '--to',
          'gpx',
          '-i',
          path,
          '-o',
          output,
          '--strict-fit',
        ]),
        65,
      );
    });

    test('--max-payload-bytes refuses a larger file with 65', () async {
      _expectExit(
        await _cli([
          ...gpxTo('tcx', _temp('limited.tcx')),
          '--max-payload-bytes',
          '100',
        ]),
        65,
      );
      _expectExit(
        await _cli([
          ...gpxTo('tcx', _temp('unlimited.tcx')),
          '--max-payload-bytes',
          'none',
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
      ('--max-delta-seconds', '5x'),
      ('--channel-max-delta', 'heart_rate'),
      ('--channel-max-delta', 'heart_rate=fast'),
      ('--max-payload-bytes', '0'),
      ('--encoding', 'klingon'),
    ]) {
      test('rejects $option "$value" with 64', () async {
        final output = _temp('rejected.tcx');
        final result = await _cli([...gpxTo('tcx', output), option, value]);
        _expectExit(result, 64);
        expect(
          result.stderr,
          option == '--encoding' ? contains('klingon') : contains(option),
        );
        expect(File(output).existsSync(), isFalse);
      });
    }

    test('requires --to', () async {
      final result = await _cli([
        'convert',
        '-i',
        _samples['gpx']!,
        '-o',
        _temp('x.tcx'),
      ]);
      _expectExit(result, 64);
      expect(result.stderr, contains('--to'));
    });

    test('a missing input exits with 66', () async {
      _expectExit(
        await _cli([
          'convert',
          '--to',
          'tcx',
          '-i',
          _temp('missing.gpx'),
          '-o',
          _temp('x.tcx'),
        ]),
        66,
      );
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
      _expectExit(await _cli(gpxTo('tcx', _temp('no/such/dir/x.tcx'))), 70);
    });

    test('messages go to stderr, stdout stays empty', () async {
      final result = await _cli(gpxTo('tcx', _temp('quiet.tcx')));
      _expectExit(result, 0);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('Converted'));
    });

    test('--json reports one JSON line per file on stderr', () async {
      final output = _temp('json.tcx');
      final result = await _cli([...gpxTo('tcx', output), '--json']);
      _expectExit(result, 0);
      final record =
          jsonDecode((result.stderr as String).trim()) as Map<String, Object?>;
      expect(record['input'], _samples['gpx']);
      expect(record['output'], output);
      expect(record['written'], isTrue);
      expect(record['diagnostics'], isA<List<Object?>>());
    });
  });

  group('deprecated options', () {
    test('validate --format works like --from and warns', () async {
      final legacy = await _cli([
        'validate',
        '--format',
        'gpx',
        '-i',
        _samples['gpx']!,
      ]);
      final current = await _cli([
        'validate',
        '--from',
        'gpx',
        '-i',
        _samples['gpx']!,
      ]);
      expect(legacy.exitCode, current.exitCode);
      expect(legacy.stdout, current.stdout);
      expect(legacy.stderr, contains('--format is deprecated'));
      expect(legacy.stderr, contains('--from'));
      expect(legacy.stderr, contains('0.10.0'));
      expect(current.stderr, isNot(contains('deprecated')));
    });

    for (final (option, channel) in [
      ('--hr-max-delta', 'heart_rate'),
      ('--cadence-max-delta', 'cadence'),
      ('--power-max-delta', 'power'),
      ('--temp-max-delta', 'temperature'),
    ]) {
      test(
        '$option 5 works like --channel-max-delta $channel=5 and warns',
        () async {
          final legacyOutput = _temp('legacy-$channel.tcx');
          final currentOutput = _temp('current-$channel.tcx');
          final legacy = await _cli([
            ...gpxTo('tcx', legacyOutput),
            option,
            '5',
          ]);
          _expectExit(legacy, 0);
          _expectExit(
            await _cli([
              ...gpxTo('tcx', currentOutput),
              '--channel-max-delta',
              '$channel=5',
            ]),
            0,
          );
          expect(
            File(legacyOutput).readAsBytesSync(),
            File(currentOutput).readAsBytesSync(),
          );
          expect(legacy.stderr, contains('$option is deprecated'));
          expect(legacy.stderr, contains('--channel-max-delta $channel='));
        },
      );
    }

    test('next to its replacement, the replacement wins', () async {
      final both = _temp('both-hr.tcx');
      final current = _temp('current-hr.tcx');
      _expectExit(
        await _cli([
          ...gpxTo('tcx', both),
          '--hr-max-delta',
          '1',
          '--channel-max-delta',
          'heart_rate=5',
        ]),
        0,
      );
      _expectExit(
        await _cli([
          ...gpxTo('tcx', current),
          '--channel-max-delta',
          'heart_rate=5',
        ]),
        0,
      );
      expect(File(both).readAsBytesSync(), File(current).readAsBytesSync());

      final validate = await _cli([
        'validate',
        '--format',
        'tcx',
        '--from',
        'gpx',
        '-i',
        _samples['gpx']!,
      ]);
      _expectExit(validate, 0);
      expect(validate.stderr, contains('--format is deprecated'));
    });

    test('with --json the warning is a JSON line', () async {
      final result = await _cli([
        ...gpxTo('tcx', _temp('json-legacy.tcx')),
        '--hr-max-delta',
        '5',
        '--json',
      ]);
      _expectExit(result, 0);
      final lines = (result.stderr as String).trim().split('\n');
      final warning = jsonDecode(lines.first) as Map<String, Object?>;
      expect(warning['warning'], contains('--hr-max-delta is deprecated'));
      for (final line in lines) {
        expect(() => jsonDecode(line), returnsNormally);
      }
    });

    test('--help does not list them', () async {
      expect(await _help('validate'), isNot(contains('--format')));
      expect(await _help('convert'), isNot(contains('--hr-max-delta')));
    });
  });

  group('encoding', () {
    late String latin1Gpx;

    setUpAll(() {
      final gpx = File(
        _samples['gpx']!,
      ).readAsStringSync().replaceFirst('<name>', '<name>Müller ');
      latin1Gpx = _temp('latin1.gpx');
      File(latin1Gpx).writeAsBytesSync(latin1.encode(gpx));
    });

    test('convert works with the default encoding', () async {
      _expectExit(await _cli(gpxTo('tcx', _temp('default.tcx'))), 0);
    });

    for (final name in ['utf8', 'utf-8', 'UTF-8']) {
      test('convert accepts $name', () async {
        _expectExit(
          await _cli([...gpxTo('tcx', _temp('$name.tcx')), '--encoding', name]),
          0,
        );
      });
    }

    test('convert reads a Latin-1 file with --encoding latin1', () async {
      final output = _temp('latin1.out.gpx');
      _expectExit(
        await _cli([
          'convert',
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
        await _cli(['validate', '-i', latin1Gpx, '--encoding', 'latin1']),
        0,
      );
    });

    test('validate reports a wrong encoding as unreadable', () async {
      final result = await _cli(['validate', '-i', latin1Gpx]);
      _expectExit(result, 65);
      expect(result.stdout, contains('could not be read'));
    });
  });

  group('edit', () {
    /// Runs `edit` with [steps] on the FIT sample and compares the written
    /// bytes with the library's result for [chain].
    Future<void> expectStepsMatch(
      List<String> steps,
      RawEditor Function(RawEditor editor, ({DateTime start, DateTime end}) b)
      chain, {
      String to = 'fit',
    }) async {
      final output = _temp('edited.$to');
      _expectExit(
        await _cli([
          'edit',
          '-i',
          _samples['fit']!,
          '-o',
          output,
          '--to',
          to,
          ...steps,
        ]),
        0,
      );
      final imported = await _import(_samples['fit']!);
      final edited = chain(
        RawEditor(imported.activity),
        _bounds(imported.activity),
      ).activity;
      final expected = ActivityFiles.export(activity: edited, to: _format(to));
      expect(File(output).readAsBytesSync(), expected.asBytes());
    }

    test('steps run in the order typed', () async {
      await expectStepsMatch(
        ['--crop', '10s..end', '--recompute-distance-and-speed'],
        (e, b) => e
            .crop(b.start.add(const Duration(seconds: 10)), b.end)
            .recomputeDistanceAndSpeed(),
      );
      await expectStepsMatch(
        ['--recompute-distance-and-speed', '--crop', '10s..end'],
        (e, b) => e.recomputeDistanceAndSpeed().crop(
          b.start.add(const Duration(seconds: 10)),
          b.end,
        ),
      );
    });

    for (final (steps, label, chain)
        in <
          (
            List<String>,
            String,
            RawEditor Function(RawEditor, ({DateTime start, DateTime end})),
          )
        >[
          (['--sort-and-dedup'], 'sortAndDedup', (e, _) => e.sortAndDedup()),
          (
            ['--strict-time-order'],
            'ensureStrictTimeOrder',
            (e, _) => e.ensureStrictTimeOrder(),
          ),
          (['--trim-invalid'], 'trimInvalid', (e, _) => e.trimInvalid()),
          (
            ['--recompute-distance-and-speed'],
            'recomputeDistanceAndSpeed',
            (e, _) => e.recomputeDistanceAndSpeed(),
          ),
          (
            ['--crop', 'start..end-10s'],
            'crop',
            (e, b) =>
                e.crop(b.start, b.end.subtract(const Duration(seconds: 10))),
          ),
          (
            ['--shift-time', '-1h'],
            'shiftTime',
            (e, _) => e.shiftTime(const Duration(hours: -1)),
          ),
          (
            ['--insert-point', '25s,40.0011,-105.0007,1600'],
            'insertPoint',
            (e, b) => e.insertPoint(
              GeoPoint(
                latitude: 40.0011,
                longitude: -105.0007,
                elevation: 1600,
                time: b.start.add(const Duration(seconds: 25)),
              ),
            ),
          ),
          (
            ['--update-point', '1,lat=40.5,ele=12'],
            'updatePoint',
            (e, _) => e.updatePoint(1, latitude: 40.5, elevation: 12),
          ),
          (
            ['--delete-point', '2'],
            'deletePointAt',
            (e, _) => e.deletePointAt(2),
          ),
          (
            ['--delete-range', '10s..20s'],
            'deleteRange',
            (e, b) => e.deleteRange(
              b.start.add(const Duration(seconds: 10)),
              b.start.add(const Duration(seconds: 20)),
            ),
          ),
          (
            ['--insert-pause', '20s,2m'],
            'insertPause',
            (e, b) => e.insertPause(
              b.start.add(const Duration(seconds: 20)),
              const Duration(minutes: 2),
            ),
          ),
          (
            ['--remove-pause', '10s..30s'],
            'removePause',
            (e, b) => e.removePause(
              b.start.add(const Duration(seconds: 10)),
              b.start.add(const Duration(seconds: 30)),
            ),
          ),
          (
            ['--downsample-time', '20s'],
            'downsampleTime',
            (e, _) => e.downsampleTime(const Duration(seconds: 20)),
          ),
          (
            ['--downsample-distance', '40'],
            'downsampleDistance',
            (e, _) => e.downsampleDistance(40),
          ),
          (['--smooth-hr', '3'], 'smoothHR', (e, _) => e.smoothHR(3)),
          (
            ['--mark-laps-by-distance', '50'],
            'markLapsByDistance',
            (e, _) => e.markLapsByDistance(50),
          ),
          (
            ['--resample', '5s'],
            'RawTransforms.resample',
            (e, _) => RawEditor(
              RawTransforms.resample(
                e.activity,
                step: const Duration(seconds: 5),
              ),
            ),
          ),
          (
            ['--auto-fix', '--auto-lap', '--auto-lap-distance', '50'],
            'autoFix',
            (e, _) => e.autoFix(
              const ActivityAutoFixOptions(
                autoLapByDistance: true,
                autoLapDistanceMeters: 50,
              ),
            ),
          ),
        ]) {
      test('${steps.first} matches RawEditor $label', () async {
        await expectStepsMatch(steps, chain);
      });
    }

    test('exact timestamps with a zone work like the library', () async {
      final imported = await _import(_samples['fit']!);
      final b = _bounds(imported.activity);
      final from = b.start.add(const Duration(seconds: 10));
      await expectStepsMatch([
        '--crop',
        '${from.toIso8601String()}..${b.end.toIso8601String()}',
      ], (e, _) => e.crop(from, b.end));
    });

    test('--to changes the format in the same pass', () async {
      await expectStepsMatch(
        ['--smooth-hr', '3'],
        (e, _) => e.smoothHR(3),
        to: 'gpx',
      );
    });

    test('without --to the output keeps the input format', () async {
      final output = _temp('kept.tcx');
      _expectExit(
        await _cli([
          'edit',
          '-i',
          _samples['tcx']!,
          '-o',
          output,
          '--sort-and-dedup',
        ]),
        0,
      );
      expect(
        File(output).readAsStringSync(),
        contains('TrainingCenterDatabase'),
      );
    });

    test('needs at least one step', () async {
      final result = await _cli([
        'edit',
        '-i',
        _samples['gpx']!,
        '-o',
        _temp('nostep.gpx'),
      ]);
      _expectExit(result, 64);
      expect(result.stderr, contains('convert'));
    });

    for (final (step, value) in [
      ('--crop', '5x..end'),
      ('--crop', '5m'),
      ('--crop', '2024-01-10T07:00:00..end'),
      ('--shift-time', 'soon'),
      ('--insert-point', '5s,95,0'),
      ('--insert-point', '5s,40'),
      ('--update-point', '1'),
      ('--update-point', '1,speed=3'),
      ('--delete-point', '-1'),
      ('--insert-pause', '5s'),
      ('--downsample-time', '0'),
      ('--downsample-distance', '-4'),
      ('--smooth-hr', '0'),
      ('--mark-laps-by-distance', 'far'),
      ('--resample', '0s'),
    ]) {
      test('rejects $step "$value" with 64 before reading', () async {
        final result = await _cli([
          'edit',
          '-i',
          _temp('does-not-exist.gpx'),
          '-o',
          _temp('rejected.gpx'),
          step,
          value,
        ]);
        _expectExit(result, 64);
        expect(result.stderr, contains(step));
      });
    }

    test('a step that does not fit the activity exits with 65', () async {
      final output = _temp('nofit.gpx');
      final result = await _cli([
        'edit',
        '-i',
        _samples['gpx']!,
        '-o',
        output,
        '--delete-point',
        '999',
      ]);
      _expectExit(result, 65);
      expect(result.stderr, contains('--delete-point 999'));
      expect(File(output).existsSync(), isFalse);
    });

    test('--json reports what the steps repaired', () async {
      final result = await _cli([
        'edit',
        '-i',
        _samples['tcx']!,
        '-o',
        _temp('repaired.tcx'),
        '--strict-time-order',
        '--json',
      ]);
      _expectExit(result, 0);
      final record =
          jsonDecode((result.stderr as String).trim()) as Map<String, Object?>;
      final sources = [
        for (final d in record['diagnostics'] as List<Object?>)
          (d as Map<String, Object?>)['source'],
      ];
      expect(sources, contains('repair'));
    });
  });

  group('merge', () {
    test('writes what RawEditor.merge and export produce', () async {
      final output = _temp('merged.tcx');
      _expectExit(
        await _cli([
          'merge',
          '-i',
          _samples['gpx']!,
          '-i',
          _samples['fit']!,
          '--to',
          'tcx',
          '-o',
          output,
          '--preserve-sport-per-lap',
          '--creator',
          'cli-test',
        ]),
        0,
      );
      final merged = RawEditor.merge(
        [
          (await _import(_samples['gpx']!)).activity,
          (await _import(_samples['fit']!)).activity,
        ],
        preserveSportPerLap: true,
        creator: 'cli-test',
      );
      final expected = ActivityFiles.export(
        activity: merged,
        to: ActivityFileFormat.tcx,
      );
      expect(File(output).readAsBytesSync(), expected.asBytes());
    });

    test('needs two inputs, --to and -o', () async {
      _expectExit(
        await _cli([
          'merge',
          '-i',
          _samples['gpx']!,
          '--to',
          'tcx',
          '-o',
          _temp('one.tcx'),
        ]),
        64,
      );
      _expectExit(
        await _cli([
          'merge',
          '-i',
          _samples['gpx']!,
          '-i',
          _samples['tcx']!,
          '-o',
          _temp('noto.tcx'),
        ]),
        64,
      );
      _expectExit(
        await _cli([
          'merge',
          '-i',
          _samples['gpx']!,
          '-i',
          _samples['tcx']!,
          '--to',
          'tcx',
        ]),
        64,
      );
    });

    test('an unreadable input writes nothing and exits with 65', () async {
      final junk = _temp('merge-junk.gpx');
      File(junk).writeAsStringSync('nope');
      final output = _temp('merge-failed.tcx');
      _expectExit(
        await _cli([
          'merge',
          '-i',
          _samples['gpx']!,
          '-i',
          junk,
          '--from',
          'gpx',
          '--to',
          'tcx',
          '-o',
          output,
        ]),
        65,
      );
      expect(File(output).existsSync(), isFalse);
    });
  });

  group('split', () {
    test('writes one file per leg, numbered by start time', () async {
      final race = RawEditor.merge([
        (await _import(
          _samples['gpx']!,
        )).activity.copyWith(sport: Sport.cycling),
        RawEditor((await _import(_samples['fit']!)).activity)
            .shiftTime(const Duration(hours: 1))
            .activity
            .copyWith(sport: Sport.running),
      ], preserveSportPerLap: true);
      // TCX keeps one <Activity> per sport, so the legs survive the file.
      final racePath = _temp('race.tcx');
      File(racePath).writeAsBytesSync(
        ActivityFiles.export(
          activity: race,
          to: ActivityFileFormat.tcx,
        ).asBytes(),
      );
      final legs = Directory(_temp('legs'));
      _expectExit(
        await _cli(['split', '-i', racePath, '--out-dir', legs.path]),
        0,
      );
      final parsed = await _import(racePath);
      final parts = RawEditor.splitBySport(parsed.activity).entries.toList()
        ..sort(
          (a, b) => _bounds(a.value).start.compareTo(_bounds(b.value).start),
        );
      expect(parts.length, greaterThan(1));
      for (var i = 0; i < parts.length; i++) {
        final file = File(
          '${legs.path}/race.${i + 1}-${parts[i].key.name}.tcx',
        );
        expect(file.existsSync(), isTrue, reason: file.path);
        expect(
          file.readAsBytesSync(),
          ActivityFiles.export(
            activity: parts[i].value,
            to: ActivityFileFormat.tcx,
          ).asBytes(),
        );
      }
    });

    test('needs --out-dir and one input', () async {
      _expectExit(
        await _cli(['split', '-i', _samples['fit']!, '-o', _temp('x.fit')]),
        64,
      );
      _expectExit(
        await _cli([
          'split',
          '-i',
          _samples['fit']!,
          '-i',
          _samples['gpx']!,
          '--out-dir',
          _temp('two'),
        ]),
        64,
      );
    });
  });

  group('validate', () {
    for (final format in _formats) {
      test('judges the $format sample like the library', () async {
        final result = await _cli(['validate', '-i', _samples[format]!]);
        final activity = (await _import(_samples[format]!, format)).activity;
        final validation = ActivityFiles.validate(activity);
        final errors = validation.diagnostics.where((d) => d.isError);
        if (validation.isValid) {
          _expectExit(result, 0);
          expect(result.stdout, contains('Validation passed'));
        } else {
          _expectExit(result, 65);
          for (final error in errors) {
            expect(result.stdout, contains(error.message));
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
        final result = await _cli(['validate', '--from', 'gpx', '-i', path]);
        _expectExit(result, 65);
        expect(result.stdout, isNot(contains('Validation passed')));
      });
    }

    test('passes or fails as ActivityFiles.validate does', () async {
      // Its only problem is a FIT manufacturer ID of 0, which the device
      // checks report and ActivityFiles.validate does not check.
      final path = _temp('manufacturer-0.fit');
      File(path).writeAsBytesSync(_fitWithRecords(manufacturer: 0));
      final activity = (await _import(path)).activity;
      expect(
        validateDeviceMetadata(activity.device!).map((d) => d.code),
        contains('validation.device.invalid_fit_manufacturer_id'),
      );
      expect(ActivityFiles.validate(activity).isValid, isTrue);

      final result = await _cli(['validate', '-i', path]);
      _expectExit(result, 0);
      expect(result.stdout, contains('Validation passed'));
      expect(result.stdout, isNot(contains('manufacturer')));
    });

    test('a FIT file with a bad checksum but readable data passes; convert '
        'writes it', () async {
      final path = _temp('bad-checksum.fit');
      File(path).writeAsBytesSync(_fitWithRecords(badChecksum: true));
      final result = await _cli(['validate', '-i', path]);
      _expectExit(result, 0);
      expect(result.stdout, contains('Validation passed'));
      expect(result.stdout, contains('Errors while reading:'));
      expect(result.stdout, contains('fit.trailer.crc_mismatch'));

      final json = await _cli(['validate', '-i', path, '--json']);
      _expectExit(json, 0);
      final report = jsonDecode(json.stdout as String) as Map;
      expect(report['passed'], isTrue);

      final out = _temp('bad-checksum.gpx');
      _expectExit(
        await _cli(['convert', '--to', 'gpx', '-i', path, '-o', out]),
        0,
      );
      expect((await _import(out)).activity.points, hasLength(2));
    });

    test('fails a GPX file read as TCX, and a TCX file read as GPX', () async {
      for (final (from, file) in [('tcx', 'gpx'), ('gpx', 'tcx')]) {
        final result = await _cli([
          'validate',
          '--from',
          from,
          '-i',
          _samples[file]!,
        ]);
        _expectExit(result, 65);
        expect(result.stdout, contains('could not be read'));
      }
    });

    test('fails a file given the wrong --from with 65', () async {
      _expectExit(
        await _cli(['validate', '--from', 'gpx', '-i', _samples['fit']!]),
        65,
      );
    });

    test('--gap-threshold reports shorter gaps', () async {
      final result = await _cli([
        'validate',
        '-i',
        _samples['gpx']!,
        '--gap-threshold',
        '1ms',
      ]);
      _expectExit(result, 0);
      expect(result.stdout, contains('Warnings:'));
    });

    for (final value in ['0', '-1', 'abc']) {
      test('rejects --gap-threshold "$value" with 64', () async {
        final result = await _cli([
          'validate',
          '-i',
          _samples['gpx']!,
          '--gap-threshold',
          value,
        ]);
        _expectExit(result, 64);
        expect(result.stderr, contains('--gap-threshold'));
      });
    }

    test('--json writes one report line per file on stdout', () async {
      final result = await _cli([
        'validate',
        '-i',
        _samples['gpx']!,
        '-i',
        _samples['tcx']!,
        '--json',
      ]);
      final lines = (result.stdout as String).trim().split('\n');
      expect(lines, hasLength(2));
      final first = jsonDecode(lines.first) as Map<String, Object?>;
      expect(first['input'], _samples['gpx']);
      expect(first['format'], 'gpx');
      expect(first['passed'], isA<bool>());
      expect(first['points'], isA<int>());
    });
  });

  group('inspect', () {
    test('--json reports what the library reads', () async {
      final result = await _cli(['inspect', '-i', _samples['fit']!, '--json']);
      _expectExit(result, 0);
      final summary =
          jsonDecode((result.stdout as String).trim()) as Map<String, Object?>;
      final activity = (await _import(_samples['fit']!)).activity;
      expect(summary['format'], 'fit');
      expect(summary['sport'], activity.sport.name);
      expect(summary['points'], activity.points.length);
      expect(summary['laps'], activity.laps.length);
      expect(summary['channels'], {
        for (final e in activity.channels.entries) e.key.id: e.value.length,
      });
      expect(summary['device'], isA<Map<String, Object?>>());
    });

    test('text output lists format, points and channels', () async {
      final result = await _cli(['inspect', '-i', _samples['gpx']!]);
      _expectExit(result, 0);
      expect(result.stdout, contains('format     gpx'));
      expect(result.stdout, contains('points'));
      expect(result.stdout, contains('channels'));
    });

    test('a file that cannot be read exits with 65', () async {
      final path = _temp('inspect-junk.gpx');
      File(path).writeAsStringSync('nope');
      _expectExit(await _cli(['inspect', '--from', 'gpx', '-i', path]), 65);
    });
  });

  group('many files and folders', () {
    late Directory tree;

    setUp(() {
      tree = Directory(_temp('tree'))..createSync();
      Directory('${tree.path}/2024').createSync();
      Directory('${tree.path}/.hidden').createSync();
      File(_samples['gpx']!).copySync('${tree.path}/a.gpx');
      File(_samples['fit']!).copySync('${tree.path}/2024/b.fit');
      File(_samples['tcx']!).copySync('${tree.path}/.hidden/c.tcx');
      File('${tree.path}/notes.txt').writeAsStringSync('not an activity');
    });

    tearDown(() {
      tree.deleteSync(recursive: true);
      final out = Directory(_temp('tree-out'));
      if (out.existsSync()) out.deleteSync(recursive: true);
    });

    test('a folder converts its own files; --recursive adds subfolders and '
        'mirrors them', () async {
      final out = _temp('tree-out');
      _expectExit(
        await _cli([
          'convert',
          '--to',
          'tcx',
          '-i',
          tree.path,
          '--out-dir',
          out,
        ]),
        0,
      );
      expect(File('$out/a.tcx').existsSync(), isTrue);
      expect(File('$out/2024/b.tcx').existsSync(), isFalse);

      final result = await _cli([
        'convert',
        '--to',
        'tcx',
        '-i',
        tree.path,
        '--recursive',
        '--out-dir',
        out,
      ]);
      _expectExit(result, 0);
      expect(File('$out/2024/b.tcx').existsSync(), isTrue);
      expect(File('$out/.hidden/c.tcx').existsSync(), isFalse);
      expect(result.stderr, contains('2 converted, 0 failed'));
    });

    test('a name clash stops the run before anything is written', () async {
      File(_samples['tcx']!).copySync('${tree.path}/a.tcx');
      final out = _temp('tree-out');
      final result = await _cli([
        'convert',
        '--to',
        'gpx',
        '-i',
        '${tree.path}/a.gpx',
        '-i',
        '${tree.path}/a.tcx',
        '--out-dir',
        out,
      ]);
      _expectExit(result, 64);
      expect(result.stderr, contains('a.gpx'));
      expect(result.stderr, contains('a.tcx'));
      expect(Directory(out).existsSync(), isFalse);
    });

    test('an output never overwrites an input', () async {
      final result = await _cli([
        'convert',
        '--to',
        'gpx',
        '-i',
        tree.path,
        '--out-dir',
        tree.path,
      ]);
      _expectExit(result, 64);
      expect(result.stderr, contains('overwrite'));
    });

    test('one failing file is reported and the others continue', () async {
      File('${tree.path}/broken.gpx').writeAsStringSync('nope');
      final out = _temp('tree-out');
      final result = await _cli([
        'convert',
        '--to',
        'tcx',
        '-i',
        tree.path,
        '--out-dir',
        out,
      ]);
      _expectExit(result, 65);
      expect(File('$out/a.tcx').existsSync(), isTrue);
      expect(result.stderr, contains('1 converted, 1 failed'));
      expect(result.stderr, contains('broken.gpx'));
    });

    test('--stop-on-error stops at the first failure', () async {
      File('${tree.path}/0-broken.gpx').writeAsStringSync('nope');
      final out = _temp('tree-out');
      final result = await _cli([
        'convert',
        '--to',
        'tcx',
        '-i',
        tree.path,
        '--out-dir',
        out,
        '--stop-on-error',
      ]);
      _expectExit(result, 65);
      expect(File('$out/a.tcx').existsSync(), isFalse);
      expect(result.stderr, contains('not attempted'));
    });

    test('several inputs need --out-dir instead of -o', () async {
      _expectExit(
        await _cli([
          'convert',
          '--to',
          'tcx',
          '-i',
          tree.path,
          '-o',
          _temp('x.tcx'),
        ]),
        64,
      );
    });

    test('validate and inspect take folders too', () async {
      final validate = await _cli(['validate', '-i', tree.path, '--recursive']);
      expect(validate.stdout, contains('a.gpx'));
      expect(validate.stdout, contains('b.fit'));
      final inspect = await _cli(['inspect', '-i', tree.path, '--recursive']);
      _expectExit(inspect, 0);
      expect(inspect.stdout, contains('b.fit'));
    });
  });

  group('bad input in a run', () {
    late Directory work;
    final locked = <String>[];

    setUp(() {
      work = Directory(_temp('guards'))..createSync();
    });

    tearDown(() {
      for (final path in locked) {
        Process.runSync('chmod', ['755', path]);
      }
      locked.clear();
      work.deleteSync(recursive: true);
    });

    /// Takes away all permissions on [path]; false where that does not stop
    /// reading it (Windows, or running as root).
    bool lock(String path, {required bool folder}) {
      if (Platform.isWindows) return false;
      Process.runSync('chmod', ['000', path]);
      locked.add(path);
      try {
        folder ? Directory(path).listSync() : File(path).readAsBytesSync();
        return false;
      } on FileSystemException {
        return true;
      }
    }

    String gpxWithPoints(int count) {
      final start = DateTime.utc(2024, 1, 1, 10);
      final points = [
        for (var i = 0; i < count; i++)
          '<trkpt lat="${50 + i * 0.0001}" lon="8"><time>'
              '${start.add(Duration(seconds: i)).toIso8601String()}'
              '</time></trkpt>',
      ];
      return '<?xml version="1.0" encoding="UTF-8"?>'
          '<gpx version="1.1" creator="test" '
          'xmlns="http://www.topografix.com/GPX/1/1">'
          '<trk><trkseg>${points.join()}</trkseg></trk></gpx>';
    }

    List<Map<String, Object?>> jsonLines(ProcessResult result) => [
      for (final line in (result.stderr as String).trim().split('\n'))
        jsonDecode(line) as Map<String, Object?>,
    ];

    test(
      'an edit step that does not fit one file fails that file only',
      () async {
        final dir = Directory('${work.path}/in')..createSync();
        File(_samples['gpx']!).copySync('${dir.path}/a.gpx');
        File('${dir.path}/b.gpx').writeAsStringSync(gpxWithPoints(12));
        File('${dir.path}/c.gpx').writeAsStringSync(gpxWithPoints(12));
        List<String> edit(String out) => [
          'edit',
          '-i',
          dir.path,
          '--out-dir',
          out,
          '--delete-point',
          '10',
        ];

        final out = '${work.path}/out';
        final result = await _cli(edit(out));
        _expectExit(result, 65);
        expect(File('$out/a.gpx').existsSync(), isFalse);
        expect(File('$out/b.gpx').existsSync(), isTrue);
        expect(File('$out/c.gpx').existsSync(), isTrue);
        expect(result.stderr, contains('2 edited, 1 failed'));

        final json = await _cli([...edit('${work.path}/out-json'), '--json']);
        _expectExit(json, 65);
        final records = jsonLines(json);
        expect([for (final r in records) r['written']], [false, true, true]);
        expect(records.first['error'], contains('--delete-point 10'));
      },
    );

    for (final outDir in ['in2/', './in2', 'x/../in2']) {
      test(
        '--out-dir $outDir is refused when it is the input folder',
        () async {
          final dir = Directory('${work.path}/in2')..createSync();
          Directory('${work.path}/x').createSync();
          final input = File('${dir.path}/a.gpx');
          File(_samples['gpx']!).copySync(input.path);
          final before = input.readAsBytesSync();
          final result = await Process.run(_cliPath, [
            'edit',
            '-i',
            'in2',
            '--out-dir',
            outDir,
            '--shift-time',
            '1h',
          ], workingDirectory: work.path);
          _expectExit(result, 64);
          expect(result.stderr, contains('would overwrite an input file'));
          expect(input.readAsBytesSync(), before);
        },
      );
    }

    test('output names that differ only in case clash', () async {
      final dir = Directory('${work.path}/case')..createSync();
      File(_samples['gpx']!).copySync('${dir.path}/Run.gpx');
      File(_samples['tcx']!).copySync('${dir.path}/run.tcx');
      final out = '${work.path}/out';
      final result = await _cli([
        'convert',
        '--to',
        'fit',
        '-i',
        dir.path,
        '--out-dir',
        out,
      ]);
      _expectExit(result, 64);
      expect(result.stderr, contains('Run.gpx'));
      expect(result.stderr, contains('run.tcx'));
      expect(Directory(out).existsSync(), isFalse);
    });

    test('a FIT file with laps but no records and a bad checksum is written; '
        '--strict-fit refuses it', () async {
      final path = '${work.path}/laps-only.fit';
      File(path).writeAsBytesSync(_fitWithoutRecords());
      final imported = await _import(path);
      expect(imported.activity.points, isEmpty);
      expect(imported.activity.laps, hasLength(1));
      expect(imported.activity.sets, hasLength(1));

      final out = '${work.path}/laps-only.tcx';
      _expectExit(
        await _cli(['convert', '--to', 'tcx', '-i', path, '-o', out]),
        0,
      );
      // TCX loses the lap for now, with no diagnostic; the open-work list
      // plans the fix for 0.11.0 ("An activity with laps but no points loses
      // them in every text format, silently"). The fix should make this
      // check that the lap survives.
      expect(File(out).existsSync(), isTrue);
      final inspected = await _cli(['inspect', '-i', path, '--json']);
      _expectExit(inspected, 0);
      final summary = jsonDecode(inspected.stdout as String) as Map;
      expect(summary['laps'], 1);
      expect(summary['sets'], 1);

      final strictOut = '${work.path}/strict.tcx';
      final strict = await _cli([
        'convert',
        '--to',
        'tcx',
        '--strict-fit',
        '-i',
        path,
        '-o',
        strictOut,
      ]);
      _expectExit(strict, 65);
      expect(File(strictOut).existsSync(), isFalse);
    });

    test(
      'a file over --max-payload-bytes is refused before it is read',
      () async {
        final path = '${work.path}/big.gpx';
        File(path).writeAsStringSync(gpxWithPoints(40));
        final size = File(path).lengthSync();
        // An unreadable file shows the size is checked without reading it.
        if (!lock(path, folder: false)) {
          markTestSkipped('file permissions do not stop reading here');
          return;
        }
        final result = await _cli([
          'inspect',
          '-i',
          path,
          '--max-payload-bytes',
          '${size - 1}',
        ]);
        _expectExit(result, 65);
        expect(result.stdout, contains('exceeds ${size - 1} bytes'));
      },
    );

    test('stdin over --max-payload-bytes is refused without reading to its '
        'end', () async {
      final process = await Process.start(_cliPath, [
        'inspect',
        '-i',
        '-',
        '--from',
        'gpx',
        '--max-payload-bytes',
        '1000',
      ]);
      // More than the limit, and stdin stays open: reading it to its end
      // would never finish.
      // The command line may stop reading, and exit, before the write ends.
      process.stdin.done.ignore();
      process.stdin.add(List.filled(70 * 1024, 0x20));
      final out = process.stdout.transform(utf8.decoder).join();
      final err = process.stderr.drain<void>();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      await err;
      expect(code, 65);
      expect(await out, contains('exceeds 1000 bytes'));
    });

    test('an unreadable subfolder fails on its own; the rest is written and '
        'summarized', () async {
      final dir = Directory('${work.path}/tree')..createSync();
      File(_samples['gpx']!).copySync('${dir.path}/a.gpx');
      final sub = Directory('${dir.path}/sub')..createSync();
      File(_samples['gpx']!).copySync('${sub.path}/b.gpx');
      if (!lock(sub.path, folder: true)) {
        markTestSkipped('folder permissions do not stop listing here');
        return;
      }
      List<String> convert(String out) => [
        'convert',
        '--to',
        'tcx',
        '-i',
        dir.path,
        '--recursive',
        '--out-dir',
        out,
      ];

      final out = '${work.path}/out';
      final result = await _cli(convert(out));
      _expectExit(result, 66);
      expect(File('$out/a.tcx').existsSync(), isTrue);
      expect(result.stderr, contains('Could not read the folder'));
      expect(result.stderr, contains('1 converted, 1 failed'));

      final json = await _cli([...convert('${work.path}/out-json'), '--json']);
      _expectExit(json, 66);
      final records = jsonLines(json);
      expect(records, hasLength(2));
      expect(
        records.firstWhere((r) => r['written'] == false)['input'],
        sub.path,
      );
    });
  });

  group('pipes', () {
    test(
      '- reads stdin and writes stdout; only the file goes to stdout',
      () async {
        final result = await _cliWithStdin([
          'convert',
          '--to',
          'gpx',
          '-i',
          '-',
          '-o',
          '-',
        ], File(_samples['fit']!).readAsBytesSync());
        _expectExit(result, 0);
        final expected = await ActivityFiles.convert(
          source: File(_samples['fit']!).readAsBytesSync(),
          to: ActivityFileFormat.gpx,
          useIsolate: false,
        );
        expect(result.stdout, expected.asBytes());
        expect(result.stderr, contains('stdout'));
      },
    );

    test('stdin cannot be combined with other inputs', () async {
      _expectExit(
        await _cli([
          'convert',
          '--to',
          'gpx',
          '-i',
          '-',
          '-i',
          _samples['gpx']!,
          '--out-dir',
          _temp('mixed'),
        ]),
        64,
      );
    });
  });

  group('documentation', () {
    late String guide;
    late String reference;

    setUpAll(() {
      guide = File('doc/usage_guide.md').readAsStringSync();
      reference = guide.substring(guide.indexOf('## Command line reference'));
    });

    test('the package declares the activity_files executable', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec,
        matches(RegExp(r'executables:\s*\n\s+activity_files: activity_files')),
      );
    });

    test('every documented command and option exists', () async {
      final docs = '$guide\n${File('README.md').readAsStringSync()}';
      final invocations = RegExp(
        r'activity_files (convert|edit|merge|split|validate|inspect)\b'
        r'((?:[^\n]*\\\n)*[^\n]*)',
      ).allMatches(docs).toList();
      expect(invocations, isNotEmpty);
      final helps = <String, Set<String>>{};
      for (final invocation in invocations) {
        final command = invocation[1]!;
        final options = helps[command] ??= _optionsIn(await _help(command));
        for (final option in RegExp(
          r'--(?:no-)?([a-z][a-z0-9-]*)',
        ).allMatches(invocation[2]!).map((m) => m[1]!)) {
          expect(
            options,
            contains(option),
            reason: '"activity_files $command" documents --$option',
          );
        }
      }
    });

    test('every option of every command is in the reference', () async {
      for (final command in _commands) {
        for (final option in _optionsIn(await _help(command))) {
          expect(
            reference.contains('--$option') ||
                reference.contains('--no-$option'),
            isTrue,
            reason: '--$option of $command is missing from the reference',
          );
        }
      }
    });

    test('every task section shows the Dart code and the command', () {
      final sections = guide
          .substring(0, guide.indexOf('## Command line reference'))
          .split(RegExp(r'\n(?=## )'));
      final commandsShown = <String>{};
      for (final section in sections) {
        final commands = RegExp(
          r'activity_files (convert|edit|merge|split|validate|inspect)\b',
        ).allMatches(section).map((m) => m[1]!).toSet();
        // Getting started installs the tool; it is setup, not a task.
        if (commands.isEmpty || section.startsWith('## Getting started')) {
          continue;
        }
        commandsShown.addAll(commands);
        expect(
          section.contains('```dart'),
          isTrue,
          reason:
              'The section "${section.split('\n').first}" shows a command but '
              'no Dart code',
        );
      }
      expect(commandsShown, containsAll(_commands));
    });

    test('the guide names no deprecated option', () {
      for (final removed in [
        '--format',
        '--hr-max-delta',
        '--cadence-max-delta',
        '--power-max-delta',
        '--temp-max-delta',
      ]) {
        expect(guide, isNot(contains(removed)));
      }
    });
  });
}

/// A FIT definition message for local message [local], little endian.
List<int> _fitDefinition(int local, int global, List<List<int>> fields) => [
  0x40 | local,
  0x00,
  0x00,
  ...uint16LeBytes(global),
  fields.length,
  for (final field in fields) ...field,
];

/// A FIT file around [data]; with [badChecksum] its file checksum does not
/// match.
List<int> _fitFile(List<int> data, {bool badChecksum = false}) {
  final crc = fitCrc(data) ^ (badChecksum ? 0xFFFF : 0);
  return [...buildFitHeader(data.length), ...data, crc & 0xFF, crc >> 8];
}

/// Seconds since 1989-12-31T00:00:00Z, the FIT epoch.
const _fitStart = 1000000000;

/// A FIT activity of two records from [manufacturer]. Field numbers are from
/// the FIT profile.
List<int> _fitWithRecords({int manufacturer = 1, bool badChecksum = false}) =>
    _fitFile([
      // file_id (0): type (0, enum) = activity, manufacturer (1, uint16),
      // time_created (4, uint32).
      ..._fitDefinition(0, 0, [
        [0, 1, 0x00],
        [1, 2, 0x84],
        [4, 4, 0x86],
      ]),
      0x00, 4, ...uint16LeBytes(manufacturer), ...uint32LeBytes(_fitStart),
      // record (20): timestamp (253), position_lat (0), position_long (1).
      ..._fitDefinition(1, 20, [
        [253, 4, 0x86],
        [0, 4, 0x85],
        [1, 4, 0x85],
      ]),
      for (var i = 0; i < 2; i++) ...[
        0x01,
        ...uint32LeBytes(_fitStart + i),
        ...int32LeBytes(encodeSemicircles(50 + i * 0.0001)),
        ...int32LeBytes(encodeSemicircles(8)),
      ],
    ], badChecksum: badChecksum);

/// A FIT activity with a session, a lap and a strength set but no records,
/// and a file checksum that does not match. Field numbers are from the FIT
/// profile.
List<int> _fitWithoutRecords() {
  const end = _fitStart + 600;
  return _fitFile([
    // file_id (0): type (0, enum) = activity, time_created (4, uint32).
    ..._fitDefinition(0, 0, [
      [0, 1, 0x00],
      [4, 4, 0x86],
    ]),
    0x00, 4, ...uint32LeBytes(_fitStart),
    // session (18): timestamp (253), start_time (2), total_elapsed_time (7,
    // ms), sport (5, enum) = training.
    ..._fitDefinition(1, 18, [
      [253, 4, 0x86],
      [2, 4, 0x86],
      [7, 4, 0x86],
      [5, 1, 0x00],
    ]),
    0x01, ...uint32LeBytes(end), ...uint32LeBytes(_fitStart),
    ...uint32LeBytes(600000), 10,
    // lap (19): timestamp (253), start_time (2), total_elapsed_time (7, ms).
    ..._fitDefinition(2, 19, [
      [253, 4, 0x86],
      [2, 4, 0x86],
      [7, 4, 0x86],
    ]),
    0x02, ...uint32LeBytes(end), ...uint32LeBytes(_fitStart),
    ...uint32LeBytes(600000),
    // set (225): timestamp (254), start_time (6), duration (0, ms),
    // repetitions (3, uint16), set_type (5, uint8) = active.
    ..._fitDefinition(3, 225, [
      [254, 4, 0x86],
      [6, 4, 0x86],
      [0, 4, 0x86],
      [3, 2, 0x84],
      [5, 1, 0x02],
    ]),
    0x03, ...uint32LeBytes(_fitStart + 60), ...uint32LeBytes(_fitStart),
    ...uint32LeBytes(60000), ...uint16LeBytes(10), 1,
  ], badChecksum: true);
}
