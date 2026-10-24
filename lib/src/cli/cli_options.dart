// SPDX-License-Identifier: BSD-3-Clause
part of 'cli.dart';

const _formatNames = ['gpx', 'tcx', 'fit', 'csv', 'geojson'];

/// Edit steps that take no value, in the order they appear in `--help`.
const _flagSteps = [
  'sort-and-dedup',
  'strict-time-order',
  'trim-invalid',
  'recompute-distance-and-speed',
  'auto-fix',
];

/// Edit steps that take a value.
const _valueSteps = {
  'crop': 'FROM..TO',
  'shift-time': 'DURATION',
  'insert-point': 'TIME,LAT,LON[,ELE]',
  'update-point': 'INDEX,lat=..,lon=..,ele=..,time=..',
  'delete-point': 'INDEX',
  'delete-range': 'FROM..TO',
  'insert-pause': 'AT,DURATION',
  'remove-pause': 'FROM..TO',
  'downsample-time': 'DURATION',
  'downsample-distance': 'METERS',
  'smooth-hr': 'WINDOW',
  'mark-laps-by-distance': 'METERS',
  'resample': 'DURATION',
};

/// Options kept working as hidden aliases until 0.10.0, with what replaces
/// them; using one prints a warning.
const _deprecatedOptions = {
  'format': '--from',
  'hr-max-delta': '--channel-max-delta heart_rate=SECONDS',
  'cadence-max-delta': '--channel-max-delta cadence=SECONDS',
  'power-max-delta': '--channel-max-delta power=SECONDS',
  'temp-max-delta': '--channel-max-delta temperature=SECONDS',
};

/// The channel each deprecated per-channel tolerance sets.
final _deprecatedChannelOptions = {
  'hr-max-delta': Channel.heartRate,
  'cadence-max-delta': Channel.cadence,
  'power-max-delta': Channel.power,
  'temp-max-delta': Channel.temperature,
};

ArgParser _buildParser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addFlag(
      'version',
      negatable: false,
      help: 'Print the activity_files version.',
    );
  parser.addCommand(
    'convert',
    _commandParser(write: true, autoFix: true, deprecatedChannelDeltas: true),
  );
  parser.addCommand(
    'edit',
    _commandParser(write: true, autoFixTuning: true, steps: true),
  );
  parser.addCommand(
    'merge',
    _commandParser(write: true, batch: false)
      ..addFlag(
        'preserve-sport-per-lap',
        negatable: false,
        help: "Give each lap its source file's sport (multi-sport merges).",
      )
      ..addOption('creator', help: 'Software name written as the creator.'),
  );
  parser.addCommand('split', _commandParser(write: true, batch: false));
  parser.addCommand(
    'validate',
    _commandParser(deprecatedFormat: true)..addOption(
      'gap-threshold',
      help: 'Report gaps between points longer than this duration.',
      defaultsTo: '5m',
      valueHelp: 'DURATION',
    ),
  );
  parser.addCommand('inspect', _commandParser());
  return parser;
}

ArgParser _commandParser({
  bool write = false,
  bool autoFix = false,
  bool autoFixTuning = false,
  bool steps = false,
  bool batch = true,
  bool deprecatedFormat = false,
  bool deprecatedChannelDeltas = false,
}) {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addMultiOption(
      'input',
      abbr: 'i',
      help: 'Input file, folder, or - for stdin. Repeat for more inputs.',
      valueHelp: 'PATH',
      splitCommas: false,
    )
    ..addOption(
      'from',
      allowed: _formatNames,
      help: 'Input format. Detected when left out.',
    )
    ..addFlag(
      'recursive',
      negatable: false,
      help: 'Also read the subfolders of a folder input.',
    )
    ..addOption(
      'encoding',
      defaultsTo: 'utf-8',
      help: 'Text encoding of GPX/TCX/CSV/GeoJSON input: utf-8, latin1, ascii.',
    )
    ..addFlag(
      'strict-fit',
      negatable: false,
      help:
          'Refuse a FIT file with integrity errors instead of keeping what '
          'could be read.',
    )
    ..addOption(
      'max-payload-bytes',
      defaultsTo: '${ActivityFiles.defaultMaxPayloadBytes}',
      help: 'Largest input in bytes, or none.',
      valueHelp: 'BYTES',
    )
    ..addFlag(
      'json',
      negatable: false,
      help: write
          ? 'Report diagnostics as JSON Lines on stderr.'
          : 'Write the report as JSON Lines on stdout.',
    );
  if (batch) {
    parser.addFlag(
      'stop-on-error',
      negatable: false,
      help: 'Stop at the first file that fails.',
    );
  }
  if (write) _addWriteOptions(parser);
  if (autoFix) {
    parser.addFlag(
      'auto-fix',
      negatable: false,
      help: 'Repair common data problems during the conversion.',
    );
  }
  if (autoFix || autoFixTuning) _addAutoFixOptions(parser);
  if (steps) _addEditSteps(parser);
  if (deprecatedFormat) parser.addOption('format', hide: true);
  if (deprecatedChannelDeltas) {
    for (final option in _deprecatedChannelOptions.keys) {
      parser.addOption(option, hide: true);
    }
  }
  return parser;
}

void _addWriteOptions(ArgParser parser) {
  parser
    ..addOption('output', abbr: 'o', help: 'Output file, or - for stdout.')
    ..addOption(
      'out-dir',
      help: 'Output folder, for several inputs, folders, and split.',
    )
    ..addOption('to', allowed: _formatNames, help: 'Output format.')
    ..addFlag(
      'normalize',
      defaultsTo: true,
      help: 'Sort, remove duplicates and invalid points before writing.',
    )
    ..addFlag(
      'validate',
      defaultsTo: true,
      help: 'Validate the written activity and report what is wrong.',
    )
    ..addOption(
      'precision-latlon',
      defaultsTo: '6',
      help: 'Decimal places for latitude and longitude, 0 to 20.',
    )
    ..addOption(
      'precision-ele',
      defaultsTo: '2',
      help: 'Decimal places for elevation, 0 to 20.',
    )
    ..addOption(
      'max-delta-seconds',
      defaultsTo: '5s',
      help:
          'How far a sensor sample may lie from a point and still be written '
          'with it.',
      valueHelp: 'DURATION',
    )
    ..addMultiOption(
      'channel-max-delta',
      help: 'The same for one channel; repeat for more.',
      valueHelp: 'CHANNEL=DURATION',
      splitCommas: false,
    )
    ..addOption('gpx-version', allowed: ['1.1', '1.0'], defaultsTo: '1.1')
    ..addOption('tcx-version', allowed: ['2', '1'], defaultsTo: '2')
    ..addOption(
      'geojson-geometry',
      allowed: ['line', 'points'],
      defaultsTo: 'line',
      help: 'A LineString feature, or one Point feature per sample.',
    )
    ..addFlag(
      'geojson-channels',
      negatable: false,
      help: 'Write sensor values onto GeoJSON points.',
    );
}

void _addAutoFixOptions(ArgParser parser) {
  parser
    ..addFlag(
      'fix-invalid-gps',
      defaultsTo: true,
      help: 'Auto-fix: drop invalid coordinates.',
    )
    ..addFlag(
      'fix-channel-drift',
      defaultsTo: true,
      help: 'Auto-fix: align sensor samples with the track.',
    )
    ..addFlag(
      'fix-distance-drift',
      defaultsTo: true,
      help: 'Auto-fix: recompute distance and speed.',
    )
    ..addFlag(
      'fix-timestamp-gaps',
      defaultsTo: true,
      help: 'Auto-fix: fill gaps longer than --gap-fill-threshold.',
    )
    ..addOption(
      'gap-fill-threshold',
      defaultsTo: '5m',
      help: 'Auto-fix: shortest gap that gets filled.',
      valueHelp: 'DURATION',
    )
    ..addOption(
      'max-gap-points',
      defaultsTo: '250',
      help: 'Auto-fix: most points inserted per gap.',
    )
    ..addFlag(
      'auto-lap',
      negatable: false,
      help: 'Auto-fix: add laps by distance.',
    )
    ..addFlag(
      'auto-lap-always',
      negatable: false,
      help: 'Auto-fix: add laps even when the file has laps.',
    )
    ..addOption(
      'auto-lap-distance',
      help: 'Auto-fix: lap distance in meters for every sport.',
      valueHelp: 'METERS',
    )
    ..addOption(
      'running-lap-distance',
      defaultsTo: '1000',
      help: 'Auto-fix: lap distance in meters for running.',
      valueHelp: 'METERS',
    )
    ..addOption(
      'cycling-lap-distance',
      defaultsTo: '5000',
      help: 'Auto-fix: lap distance in meters for cycling.',
      valueHelp: 'METERS',
    )
    ..addOption(
      'default-lap-distance',
      defaultsTo: '1000',
      help: 'Auto-fix: lap distance in meters for other sports.',
      valueHelp: 'METERS',
    );
}

void _addEditSteps(ArgParser parser) {
  const help = {
    'sort-and-dedup': 'Step: sort by time and remove duplicates.',
    'strict-time-order':
        'Step: sort by time and nudge duplicate timestamps apart.',
    'trim-invalid': 'Step: remove invalid coordinates and sentinel values.',
    'recompute-distance-and-speed':
        'Step: recompute distance and speed from the track.',
    'auto-fix': 'Step: run the auto-fix repairs (tuned by the options above).',
    'crop': 'Step: keep only FROM..TO.',
    'shift-time': 'Step: move every timestamp by DURATION (may be negative).',
    'insert-point': 'Step: insert a point.',
    'update-point': 'Step: change the point at INDEX (counting from 0).',
    'delete-point': 'Step: remove the point at INDEX (counting from 0).',
    'delete-range': 'Step: remove everything in FROM..TO.',
    'insert-pause': 'Step: insert a pause of DURATION at AT.',
    'remove-pause': 'Step: close the gap FROM..TO.',
    'downsample-time': 'Step: keep at most one point per DURATION.',
    'downsample-distance': 'Step: keep at most one point per METERS.',
    'smooth-hr': 'Step: smooth heart rate over WINDOW samples.',
    'mark-laps-by-distance': 'Step: replace the laps with one per METERS.',
    'resample': 'Step: put points and channels on a DURATION grid.',
  };
  for (final step in _flagSteps) {
    parser.addFlag(step, negatable: false, help: help[step]);
  }
  for (final entry in _valueSteps.entries) {
    parser.addMultiOption(
      entry.key,
      help: help[entry.key],
      valueHelp: entry.value,
      splitCommas: false,
    );
  }
}

/// Warns once on stderr for each deprecated option used; with `--json` the
/// warning is a JSON line, so stderr stays machine-readable.
void _warnDeprecatedOptions(ArgResults command) {
  for (final entry in _deprecatedOptions.entries) {
    if (command.options.contains(entry.key) && command.wasParsed(entry.key)) {
      final warning =
          '--${entry.key} is deprecated, use ${entry.value}; removed in '
          '0.10.0';
      if (command.options.contains('json') && command['json'] == true) {
        _printJson(stderr, {'warning': warning});
      } else {
        _error(warning);
      }
    }
  }
}

/// `--from`, or the deprecated `--format` of `validate`.
ActivityFileFormat? _fromOption(ArgResults command) {
  final from = _formatOption(command, 'from');
  if (from != null || !command.options.contains('format')) return from;
  final legacy = _string(command, 'format');
  if (legacy == null) return null;
  if (!_formatNames.contains(legacy)) {
    _usage(
      '--format must be one of ${_formatNames.join(', ')}, got "$legacy".',
    );
  }
  return ActivityFileFormat.values.byName(legacy);
}

// Value readers. Each rejects anything it cannot read exactly, so nothing
// falls back to a default unnoticed.

String? _string(ArgResults command, String name) {
  if (!command.options.contains(name)) return null;
  final value = command[name] as String?;
  return value?.trim();
}

int _intOption(ArgResults command, String name, {int min = 0, int? max}) {
  final raw = _string(command, name) ?? '';
  final value = int.tryParse(raw);
  if (value == null || value < min || (max != null && value > max)) {
    final range = max == null ? '$min or more' : 'from $min to $max';
    _usage('--$name must be a whole number $range, got "$raw".');
  }
  return value;
}

double _metersValue(String raw, String what) {
  final value = double.tryParse(raw.trim());
  if (value == null || !value.isFinite || value <= 0) {
    _usage('$what must be a distance in meters above 0, got "$raw".');
  }
  return value;
}

Duration _durationOption(
  ArgResults command,
  String name, {
  bool allowZero = true,
}) => _durationValue(
  _string(command, name) ?? '',
  '--$name',
  allowZero: allowZero,
);

int? _maxPayloadBytes(ArgResults command) {
  final raw = _string(command, 'max-payload-bytes')!;
  if (raw == 'none') return null;
  return _intOption(command, 'max-payload-bytes', min: 1);
}

/// Reads `--encoding`; `utf8` is accepted besides the IANA names.
Encoding _encoding(ArgResults command) {
  final name = (_string(command, 'encoding') ?? '').toLowerCase();
  if (name.isEmpty || name == 'utf8') return utf8;
  final encoding = Encoding.getByName(name);
  if (encoding == null) _usage('Unknown encoding "$name".');
  return encoding;
}

ActivityFileFormat? _formatOption(ArgResults command, String name) {
  final value = _string(command, name);
  return value == null ? null : ActivityFileFormat.values.byName(value);
}

EncoderOptions _encoderOptions(ArgResults command) {
  final perChannel = <Channel, Duration>{};
  for (final raw in command['channel-max-delta'] as List<String>) {
    final separator = raw.indexOf('=');
    if (separator <= 0) {
      _usage('--channel-max-delta must be CHANNEL=DURATION, got "$raw".');
    }
    final channel = Channel.custom(raw.substring(0, separator).trim());
    perChannel[channel] = _durationValue(
      raw.substring(separator + 1),
      '--channel-max-delta ${channel.id}',
    );
  }
  for (final entry in _deprecatedChannelOptions.entries) {
    final raw = _string(command, entry.key);
    if (raw == null) continue;
    final duration = _durationValue(raw, '--${entry.key}');
    // --channel-max-delta wins when both name the same channel.
    perChannel.putIfAbsent(entry.value, () => duration);
  }
  return EncoderOptions(
    defaultMaxDelta: _durationOption(command, 'max-delta-seconds'),
    maxDeltaPerChannel: perChannel,
    precisionLatLon: _intOption(command, 'precision-latlon', max: 20),
    precisionEle: _intOption(command, 'precision-ele', max: 20),
    gpxVersion: _string(command, 'gpx-version') == '1.0'
        ? GpxVersion.v1_0
        : GpxVersion.v1_1,
    tcxVersion: _string(command, 'tcx-version') == '1'
        ? TcxVersion.v1
        : TcxVersion.v2,
    geojsonGeometry: _string(command, 'geojson-geometry') == 'points'
        ? GeojsonGeometry.points
        : GeojsonGeometry.lineString,
    geojsonIncludeChannels: command['geojson-channels'] == true,
  );
}

/// The auto-fix options, or null when [enabled] is false and none of the
/// tuning options was given.
ActivityAutoFixOptions? _autoFixOptions(
  ArgResults command, {
  required bool enabled,
}) {
  const tuning = [
    'fix-invalid-gps',
    'fix-channel-drift',
    'fix-distance-drift',
    'fix-timestamp-gaps',
    'gap-fill-threshold',
    'max-gap-points',
    'auto-lap',
    'auto-lap-always',
    'auto-lap-distance',
    'running-lap-distance',
    'cycling-lap-distance',
    'default-lap-distance',
  ];
  if (!enabled) {
    final stray = tuning.where(command.wasParsed).toList();
    if (stray.isNotEmpty) {
      _usage('--${stray.first} only takes effect together with --auto-fix.');
    }
    return null;
  }
  final globalLap = _string(command, 'auto-lap-distance');
  return ActivityAutoFixOptions(
    fixInvalidGps: command['fix-invalid-gps'] == true,
    fixChannelDrift: command['fix-channel-drift'] == true,
    fixDistanceDrift: command['fix-distance-drift'] == true,
    fixTimestampGaps: command['fix-timestamp-gaps'] == true,
    gapThreshold: _durationOption(
      command,
      'gap-fill-threshold',
      allowZero: false,
    ),
    maxInsertedGapPoints: _intOption(command, 'max-gap-points'),
    autoLapByDistance: command['auto-lap'] == true,
    autoLapOnlyWhenMissing: command['auto-lap-always'] != true,
    autoLapDistanceMeters: globalLap == null
        ? null
        : _metersValue(globalLap, '--auto-lap-distance'),
    runningLapDistanceMeters: _metersValue(
      _string(command, 'running-lap-distance')!,
      '--running-lap-distance',
    ),
    cyclingLapDistanceMeters: _metersValue(
      _string(command, 'cycling-lap-distance')!,
      '--cycling-lap-distance',
    ),
    defaultLapDistanceMeters: _metersValue(
      _string(command, 'default-lap-distance')!,
      '--default-lap-distance',
    ),
  );
}

/// The edit steps of [command], in the order they were typed.
List<_Step> _editSteps(ArgResults command, ArgParser parser) {
  final steps = <_Step>[];
  final arguments = command.arguments;
  for (var i = 0; i < arguments.length; i++) {
    final token = arguments[i];
    if (token == '--') break;
    if (!token.startsWith('--')) {
      // A short option such as -i or -o consumes the next token.
      if (token.length == 2 && token.startsWith('-')) {
        final option = parser.findByAbbreviation(token.substring(1));
        if (option != null && !option.isFlag) i++;
      }
      continue;
    }
    final equals = token.indexOf('=');
    final name = equals < 0 ? token.substring(2) : token.substring(2, equals);
    final inlineValue = equals < 0 ? null : token.substring(equals + 1);
    if (_flagSteps.contains(name)) {
      steps.add(_Step.parse(name, null));
    } else if (_valueSteps.containsKey(name)) {
      final value = inlineValue ?? arguments[++i];
      steps.add(_Step.parse(name, value));
    } else {
      final option = parser.options[name];
      if (option != null && !option.isFlag && inlineValue == null) i++;
    }
  }
  return steps;
}
