// SPDX-License-Identifier: BSD-3-Clause
part of 'cli.dart';

/// A file that failed; the run goes on with the next one.
class _FileFailure implements Exception {
  _FileFailure(this.message, this.exitCode, [this.reported = const []]);

  final String message;
  final int exitCode;
  final List<_Reported> reported;
}

/// How every command reads its inputs.
class _ReadOptions {
  _ReadOptions(ArgResults command)
    : from = _fromOption(command),
      encoding = _encoding(command),
      strictFit = command['strict-fit'] == true,
      maxPayloadBytes = _maxPayloadBytes(command);

  final ActivityFileFormat? from;
  final Encoding encoding;
  final bool strictFit;
  final int? maxPayloadBytes;
}

/// How the writing commands write.
class _WriteOptions {
  _WriteOptions(ArgResults command)
    : to = _formatOption(command, 'to'),
      encoder = _encoderOptions(command),
      normalize = command['normalize'] == true,
      validate = command['validate'] == true,
      outDir = _string(command, 'out-dir') != null;

  final ActivityFileFormat? to;
  final EncoderOptions encoder;
  final bool normalize;
  final bool validate;
  final bool outDir;
}

String _firstLine(Object? message) =>
    '$message'.split('\n').first.replaceFirst('Invalid argument(s): ', '');

/// The failure [error] stands for when one file of a run hits it: a usage or
/// write error keeps its exit code, anything else is an internal error
/// (exit 70).
_FileFailure _asFailure(Object error) => switch (error) {
  _FileFailure() => error,
  _CliException() => _FileFailure(error.message, error.exitCode),
  _ => _FileFailure('Internal error: ${_firstLine(error)}', _exitSoftware),
};

/// How the library's message begins when it cannot tell the format.
const _undetected = 'Unable to infer activity format';

/// Runs the library call [read] that reads one input and turns what it
/// throws into a file failure.
Future<T> _guardRead<T>(_ReadOptions options, Future<T> Function() read) async {
  try {
    return await read();
  } on FormatException catch (e) {
    throw _FileFailure(_firstLine(e.message), _exitData);
  } on ArgumentError catch (e) {
    throw _FileFailure(
      '${_firstLine(e.message)}'
      '${options.from == null && '${e.message}'.startsWith(_undetected) ? ' Pass --from to name the format.' : ''}',
      _exitData,
    );
  } on FileSystemException catch (e) {
    throw _FileFailure(
      'Could not read the file: ${e.osError?.message ?? e.message}',
      _exitNoInput,
    );
  }
}

/// Refuses a file when the parser reported an error and nothing could be
/// read. An error next to data (a FIT checksum mismatch, say) keeps the data,
/// as the library does; `--strict-fit` refuses such FIT files.
void _refuseUnreadable(List<_Reported> reported, RawActivity activity) {
  if (reported.any((d) => d.source == 'parser' && d.isError) &&
      !_holdsData(activity)) {
    throw _FileFailure('the file could not be read.', _exitData, reported);
  }
}

/// Whether [activity] holds anything a file recorded.
bool _holdsData(RawActivity activity) =>
    activity.points.isNotEmpty ||
    activity.channels.values.any((samples) => samples.isNotEmpty) ||
    activity.laps.isNotEmpty ||
    activity.summary?.isEmpty == false ||
    activity.additionalSessions.isNotEmpty ||
    activity.sets.isNotEmpty ||
    activity.lengths.isNotEmpty ||
    activity.events.isNotEmpty ||
    activity.gpxWaypoints.isNotEmpty ||
    activity.gpxRoutes.isNotEmpty ||
    activity.additionalTracks.any(_holdsData);

/// Imports [input]; a file the parser rejects fails with its diagnostics.
Future<ActivityImportResult> _read(_Input input, _ReadOptions options) async {
  final result = await _guardRead(
    options,
    () async => await ActivityFiles.import(
      _source(input),
      format: options.from,
      encoding: options.encoding,
      strictFitIntegrity: options.strictFit,
      maxPayloadBytes: options.maxPayloadBytes,
      useIsolate: false,
    ),
  );
  _refuseUnreadable(_fromParse(result.diagnostics), result.activity);
  return result;
}

List<_Reported> _exportDiagnostics(ActivityExportResult result) {
  final reported = <_Reported>[
    for (final d in result.diagnostics)
      if (!d.code.startsWith('validation.')) _Reported.parse(d),
  ];
  for (final d in result.validation?.diagnostics ?? <ValidationDiagnostic>[]) {
    reported.add(_Reported.validation(d));
  }
  return reported;
}

/// Reports one written file on stderr, as text or a JSON line.
void _reportWritten(
  _BatchReport batch, {
  required bool json,
  required Map<String, Object?> record,
  required String message,
  required String title,
  required List<_Reported> reported,
}) {
  if (json) {
    _printJson(stderr, {
      ...record,
      'written': true,
      'diagnostics': [for (final d in reported) d.toJson()],
    });
  } else {
    _printDiagnostics(stderr, title, reported);
  }
  batch.succeeded(message);
}

void _reportFailed(
  _BatchReport batch,
  _Input input,
  _FileFailure failure, {
  required bool json,
  Map<String, Object?> record = const {},
}) {
  if (json) {
    _printJson(stderr, {
      'input': input.display,
      ...record,
      'written': false,
      'error': failure.message,
      'diagnostics': [for (final d in failure.reported) d.toJson()],
    });
  } else {
    _printDiagnostics(
      stderr,
      'Diagnostics for ${input.display}:',
      failure.reported,
    );
  }
  batch.failure(input, failure.message, failure.exitCode);
}

/// Runs [body] for every input, reporting each, until done or until the
/// first failure with `--stop-on-error`.
Future<int> _forEachInput(
  ArgResults command,
  List<_Input> inputs,
  _BatchReport batch,
  Future<void> Function(_Input input) body, {
  Map<String, Object?> Function(_Input input)? failureRecord,
}) async {
  final stopOnError = command['stop-on-error'] == true;
  final json = command['json'] == true;
  for (final input in inputs) {
    try {
      await body(input);
    } catch (error) {
      final failure = _asFailure(error);
      _reportFailed(
        batch,
        input,
        failure,
        json: json,
        record: failureRecord?.call(input) ?? const {},
      );
      if (stopOnError) break;
    }
  }
  batch.summarize();
  return batch.worstExit;
}

Future<void> _writeOrFail(
  ActivityExportResult result,
  String target, {
  required bool createFolders,
}) async {
  try {
    await _write(result, target, createFolders: createFolders);
  } on _CliException catch (e) {
    throw _FileFailure(e.message, e.exitCode);
  }
}

// convert ---------------------------------------------------------------------

Future<int> _runConvert(ArgResults command) async {
  final read = _ReadOptions(command);
  final write = _WriteOptions(command);
  final to = write.to ?? _usage('--to is required: name the output format.');
  final autoFix =
      _autoFixOptions(command, enabled: command['auto-fix'] == true) ??
      const ActivityAutoFixOptions.disabled();
  final inputs = _inputs(command);
  final outputs = _plannedOutputs(command, inputs, (_) => to);
  final json = command['json'] == true;
  final batch = _BatchReport(inputs.length, verb: 'converted', json: json);

  return await _forEachInput(command, inputs, batch, (input) async {
    final result = await _guardRead(
      read,
      () async => await ActivityFiles.convert(
        source: _source(input),
        from: read.from,
        to: to,
        options: write.encoder,
        normalize: write.normalize,
        encoding: read.encoding,
        strictFitIntegrity: read.strictFit,
        autoFix: autoFix,
        maxPayloadBytes: read.maxPayloadBytes,
        runValidation: write.validate,
        useIsolate: false,
      ),
    );
    final reported = _exportDiagnostics(result);
    _refuseUnreadable(reported, result.activity);
    final target = outputs[input]!;
    await _writeOrFail(result, target, createFolders: write.outDir);
    _reportWritten(
      batch,
      json: json,
      record: {'input': input.display, 'output': target},
      message: 'Converted ${input.display} → ${_shown(target)}',
      title: 'Diagnostics for ${input.display}:',
      reported: reported,
    );
  }, failureRecord: (input) => {'output': ?outputs[input]});
}

// edit ------------------------------------------------------------------------

Future<int> _runEdit(ArgResults command) async {
  final steps = _editSteps(
    command,
    _commandParser(write: true, autoFixTuning: true, steps: true),
  );
  if (steps.isEmpty) {
    _usage(
      'edit needs at least one step (run "activity_files edit --help"); to '
      'change only the format, use convert.',
    );
  }
  final usesAutoFix = steps.any((step) => step.name == 'auto-fix');
  final context = _StepContext(
    autoFix: _autoFixOptions(command, enabled: usesAutoFix),
  );
  final read = _ReadOptions(command);
  final write = _WriteOptions(command);
  final inputs = _inputs(command);
  final outputs = _plannedOutputs(command, inputs, (_) => write.to);
  final json = command['json'] == true;
  final batch = _BatchReport(inputs.length, verb: 'edited', json: json);

  return await _forEachInput(command, inputs, batch, (input) async {
    final imported = await _read(input, read);
    final repairs = <_Reported>[];
    var editor = RawEditor(imported.activity);
    for (final step in steps) {
      final before = editor.repairDiagnostics.length;
      final next = step.apply(editor, context);
      final added = identical(next, editor)
          ? next.repairDiagnostics.skip(before)
          : next.repairDiagnostics;
      repairs.addAll(
        added.map((d) => _Reported.validation(d, source: 'repair')),
      );
      editor = next;
    }
    final result = ActivityFiles.export(
      activity: editor.activity,
      to: write.to ?? imported.format,
      options: write.encoder,
      normalize: write.normalize,
      runValidation: write.validate,
    );
    final reported = [
      ..._fromParse(imported.diagnostics),
      ...repairs,
      ..._exportDiagnostics(result),
    ];
    final target = outputs[input]!;
    await _writeOrFail(result, target, createFolders: write.outDir);
    _reportWritten(
      batch,
      json: json,
      record: {'input': input.display, 'output': target},
      message: 'Edited ${input.display} → ${_shown(target)}',
      title: 'Diagnostics for ${input.display}:',
      reported: reported,
    );
  }, failureRecord: (input) => {'output': ?outputs[input]});
}

// merge -----------------------------------------------------------------------

Future<int> _runMerge(ArgResults command) async {
  final read = _ReadOptions(command);
  final write = _WriteOptions(command);
  final to = write.to ?? _usage('--to is required: name the output format.');
  if (write.outDir) _usage('merge writes one file; name it with -o.');
  final target =
      _string(command, 'output') ??
      _usage('Name the merged file with -o FILE, or -o - for stdout.');
  final inputs = _inputs(command);
  if (inputs.length < 2) _usage('merge needs at least two inputs.');
  final json = command['json'] == true;

  final activities = <RawActivity>[];
  final reported = <_Reported>[];
  for (final input in inputs) {
    try {
      final imported = await _read(input, read);
      activities.add(imported.activity);
      reported.addAll(_fromParse(imported.diagnostics));
    } catch (error) {
      final failure = _asFailure(error);
      final batch = _BatchReport(1, verb: 'merged', json: json);
      _reportFailed(
        batch,
        input,
        failure,
        json: json,
        record: {
          'inputs': [for (final i in inputs) i.display],
          'output': target,
        },
      );
      if (!json) _error('Nothing was written.');
      return failure.exitCode;
    }
  }
  try {
    final merged = RawEditor.merge(
      activities,
      preserveSportPerLap: command['preserve-sport-per-lap'] == true,
      normalize: write.normalize,
      creator: _string(command, 'creator'),
    );
    final result = ActivityFiles.export(
      activity: merged,
      to: to,
      options: write.encoder,
      normalize: write.normalize,
      runValidation: write.validate,
    );
    reported.addAll(_exportDiagnostics(result));
    await _write(result, target, createFolders: false);
  } catch (error) {
    final failure = _asFailure(error);
    _reportFailed(
      _BatchReport(1, verb: 'merged', json: json),
      inputs.first,
      failure,
      json: json,
      record: {
        'inputs': [for (final i in inputs) i.display],
        'output': target,
      },
    );
    if (!json) _error('Nothing was written.');
    return failure.exitCode;
  }
  final names = [for (final input in inputs) input.display];
  final batch = _BatchReport(1, verb: 'merged', json: json);
  _reportWritten(
    batch,
    json: json,
    record: {'inputs': names, 'output': target},
    message: 'Merged ${names.join(', ')} → ${_shown(target)}',
    title: 'Diagnostics:',
    reported: reported,
  );
  return _exitOk;
}

// split -----------------------------------------------------------------------

Future<int> _runSplit(ArgResults command) async {
  final read = _ReadOptions(command);
  final write = _WriteOptions(command);
  if (_string(command, 'output') != null) {
    _usage('split writes one file per leg; name the folder with --out-dir.');
  }
  final outDir =
      _string(command, 'out-dir') ??
      _usage('Name the folder for the legs with --out-dir.');
  final inputs = _inputs(command);
  if (_isBatch(inputs)) _usage('split takes one input file.');
  final input = inputs.single;
  final json = command['json'] == true;
  final batch = _BatchReport(1, verb: 'split', json: json);

  try {
    final imported = await _read(input, read);
    final to = write.to ?? imported.format;
    final parts = RawEditor.splitBySport(
      imported.activity,
      normalize: write.normalize,
    ).entries.toList();
    DateTime startOf(RawActivity activity) {
      try {
        return _recordedRange(activity).start;
      } on _CliException {
        return DateTime.utc(9999);
      }
    }

    parts.sort((a, b) => startOf(a.value).compareTo(startOf(b.value)));
    final reported = _fromParse(imported.diagnostics);
    final written = <String>[];
    for (var i = 0; i < parts.length; i++) {
      final target =
          '$outDir/${input.stem}.${i + 1}-${parts[i].key.name}.'
          '${_extensionFor[to]}';
      final result = ActivityFiles.export(
        activity: parts[i].value,
        to: to,
        options: write.encoder,
        normalize: write.normalize,
        runValidation: write.validate,
      );
      reported.addAll(_exportDiagnostics(result));
      await _writeOrFail(result, target, createFolders: true);
      written.add(target);
    }
    _reportWritten(
      batch,
      json: json,
      record: {'input': input.display, 'outputs': written},
      message: 'Split ${input.display} → ${written.join(', ')}',
      title: 'Diagnostics for ${input.display}:',
      reported: reported,
    );
    return _exitOk;
  } catch (error) {
    final failure = _asFailure(error);
    _reportFailed(batch, input, failure, json: json);
    return failure.exitCode;
  }
}

// validate --------------------------------------------------------------------

Future<int> _runValidate(ArgResults command) async {
  final read = _ReadOptions(command);
  final gapThreshold = _durationOption(
    command,
    'gap-threshold',
    allowZero: false,
  );
  final inputs = _inputs(command);
  final json = command['json'] == true;
  final many = _isBatch(inputs);
  var exit = _exitOk;
  final stopOnError = command['stop-on-error'] == true;

  for (final input in inputs) {
    if (many && !json) stdout.writeln('${input.display}:');
    List<_Reported> reported;
    int points = 0;
    String? format;
    var passed = false;
    String? error;
    try {
      final imported = await _read(input, read);
      final activity = imported.activity;
      format = imported.format.name;
      points = activity.points.length;
      // The result is the library's; what the reader reported is listed
      // but does not fail the file.
      final validation = ActivityFiles.validate(
        activity,
        gapWarningThreshold: gapThreshold,
      );
      reported = [
        ..._fromParse(imported.diagnostics),
        for (final d in validation.diagnostics) _Reported.validation(d),
      ];
      passed = validation.isValid;
    } catch (e) {
      final failure = _asFailure(e);
      reported = failure.reported;
      error = failure.message;
      if (failure.exitCode > exit) exit = failure.exitCode;
    }
    if (!passed && exit == _exitOk) exit = _exitData;

    if (json) {
      _printJson(stdout, {
        'input': input.display,
        'format': ?format,
        'passed': passed,
        'points': points,
        'error': ?error,
        'diagnostics': [for (final d in reported) d.toJson()],
      });
    } else {
      final readErrors = reported
          .where((d) => d.isError && d.source == 'parser')
          .toList();
      final errors = reported
          .where((d) => d.isError && d.source != 'parser')
          .toList();
      final warnings = reported.where((d) => d.severity == 'warning').toList();
      if (error != null) {
        stdout.writeln('Validation failed: $error');
      } else if (passed) {
        stdout.writeln('Validation passed ($points points).');
      } else {
        stdout.writeln('Validation failed:');
      }
      void list(String title, List<_Reported> items) {
        if (items.isEmpty) return;
        stdout.writeln(title);
        for (final d in items) {
          stdout.writeln('  - ${d.code}: ${d.message}');
          if (d.suggestedFix != null) {
            stdout.writeln('      Fix: ${d.suggestedFix}');
          }
        }
      }

      list('Errors:', errors);
      list('Errors while reading:', readErrors);
      list('Warnings:', warnings);
    }
    if (!passed && stopOnError) break;
  }
  return exit;
}

// inspect ---------------------------------------------------------------------

Future<int> _runInspect(ArgResults command) async {
  final read = _ReadOptions(command);
  final inputs = _inputs(command);
  final json = command['json'] == true;
  final stopOnError = command['stop-on-error'] == true;
  var exit = _exitOk;

  for (final input in inputs) {
    try {
      final imported = await _read(input, read);
      final summary = _summary(input, imported);
      if (json) {
        _printJson(stdout, summary);
      } else {
        _printSummary(summary);
      }
    } catch (error) {
      final failure = _asFailure(error);
      if (failure.exitCode > exit) exit = failure.exitCode;
      if (json) {
        _printJson(stdout, {
          'input': input.display,
          'error': failure.message,
          'diagnostics': [for (final d in failure.reported) d.toJson()],
        });
      } else {
        stdout.writeln(input.display);
        stdout.writeln('  error      ${failure.message}');
        for (final d in failure.reported.where((d) => d.isError)) {
          stdout.writeln('    - ${d.code}: ${d.message}');
        }
      }
      if (stopOnError) break;
    }
  }
  return exit;
}

Map<String, Object?> _summary(_Input input, ActivityImportResult imported) {
  final activity = imported.activity;
  _TimeRange? range;
  try {
    range = _recordedRange(activity);
  } on _CliException {
    range = null;
  }
  final device = activity.device;
  return {
    'input': input.display,
    'format': imported.format.name,
    'sport': activity.sport.name,
    'start': ?range?.start.toIso8601String(),
    'end': ?range?.end.toIso8601String(),
    'points': activity.points.length,
    'channels': {
      for (final entry in activity.channels.entries)
        entry.key.id: entry.value.length,
    },
    'laps': activity.laps.length,
    'sessions':
        (activity.summary == null ? 0 : 1) + activity.additionalSessions.length,
    'tracks': 1 + activity.additionalTracks.length,
    'waypoints': activity.gpxWaypoints.length,
    'routes': activity.gpxRoutes.length,
    'lengths': activity.lengths.length,
    'sets': activity.sets.length,
    'events': activity.events.length,
    if (device != null)
      'device': {
        'manufacturer': ?device.manufacturer,
        'model': ?device.model,
        'product': ?device.product,
        'serialNumber': ?device.serialNumber,
        'softwareVersion': ?device.softwareVersion,
      },
    'creator': ?activity.creator,
    'diagnostics': [
      for (final d in _fromParse(imported.diagnostics)) d.toJson(),
    ],
  };
}

void _printSummary(Map<String, Object?> summary) {
  void row(String label, Object? value) {
    if (value == null) return;
    stdout.writeln('  ${label.padRight(10)} $value');
  }

  stdout.writeln(summary['input']);
  row('format', summary['format']);
  row('sport', summary['sport']);
  if (summary['start'] != null) {
    final start = DateTime.parse(summary['start'] as String);
    final end = DateTime.parse(summary['end'] as String);
    row(
      'time',
      '${_isoSeconds(start)} to ${_isoSeconds(end)} '
          '(${_formatDuration(end.difference(start))})',
    );
  }
  row('points', summary['points']);
  final channels = summary['channels'] as Map<String, int>;
  row(
    'channels',
    channels.isEmpty
        ? 'none'
        : channels.entries.map((e) => '${e.key} ${e.value}').join(', '),
  );
  for (final key in [
    'laps',
    'sessions',
    'tracks',
    'waypoints',
    'routes',
    'lengths',
    'sets',
    'events',
  ]) {
    final count = summary[key] as int;
    if (key == 'laps' || count > (key == 'tracks' ? 1 : 0)) row(key, count);
  }
  final device = summary['device'] as Map<String, Object?>?;
  if (device != null && device.isNotEmpty) {
    row(
      'device',
      [
        device['manufacturer'],
        device['model'] ?? device['product'],
      ].whereType<String>().join(' '),
    );
  }
  row('creator', summary['creator']);
  final diagnostics = (summary['diagnostics'] as List<Map<String, Object?>>)
      .where((d) => d['severity'] != 'info')
      .toList();
  for (final severity in ['error', 'warning']) {
    final items = diagnostics.where((d) => d['severity'] == severity).toList();
    if (items.isEmpty) continue;
    row('${severity}s', items.length);
    for (final d in items) {
      stdout.writeln('    - ${d['code']}: ${d['message']}');
    }
  }
}

/// How an output target is named in messages.
String _shown(String target) => target == '-' ? 'stdout' : target;

String _isoSeconds(DateTime time) =>
    '${time.toUtc().toIso8601String().split('.').first}Z';

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  return [
    if (hours > 0) '${hours}h',
    if (hours > 0 || minutes > 0) '${minutes}m',
    '${seconds}s',
  ].join();
}
