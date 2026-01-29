// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2024 activity_files
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
    ..addOption('from', allowed: ['gpx', 'tcx', 'fit'], help: 'Input format.')
    ..addOption('to', allowed: ['gpx', 'tcx', 'fit'], help: 'Output format.')
    ..addOption('input', abbr: 'i', help: 'Input file path.')
    ..addOption('output', abbr: 'o', help: 'Output file path.')
    ..addOption(
      'encoding',
      help: 'Text encoding for GPX/TCX inputs (default utf8).',
      defaultsTo: 'utf8',
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
    ..addOption(
      'format',
      allowed: ['gpx', 'tcx', 'fit'],
      help: 'Format to validate.',
    )
    ..addOption('input', abbr: 'i', help: 'Input file path.')
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

  if (results['help'] == true || results.command == null) {
    _printUsage(parser);
    return;
  }

  switch (results.command!.name) {
    case 'convert':
      await _handleConvert(results.command!);
      break;
    case 'validate':
      await _handleValidate(results.command!);
      break;
    default:
      _printError('Unknown command: ${results.command!.name}');
      _printUsage(parser);
      exitCode = 64;
  }
}

Future<void> _handleConvert(ArgResults command) async {
  final inputPath = command['input'] as String?;
  final outputPath = command['output'] as String?;
  final fromFormat = _parseFormat(command['from'] as String?);
  final toFormat = _parseFormat(command['to'] as String?);
  final encodingName = (command['encoding'] as String?)?.trim();
  final encoding = encodingName == null || encodingName.isEmpty
      ? utf8
      : (encodingName.toLowerCase() == 'utf8'
            ? utf8
            : Encoding.getByName(encodingName.toLowerCase()));

  if (inputPath == null ||
      outputPath == null ||
      fromFormat == null ||
      toFormat == null) {
    _printError('convert requires --from, --to, --input, and --output.');
    exitCode = 64;
    return;
  }
  if (encoding == null) {
    _printError('Unknown encoding "$encodingName".');
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

  final gapSeconds = double.tryParse(command['gap-threshold'] as String? ?? '');
  final gapThreshold = gapSeconds != null && gapSeconds > 0
      ? Duration(milliseconds: (gapSeconds * 1000).round())
      : const Duration(minutes: 5);

  final parserDiagnostics = <ParseDiagnostic>[];
  try {
    final payload = format == ActivityFileFormat.fit
        ? inputFile.readAsBytesSync()
        : inputFile.readAsStringSync();
    final parseResult = payload is List<int>
        ? ActivityParser.parseBytes(payload, format)
        : ActivityParser.parse(payload as String, format);
    parserDiagnostics.addAll(parseResult.diagnostics);
    final validation = validateRawActivity(
      parseResult.activity,
      gapWarningThreshold: gapThreshold,
    );

    _printDiagnostics(parserDiagnostics);
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
    default:
      return null;
  }
}

EncoderOptions _buildEncoderOptions(ArgResults command) {
  final defaultDeltaSeconds = double.tryParse(
    command['max-delta-seconds'] as String? ?? '',
  );
  final defaultDelta = defaultDeltaSeconds != null && defaultDeltaSeconds >= 0
      ? Duration(milliseconds: (defaultDeltaSeconds * 1000).round())
      : const Duration(seconds: 5);

  final precisionLatLon =
      int.tryParse(command['precision-latlon'] as String? ?? '') ?? 6;
  final precisionEle =
      int.tryParse(command['precision-ele'] as String? ?? '') ?? 2;
  final gpxVersionRaw = (command['gpx-version'] as String? ?? '').trim();
  final gpxVersion = gpxVersionRaw == '1.0' ? GpxVersion.v1_0 : GpxVersion.v1_1;
  final tcxVersionRaw = (command['tcx-version'] as String? ?? '').trim();
  final tcxVersion = tcxVersionRaw == '1' ? TcxVersion.v1 : TcxVersion.v2;

  Duration? parseChannelDelta(String? value) {
    final seconds = double.tryParse(value ?? '');
    if (seconds == null || seconds < 0) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  final overrides = <Channel, Duration>{};
  final hrDelta = parseChannelDelta(command['hr-max-delta'] as String?);
  final cadenceDelta = parseChannelDelta(
    command['cadence-max-delta'] as String?,
  );
  final powerDelta = parseChannelDelta(command['power-max-delta'] as String?);
  final tempDelta = parseChannelDelta(command['temp-max-delta'] as String?);

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
  stdout.writeln('  convert   Convert between formats');
  stdout.writeln('  validate  Validate an activity file');
  stdout.writeln('\nUse --help with a command to see additional options.');
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
    final context = [if (nodeLabel != null) nodeLabel, codeLabel].join(' • ');
    stdout.writeln(
      '  - $severityLabel${context.isNotEmpty ? ' $context' : ''}',
    );
    stdout.writeln('      ${diagnostic.message}');
  }
}

void _printError(String message) {
  stderr.writeln(message);
}
