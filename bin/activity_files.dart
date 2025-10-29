// MIT License
//
// Copyright (c) 2024 activity_files
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import 'dart:convert';
import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:args/args.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final convertParser = ArgParser()
    ..addOption(
      'from',
      allowed: ['gpx', 'tcx', 'fit'],
      help: 'Input format.',
    )
    ..addOption(
      'to',
      allowed: ['gpx', 'tcx', 'fit'],
      help: 'Output format.',
    )
    ..addOption('input', abbr: 'i', help: 'Input file path.')
    ..addOption('output', abbr: 'o', help: 'Output file path.')
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
      _handleConvert(results.command!);
      break;
    case 'validate':
      _handleValidate(results.command!);
      break;
    default:
      _printError('Unknown command: ${results.command!.name}');
      _printUsage(parser);
      exitCode = 64;
  }
}

void _handleConvert(ArgResults command) {
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

  final inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    _printError('Input file not found: $inputPath');
    exitCode = 66;
    return;
  }

  final encoderOptions = _buildEncoderOptions(command);
  final content = fromFormat == ActivityFileFormat.fit
      ? base64Encode(inputFile.readAsBytesSync())
      : inputFile.readAsStringSync();

  final warnings = <String>[];
  try {
    final output = ActivityConverter.convert(
      content,
      from: fromFormat,
      to: toFormat,
      encoderOptions: encoderOptions,
      warnings: warnings,
    );
    if (toFormat == ActivityFileFormat.fit) {
      File(outputPath).writeAsBytesSync(base64Decode(output));
    } else {
      File(outputPath).writeAsStringSync(output);
    }
    stdout.writeln('Converted $inputPath → $outputPath');
    _printWarnings(warnings);
  } on UnimplementedError catch (e) {
    _printError(e.message ?? 'Conversion not implemented for selected format.');
    exitCode = 70;
  } on Object catch (e) {
    _printError('Conversion failed: $e');
    exitCode = 70;
  }
}

void _handleValidate(ArgResults command) {
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

  final gapSeconds = double.tryParse(command['gap-threshold'] as String? ?? '');
  final gapThreshold = gapSeconds != null && gapSeconds > 0
      ? Duration(milliseconds: (gapSeconds * 1000).round())
      : const Duration(minutes: 5);

  final warnings = <String>[];
  try {
    final payload = format == ActivityFileFormat.fit
        ? base64Encode(inputFile.readAsBytesSync())
        : inputFile.readAsStringSync();
    final parseResult = ActivityParser.parse(payload, format);
    warnings.addAll(parseResult.warnings);
    final validation = validateRawActivity(
      parseResult.activity,
      gapWarningThreshold: gapThreshold,
    );

    _printWarnings(warnings);
    if (validation.errors.isEmpty) {
      stdout.writeln(
          'Validation passed (${parseResult.activity.points.length} points).');
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
  final defaultDeltaSeconds =
      double.tryParse(command['max-delta-seconds'] as String? ?? '');
  final defaultDelta = defaultDeltaSeconds != null && defaultDeltaSeconds >= 0
      ? Duration(milliseconds: (defaultDeltaSeconds * 1000).round())
      : const Duration(seconds: 5);

  final precisionLatLon =
      int.tryParse(command['precision-latlon'] as String? ?? '') ?? 6;
  final precisionEle =
      int.tryParse(command['precision-ele'] as String? ?? '') ?? 2;

  Duration? parseChannelDelta(String? value) {
    final seconds = double.tryParse(value ?? '');
    if (seconds == null || seconds < 0) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  final overrides = <Channel, Duration>{};
  final hrDelta = parseChannelDelta(command['hr-max-delta'] as String?);
  final cadenceDelta =
      parseChannelDelta(command['cadence-max-delta'] as String?);
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
  );
}

void _printUsage(ArgParser parser) {
  stdout.writeln('Usage: activity_files <command> [arguments]');
  stdout.writeln('Commands:');
  stdout.writeln('  convert   Convert between formats');
  stdout.writeln('  validate  Validate an activity file');
  stdout.writeln('\nUse --help with a command to see additional options.');
}

void _printWarnings(List<String> warnings) {
  if (warnings.isEmpty) {
    return;
  }
  stdout.writeln('Parser warnings:');
  for (final warning in warnings) {
    stdout.writeln('  - $warning');
  }
}

void _printError(String message) {
  stderr.writeln(message);
}
