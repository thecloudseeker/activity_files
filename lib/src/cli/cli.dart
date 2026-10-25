// SPDX-License-Identifier: BSD-3-Clause
/// The `activity_files` command line: the library's file operations as
/// commands. Not exported; `bin/activity_files.dart` is its only caller.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';

import '../../activity_files.dart';

part 'cli_commands.dart';
part 'cli_inputs.dart';
part 'cli_options.dart';
part 'cli_report.dart';
part 'cli_time.dart';

/// The package version `--version` prints; the release checks keep it equal
/// to `pubspec.yaml`.
const cliVersion = '0.8.5';

/// Exit codes, following the BSD `sysexits.h` convention.
const _exitOk = 0;
const _exitUsage = 64;
const _exitData = 65;
const _exitNoInput = 66;
const _exitSoftware = 70;

/// Runs the command line with [arguments] and returns the exit code.
Future<int> runCli(List<String> arguments) async {
  final parser = _buildParser();
  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on ArgParserException catch (e) {
    _error(e.message);
    _error('Run "activity_files --help" to see the commands.');
    return _exitUsage;
  }

  if (results['version'] == true) {
    stdout.writeln('activity_files $cliVersion');
    return _exitOk;
  }
  final command = results.command;
  if (command == null) {
    if (results.rest.isNotEmpty) {
      _error('Unknown command: ${results.rest.first}');
      _printUsage(stderr);
      return _exitUsage;
    }
    _printUsage(stdout);
    return _exitOk;
  }
  final name = command.name!;
  if (command['help'] == true) {
    stdout.writeln('Usage: activity_files $name [options]');
    stdout.writeln(_commandSummaries[name]);
    stdout.writeln();
    stdout.writeln(parser.commands[name]!.usage);
    return _exitOk;
  }

  try {
    _warnDeprecatedOptions(command);
    return switch (name) {
      'convert' => await _runConvert(command),
      'edit' => await _runEdit(command),
      'merge' => await _runMerge(command),
      'split' => await _runSplit(command),
      'validate' => await _runValidate(command),
      'inspect' => await _runInspect(command),
      _ => throw StateError('Unhandled command $name'),
    };
  } on _CliException catch (e) {
    _error(e.message);
    return e.exitCode;
  }
}

/// A failure that ends the run with [exitCode].
class _CliException implements Exception {
  _CliException(this.message, [this.exitCode = _exitUsage]);

  final String message;
  final int exitCode;
}

/// Raises a usage error (exit 64).
Never _usage(String message) => throw _CliException(message);

void _error(String message) => stderr.writeln(message);

const _commandSummaries = <String, String>{
  'convert': 'Writes activity files in another format.',
  'edit':
      'Changes an activity step by step, in the order the steps are typed, '
      'and writes it once.',
  'merge': 'Combines several activity files into one.',
  'split': 'Writes one file per leg of a multi-sport activity.',
  'validate': 'Checks activity files and reports what is wrong.',
  'inspect': 'Summarizes what activity files contain.',
};

void _printUsage(IOSink sink) {
  sink.writeln('Usage: activity_files <command> [options]');
  sink.writeln();
  sink.writeln('Commands:');
  for (final entry in _commandSummaries.entries) {
    sink.writeln('  ${entry.key.padRight(9)} ${entry.value}');
  }
  sink.writeln();
  sink.writeln(
    'Run "activity_files <command> --help" to see the options of a command.',
  );
  sink.writeln('Run "activity_files --version" to print the version.');
}
