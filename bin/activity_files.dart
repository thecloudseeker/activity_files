// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2024-2026 Eike Dreier
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

import 'dart:convert';
import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:args/args.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final convertParser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addOption(
      'from',
      allowed: ['gpx', 'tcx', 'fit', 'csv', 'geojson'],
      help: 'Input format.',
    )
    ..addOption(
      'to',
      allowed: ['gpx', 'tcx', 'fit', 'csv', 'geojson'],
      help: 'Output format.',
    )
    ..addOption('input', abbr: 'i', help: 'Input file path.')
    ..addOption('output', abbr: 'o', help: 'Output file path.')
    ..addOption(
      'encoding',
      help: 'Text encoding for GPX/TCX/CSV/GeoJSON inputs.',
      defaultsTo: 'utf-8',
    )
    ..addOption(
      'max-delta-seconds',
      help: 'Default channel matching tolerance in seconds.',
    )
    ..addOption(
      'precision-latlon',
      help: 'Latitude/longitude precision (fractional digits).',
    )
    ..addOption(
      'precision-ele',
      help: 'Elevation precision (fractional digits).',
    )
    ..addOption(
      'hr-max-delta',
      help: 'Override heart-rate matching tolerance (seconds).',
    )
    ..addOption(
      'cadence-max-delta',
      help: 'Override cadence matching tolerance (seconds).',
    )
    ..addOption(
      'power-max-delta',
      help: 'Override power matching tolerance (seconds).',
    )
    ..addOption(
      'temp-max-delta',
      help: 'Override temperature matching tolerance (seconds).',
    )
    ..addOption(
      'gpx-version',
      allowed: ['1.1', '1.0'],
      defaultsTo: '1.1',
      help: 'GPX version to emit when exporting to GPX.',
    )
    ..addOption(
      'tcx-version',
      allowed: ['2', '1'],
      defaultsTo: '2',
      help: 'TCX version to emit when exporting to TCX.',
    );

  final validateParser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addOption(
      'format',
      allowed: ['gpx', 'tcx', 'fit', 'csv', 'geojson'],
      help: 'Format to validate.',
    )
    ..addOption('input', abbr: 'i', help: 'Input file path.')
    ..addOption(
      'encoding',
      help: 'Text encoding for GPX/TCX/CSV/GeoJSON inputs.',
      defaultsTo: 'utf-8',
    )
    ..addOption(
      'gap-threshold',
      help: 'Warn when gaps exceed this many seconds (default 300).',
    );

  parser.addCommand('convert', convertParser);
  parser.addCommand('validate', validateParser);

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } on ArgParserException catch (e) {
    _printError(e.message);
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  if (results.command == null && results.rest.isNotEmpty) {
    _printError('Unknown command: ${results.rest.first}');
    _printUsage(parser);
    exitCode = 64;
    return;
  }
  if (results['help'] == true || results.command == null) {
    _printUsage(parser);
    return;
  }

  final command = results.command!;
  if (command['help'] == true) {
    _printCommandUsage(command.name!, parser.commands[command.name]!);
    return;
  }

  try {
    switch (command.name) {
      case 'convert':
        await _handleConvert(command);
      case 'validate':
        await _handleValidate(command);
    }
  } on _UsageException catch (e) {
    _printError(e.message);
    exitCode = 64;
  }
}

/// An invalid command-line value; reported with exit code 64.
class _UsageException implements Exception {
  _UsageException(this.message);

  final String message;
}

Future<void> _handleConvert(ArgResults command) async {
  final inputPath = command['input'] as String?;
  final outputPath = command['output'] as String?;
  final fromFormat = _parseFormat(command['from'] as String?);
  final toFormat = _parseFormat(command['to'] as String?);

  if (inputPath == null ||
      outputPath == null ||
      fromFormat == null ||
      toFormat == null) {
    _printError('convert requires --from, --to, --input, and --output.');
    exitCode = 64;
    return;
  }
  final encoding = _encodingOption(command);

  final inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    _printError('Input file not found: $inputPath');
    exitCode = 66;
    return;
  }
  final size = inputFile.lengthSync();
  if (size > ActivityFiles.defaultMaxPayloadBytes) {
    _printError(
      'Input file exceeds ${ActivityFiles.defaultMaxPayloadBytes} bytes.',
    );
    exitCode = 65;
    return;
  }

  final encoderOptions = _buildEncoderOptions(command);
  final payload = inputFile.readAsBytesSync();

  try {
    final conversion = await ActivityFiles.convert(
      source: payload,
      from: fromFormat,
      to: toFormat,
      options: encoderOptions,
      encoding: encoding,
      allowFilePaths: false,
    );
    final diagnostics = conversion.diagnostics;
    final hasErrors = diagnostics.any(
      (diagnostic) => diagnostic.severity == ParseSeverity.error,
    );
    _printDiagnostics(diagnostics);
    if (hasErrors) {
      _printError('Conversion aborted due to parser errors.');
      exitCode = 65;
      return;
    }
    if (toFormat == ActivityFileFormat.fit) {
      File(outputPath).writeAsBytesSync(conversion.asBytes());
    } else {
      File(outputPath).writeAsStringSync(conversion.asString());
    }
    stdout.writeln('Converted $inputPath → $outputPath');
  } on UnimplementedError catch (e) {
    _printError(e.message ?? 'Conversion not implemented for selected format.');
    exitCode = 70;
  } on Object catch (e) {
    _printError('Conversion failed: $e');
    exitCode = 70;
  }
}

Future<void> _handleValidate(ArgResults command) async {
  final inputPath = command['input'] as String?;
  final format = _parseFormat(command['format'] as String?);
  if (inputPath == null || format == null) {
    _printError('validate requires --format and --input.');
    exitCode = 64;
    return;
  }

  final inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    _printError('Input file not found: $inputPath');
    exitCode = 66;
    return;
  }
  final size = inputFile.lengthSync();
  if (size > ActivityFiles.defaultMaxPayloadBytes) {
    _printError(
      'Input file exceeds ${ActivityFiles.defaultMaxPayloadBytes} bytes.',
    );
    exitCode = 65;
    return;
  }

  final encoding = _encodingOption(command);
  final gapThreshold =
      _secondsOption(command, 'gap-threshold', allowZero: false) ??
      const Duration(minutes: 5);

  try {
    final parseResult = await ActivityFiles.import(
      inputFile.readAsBytesSync(),
      format: format,
      encoding: encoding,
      useIsolate: false,
    );
    final validation = ActivityFiles.validate(
      parseResult.activity,
      gapWarningThreshold: gapThreshold,
    );

    _printDiagnostics(parseResult.diagnostics);
    if (parseResult.diagnostics.any(
      (diagnostic) => diagnostic.severity == ParseSeverity.error,
    )) {
      stdout.writeln('Validation failed: the file could not be read.');
      exitCode = 65;
      return;
    }
    if (validation.errors.isEmpty) {
      stdout.writeln(
        'Validation passed (${parseResult.activity.points.length} points).',
      );
      if (validation.warnings.isNotEmpty) {
        stdout.writeln('Warnings:');
        for (final warning in validation.warnings) {
          stdout.writeln('  - $warning');
        }
      }
    } else {
      stdout.writeln('Validation failed:');
      for (final error in validation.errors) {
        stdout.writeln('  - $error');
      }
      if (validation.warnings.isNotEmpty) {
        stdout.writeln('Warnings:');
        for (final warning in validation.warnings) {
          stdout.writeln('  - $warning');
        }
      }
      exitCode = 65;
    }
  } on UnimplementedError catch (e) {
    _printError(e.message ?? 'Validation not implemented for selected format.');
    exitCode = 70;
  } on Object catch (e) {
    _printError('Validation failed: $e');
    exitCode = 70;
  }
}

ActivityFileFormat? _parseFormat(String? value) {
  switch (value) {
    case 'gpx':
      return ActivityFileFormat.gpx;
    case 'tcx':
      return ActivityFileFormat.tcx;
    case 'fit':
      return ActivityFileFormat.fit;
    case 'csv':
      return ActivityFileFormat.csv;
    case 'geojson':
      return ActivityFileFormat.geojson;
    default:
      return null;
  }
}

EncoderOptions _buildEncoderOptions(ArgResults command) {
  final defaultDelta =
      _secondsOption(command, 'max-delta-seconds') ??
      const Duration(seconds: 5);
  final precisionLatLon = _digitsOption(command, 'precision-latlon') ?? 6;
  final precisionEle = _digitsOption(command, 'precision-ele') ?? 2;
  final gpxVersionRaw = (command['gpx-version'] as String? ?? '').trim();
  final gpxVersion = gpxVersionRaw == '1.0' ? GpxVersion.v1_0 : GpxVersion.v1_1;
  final tcxVersionRaw = (command['tcx-version'] as String? ?? '').trim();
  final tcxVersion = tcxVersionRaw == '1' ? TcxVersion.v1 : TcxVersion.v2;

  final overrides = <Channel, Duration>{};
  final hrDelta = _secondsOption(command, 'hr-max-delta');
  final cadenceDelta = _secondsOption(command, 'cadence-max-delta');
  final powerDelta = _secondsOption(command, 'power-max-delta');
  final tempDelta = _secondsOption(command, 'temp-max-delta');

  if (hrDelta != null) overrides[Channel.heartRate] = hrDelta;
  if (cadenceDelta != null) overrides[Channel.cadence] = cadenceDelta;
  if (powerDelta != null) overrides[Channel.power] = powerDelta;
  if (tempDelta != null) overrides[Channel.temperature] = tempDelta;

  return EncoderOptions(
    defaultMaxDelta: defaultDelta,
    maxDeltaPerChannel: overrides,
    precisionLatLon: precisionLatLon,
    precisionEle: precisionEle,
    gpxVersion: gpxVersion,
    tcxVersion: tcxVersion,
  );
}

void _printUsage(ArgParser parser) {
  stdout.writeln('Usage: activity_files <command> [arguments]');
  stdout.writeln('Commands:');
  stdout.writeln('  convert   Convert between gpx/tcx/fit/csv/geojson');
  stdout.writeln('  validate  Validate an activity file');
  stdout.writeln(
    '\nRun "activity_files <command> --help" to see the options of a command.',
  );
}

void _printCommandUsage(String name, ArgParser parser) {
  stdout.writeln('Usage: activity_files $name [options]');
  stdout.writeln(parser.usage);
}

/// Reads `--encoding`; an unknown name is a usage error.
Encoding _encodingOption(ArgResults command) {
  final name = (command['encoding'] as String?)?.trim() ?? '';
  if (name.isEmpty) {
    return utf8;
  }
  final encoding = _encodingByName(name);
  if (encoding == null) {
    throw _UsageException('Unknown encoding "$name".');
  }
  return encoding;
}

/// Reads a duration given in seconds, or null when the option is absent.
Duration? _secondsOption(
  ArgResults command,
  String name, {
  bool allowZero = true,
}) {
  final raw = (command[name] as String?)?.trim();
  if (raw == null) {
    return null;
  }
  final seconds = double.tryParse(raw);
  if (seconds == null ||
      !seconds.isFinite ||
      seconds < 0 ||
      (!allowZero && seconds == 0)) {
    throw _UsageException(
      '--$name must be ${allowZero ? 'zero or more' : 'more than zero'} '
      'seconds, got "$raw".',
    );
  }
  return Duration(milliseconds: (seconds * 1000).round());
}

/// Reads a number of fractional digits (0 to 20), or null when absent.
int? _digitsOption(ArgResults command, String name) {
  final raw = (command[name] as String?)?.trim();
  if (raw == null) {
    return null;
  }
  final digits = int.tryParse(raw);
  if (digits == null || digits < 0 || digits > 20) {
    throw _UsageException(
      '--$name must be a whole number from 0 to 20, got "$raw".',
    );
  }
  return digits;
}

void _printDiagnostics(
  Iterable<ParseDiagnostic> diagnostics, {
  ParseSeverity minimum = ParseSeverity.warning,
}) {
  final tracked = diagnostics
      .where((diagnostic) => diagnostic.severity.index >= minimum.index)
      .toList();
  if (tracked.isEmpty) {
    return;
  }
  stdout.writeln('Parser diagnostics:');
  for (final diagnostic in tracked) {
    final nodeLabel = diagnostic.node?.format();
    final codeLabel = diagnostic.code;
    final severityLabel = diagnostic.severity.name.toUpperCase();
    final context = [?nodeLabel, codeLabel].join(' • ');
    stdout.writeln(
      '  - $severityLabel${context.isNotEmpty ? ' $context' : ''}',
    );
    stdout.writeln('      ${diagnostic.message}');
  }
}

/// Resolves an `--encoding` value by its IANA name, also accepting `utf8`,
/// which `Encoding.getByName` does not know.
Encoding? _encodingByName(String name) {
  final normalized = name.toLowerCase();
  return normalized == 'utf8' ? utf8 : Encoding.getByName(normalized);
}

void _printError(String message) {
  stderr.writeln(message);
}
