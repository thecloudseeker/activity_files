// SPDX-License-Identifier: BSD-3-Clause
/// The command line and the library are on par: every public, non-deprecated
/// part of the library is either reachable through a command-line option or
/// excluded for a stated reason, and every command-line option maps back to
/// the library. The public surface is read by reflection, so a new library
/// member fails this test until it has a command-line form.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:mirrors';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// How every exported declaration is covered. `members` means each of its
/// public members is listed in [_members].
const _exports = <String, String>{
  // Checked member by member.
  'ActivityFiles': 'members',
  'RawEditor': 'members',
  'RawTransforms': 'members',
  'EncoderOptions': 'members',
  'ActivityAutoFixOptions': 'members',
  'validateRawActivity': 'validate',
  'validateLapBoundariesList': 'validate',
  // No command yet: `validate` reports what ActivityFiles.validate reports,
  // and whether that includes these checks is open.
  'validateDeviceMetadata': '$_noCommandYet: device metadata checks',
  'validateChannels': '$_noCommandYet: channel checks',
  // Lower-level ways to read and write; every command reads and writes
  // through the same parsers and encoders.
  'ActivityParser': 'inspect --input',
  'FitParser': 'inspect --input',
  'ActivityEncoder': 'convert --to',
  'DiagnosticsFormatter': 'validate',
  // Excluded (decision 44): building activities in code, channel lookups.
  'RawActivityBuilder': 'excluded: builds activities in code',
  'ChannelMapper': 'excluded: channel lookups for code (channelSnapshot)',
  'ChannelCursor': 'excluded: channel lookups for code (channelSnapshot)',
  'ChannelSnapshot': 'excluded: channel lookups for code (channelSnapshot)',
  'ChannelReading': 'excluded: channel lookups for code (channelSnapshot)',
  // Data: values the commands read, write and report, with nothing to call.
  'ActivityConversionResult': 'data',
  'ActivityExportResult': 'data',
  'ActivityImportResult': 'data',
  'ActivityParseResult': 'data',
  'BatchImportFailure': 'data',
  'BatchImportResult': 'data',
  'RawActivity': 'data',
  'GeoPoint': 'data',
  'Lap': 'data',
  'Sample': 'data',
  'Channel': 'data',
  'ActivityDeviceMetadata': 'data',
  'ActivityEvent': 'data',
  'ActivitySummary': 'data',
  'SwimLength': 'data',
  'WorkoutSet': 'data',
  'GpxExtensionNode': 'data',
  'GpxRoute': 'data',
  'ParseDiagnostic': 'data',
  'ParseNodeReference': 'data',
  'DiagnosticCategory': 'data',
  'ValidationDiagnostic': 'data',
  'ValidationResult': 'data',
  'LapValidationResult': 'data',
  'FitTypedActivityView': 'data: a typed view of the model',
  'FitSessionView': 'data: a typed view of the model',
  'FitLapView': 'data: a typed view of the model',
  'FitRecordView': 'data: a typed view of the model',
  'FitTypedViewExtension.asFitView': 'data: a typed view of the model',
  'fitManufacturerNames': 'data: the FIT manufacturer table',
  'ActivityFileFormat': 'convert --from',
  'GeojsonGeometry': 'convert --geojson-geometry',
  'GpxVersion': 'convert --gpx-version',
  'TcxVersion': 'convert --tcx-version',
  'ParseSeverity': 'data',
  'ValidationSeverity': 'data',
  'Sport': 'data',
  'SwimStroke': 'data',
};

/// A library part that needs a command-line form and has none yet, pending a
/// maintainer decision.
const _noCommandYet = 'no command yet';

const _isolates = 'excluded: isolate setting';
const _building = 'excluded: builds activities in code';
const _sportMapping = 'excluded: sport-mapper callbacks (decision 27)';
const _callerDiagnostics =
    'excluded: a caller passing its own diagnostics through';
const _filePaths = 'excluded: the command line always reads paths as files';
const _optionsHelper = 'excluded: a helper on the options object';

/// Every public member of the `members` classes, as `Class.member` or
/// `Class.member.parameter`, with the command-line option that reaches it.
const _members = <String, String>{
  // ActivityFiles
  'ActivityFiles.import': 'inspect --input',
  'ActivityFiles.import.format': 'inspect --from',
  'ActivityFiles.import.useIsolate': _isolates,
  'ActivityFiles.import.encoding': 'inspect --encoding',
  'ActivityFiles.import.allowFilePaths': _filePaths,
  'ActivityFiles.import.strictFitIntegrity': 'inspect --strict-fit',
  'ActivityFiles.import.maxPayloadBytes': 'inspect --max-payload-bytes',
  'ActivityFiles.importBatch': 'inspect --input',
  'ActivityFiles.importBatch.format': 'inspect --from',
  'ActivityFiles.importBatch.useIsolate': _isolates,
  'ActivityFiles.importBatch.onProgress': 'convert --input',
  'ActivityFiles.importBatch.stopOnError': 'inspect --stop-on-error',
  'ActivityFiles.importBatch.maxPayloadBytes': 'inspect --max-payload-bytes',
  'ActivityFiles.detectFormat': 'inspect --input',
  'ActivityFiles.detectFormat.encoding': 'inspect --encoding',
  'ActivityFiles.detectFormat.allowFilePaths': _filePaths,
  'ActivityFiles.detectFormat.maxPayloadBytes': 'inspect --max-payload-bytes',
  'ActivityFiles.convert': 'convert --input',
  'ActivityFiles.convert.source': 'convert --input',
  'ActivityFiles.convert.to': 'convert --to',
  'ActivityFiles.convert.from': 'convert --from',
  'ActivityFiles.convert.options': 'convert --precision-latlon',
  'ActivityFiles.convert.normalize': 'convert --normalize',
  'ActivityFiles.convert.useIsolate': _isolates,
  'ActivityFiles.convert.encoding': 'convert --encoding',
  'ActivityFiles.convert.allowFilePaths': _filePaths,
  'ActivityFiles.convert.exportInIsolate': _isolates,
  'ActivityFiles.convert.runValidation': 'convert --validate',
  'ActivityFiles.convert.strictFitIntegrity': 'convert --strict-fit',
  'ActivityFiles.convert.autoFix': 'convert --auto-fix',
  'ActivityFiles.convert.maxPayloadBytes': 'convert --max-payload-bytes',
  'ActivityFiles.convert.diagnostics': _callerDiagnostics,
  'ActivityFiles.export': 'edit --to',
  'ActivityFiles.export.activity': 'edit --input',
  'ActivityFiles.export.to': 'edit --to',
  'ActivityFiles.export.options': 'edit --precision-latlon',
  'ActivityFiles.export.normalize': 'edit --normalize',
  'ActivityFiles.export.diagnostics': _callerDiagnostics,
  'ActivityFiles.export.runValidation': 'edit --validate',
  'ActivityFiles.export.validation': _callerDiagnostics,
  'ActivityFiles.exportAsync': 'edit --to',
  'ActivityFiles.exportAsync.activity': 'edit --input',
  'ActivityFiles.exportAsync.to': 'edit --to',
  'ActivityFiles.exportAsync.options': 'edit --precision-latlon',
  'ActivityFiles.exportAsync.normalize': 'edit --normalize',
  'ActivityFiles.exportAsync.diagnostics': _callerDiagnostics,
  'ActivityFiles.exportAsync.runValidation': 'edit --validate',
  'ActivityFiles.exportAsync.validation': _callerDiagnostics,
  'ActivityFiles.exportAsync.useIsolate': _isolates,
  'ActivityFiles.edit': 'edit --input',
  'ActivityFiles.validate': 'validate --input',
  'ActivityFiles.validate.gapWarningThreshold': 'validate --gap-threshold',
  'ActivityFiles.defaultMaxPayloadBytes': 'convert --max-payload-bytes',
  'ActivityFiles.builder': _building,
  'ActivityFiles.gpxDefaultExtensionNamespace': _building,
  'ActivityFiles.gpxDefaultExtensionPrefix': _building,
  'ActivityFiles.builderFromStreams': _building,
  'ActivityFiles.buildAndExport': _building,
  'ActivityFiles.channelSamplesFrom': _building,
  'ActivityFiles.channelSnapshot':
      'excluded: channel lookups for code (channelSnapshot)',
  'ActivityFiles.inferSport': _sportMapping,
  'ActivityFiles.registerSportMapper': _sportMapping,
  'ActivityFiles.unregisterSportMapper': _sportMapping,
  'ActivityFiles.clearSportMappers': _sportMapping,
  // RawEditor
  'RawEditor.RawEditor': 'edit --input',
  'RawEditor.activity': 'edit --input',
  'RawEditor.repairDiagnostics': 'edit --json',
  'RawEditor.sortAndDedup': 'edit --sort-and-dedup',
  'RawEditor.ensureStrictTimeOrder': 'edit --strict-time-order',
  'RawEditor.trimInvalid': 'edit --trim-invalid',
  'RawEditor.crop': 'edit --crop',
  'RawEditor.shiftTime': 'edit --shift-time',
  'RawEditor.insertPoint': 'edit --insert-point',
  'RawEditor.deletePointAt': 'edit --delete-point',
  'RawEditor.updatePoint': 'edit --update-point',
  'RawEditor.updatePoint.latitude': 'edit --update-point',
  'RawEditor.updatePoint.longitude': 'edit --update-point',
  'RawEditor.updatePoint.elevation': 'edit --update-point',
  'RawEditor.updatePoint.time': 'edit --update-point',
  'RawEditor.deleteRange': 'edit --delete-range',
  'RawEditor.insertPause': 'edit --insert-pause',
  'RawEditor.removePause': 'edit --remove-pause',
  'RawEditor.downsampleTime': 'edit --downsample-time',
  'RawEditor.downsampleDistance': 'edit --downsample-distance',
  'RawEditor.smoothHR': 'edit --smooth-hr',
  'RawEditor.recomputeDistanceAndSpeed': 'edit --recompute-distance-and-speed',
  'RawEditor.markLapsByDistance': 'edit --mark-laps-by-distance',
  'RawEditor.autoFix': 'edit --auto-fix',
  'RawEditor.validateLapBoundaries': 'validate --input',
  'RawEditor.merge': 'merge --input',
  'RawEditor.merge.preserveSportPerLap': 'merge --preserve-sport-per-lap',
  'RawEditor.merge.normalize': 'merge --normalize',
  'RawEditor.merge.creator': 'merge --creator',
  'RawEditor.splitBySport': 'split --input',
  'RawEditor.splitBySport.normalize': 'split --normalize',
  // RawTransforms
  'RawTransforms.resample': 'edit --resample',
  'RawTransforms.resample.step': 'edit --resample',
  // EncoderOptions
  'EncoderOptions.EncoderOptions': 'convert --precision-latlon',
  'EncoderOptions.defaultMaxDelta': 'convert --max-delta-seconds',
  'EncoderOptions.maxDeltaPerChannel': 'convert --channel-max-delta',
  'EncoderOptions.precisionLatLon': 'convert --precision-latlon',
  'EncoderOptions.precisionEle': 'convert --precision-ele',
  'EncoderOptions.gpxVersion': 'convert --gpx-version',
  'EncoderOptions.tcxVersion': 'convert --tcx-version',
  'EncoderOptions.geojsonGeometry': 'convert --geojson-geometry',
  'EncoderOptions.geojsonIncludeChannels': 'convert --geojson-channels',
  'EncoderOptions.copyWith': _optionsHelper,
  'EncoderOptions.maxDeltaFor': _optionsHelper,
  // ActivityAutoFixOptions
  'ActivityAutoFixOptions.ActivityAutoFixOptions': 'convert --auto-fix',
  'ActivityAutoFixOptions.disabled': 'convert --auto-fix',
  'ActivityAutoFixOptions.isEnabled': 'convert --auto-fix',
  'ActivityAutoFixOptions.fixInvalidGps': 'convert --fix-invalid-gps',
  'ActivityAutoFixOptions.fixChannelDrift': 'convert --fix-channel-drift',
  'ActivityAutoFixOptions.fixDistanceDrift': 'convert --fix-distance-drift',
  'ActivityAutoFixOptions.fixTimestampGaps': 'convert --fix-timestamp-gaps',
  'ActivityAutoFixOptions.gapThreshold': 'convert --gap-fill-threshold',
  'ActivityAutoFixOptions.maxInsertedGapPoints': 'convert --max-gap-points',
  'ActivityAutoFixOptions.autoLapByDistance': 'convert --auto-lap',
  'ActivityAutoFixOptions.autoLapOnlyWhenMissing': 'convert --auto-lap-always',
  'ActivityAutoFixOptions.autoLapDistanceMeters': 'convert --auto-lap-distance',
  'ActivityAutoFixOptions.runningLapDistanceMeters':
      'convert --running-lap-distance',
  'ActivityAutoFixOptions.cyclingLapDistanceMeters':
      'convert --cycling-lap-distance',
  'ActivityAutoFixOptions.defaultLapDistanceMeters':
      'convert --default-lap-distance',
};

/// Options that handle input and output on the command line rather than
/// reach a library member.
const _inputOutputOptions = {
  'help',
  'input',
  'output',
  'out-dir',
  'recursive',
  'json',
};

/// Named parameters of options classes repeat their fields.
const _optionsClasses = {'EncoderOptions', 'ActivityAutoFixOptions'};

String _name(Symbol symbol) => MirrorSystem.getName(symbol);

bool _deprecated(DeclarationMirror d) =>
    d.metadata.any((m) => m.reflectee is Deprecated);

/// Every public, non-deprecated declaration the package exports.
Set<String> _exported() {
  final library = currentMirrorSystem()
      .libraries[Uri.parse('package:activity_files/activity_files.dart')]!;
  final names = <String>{};
  for (final dependency in library.libraryDependencies.where(
    (d) => d.isExport,
  )) {
    final shown = {
      for (final c in dependency.combinators.where((c) => c.isShow))
        ...c.identifiers.map(_name),
    };
    final hidden = {
      for (final c in dependency.combinators.where((c) => c.isHide))
        ...c.identifiers.map(_name),
    };
    for (final d in dependency.targetLibrary!.declarations.values) {
      final name = _name(d.simpleName);
      if (d.isPrivate || _deprecated(d) || hidden.contains(name)) continue;
      if (shown.isNotEmpty && !shown.contains(name)) continue;
      names.add(name);
    }
  }
  return names;
}

/// Every public, non-deprecated member of [type], with named parameters.
Set<String> _membersOf(Type type) {
  final mirror = reflectClass(type);
  final className = _name(mirror.simpleName);
  final keys = <String>{};
  for (final d in mirror.declarations.values) {
    if (d.isPrivate || _deprecated(d)) continue;
    if (d is MethodMirror && d.isOperator) continue;
    if (d is MethodMirror && (d.isSetter || d.isSynthetic)) continue;
    var member = _name(d.simpleName);
    if (d is MethodMirror && d.isConstructor) {
      final constructor = _name(d.constructorName);
      member = constructor.isEmpty ? className : constructor;
    }
    final key = '$className.$member';
    if (d is MethodMirror && d.isGetter && keys.contains(key)) continue;
    keys.add(key);
    if (d is MethodMirror && !_optionsClasses.contains(className)) {
      for (final p in d.parameters) {
        if (p.isNamed && !_deprecated(p)) {
          keys.add('$key.${_name(p.simpleName)}');
        }
      }
    }
  }
  return keys;
}

void main() {
  late Map<String, Set<String>> help;

  setUpAll(() async {
    help = {};
    for (final command in [
      'convert',
      'edit',
      'merge',
      'split',
      'validate',
      'inspect',
    ]) {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/activity_files.dart',
        command,
        '--help',
      ]);
      help[command] = {
        for (final m in RegExp(
          r'--(?:\[no-\])?([a-z0-9][a-z0-9-]*)',
        ).allMatches(result.stdout as String))
          m[1]!,
      };
    }
  });

  /// Checks a `command --option` form against the real `--help` output.
  void expectForm(String form, String owner) {
    final parts = form.split(' ');
    expect(help.keys, contains(parts.first), reason: '$owner: $form');
    if (parts.length > 1) {
      expect(
        help[parts.first],
        contains(parts[1].substring(2)),
        reason: '$owner maps to $form, which `${parts.first} --help` lacks',
      );
    }
  }

  test('every exported declaration is covered, and only those', () {
    final exported = _exported();
    expect(
      exported.difference(_exports.keys.toSet()),
      isEmpty,
      reason: 'New exports need a command-line form or an exclusion',
    );
    expect(
      _exports.keys.toSet().difference(exported),
      isEmpty,
      reason: 'Listed declarations that are no longer exported',
    );
    for (final entry in _exports.entries) {
      final kind = entry.value;
      if (kind == 'members' ||
          kind.startsWith('data') ||
          kind.startsWith('excluded') ||
          kind.startsWith(_noCommandYet)) {
        continue;
      }
      expectForm(kind, entry.key);
    }
  });

  test('every library member has a command-line form or an exclusion', () {
    final members = {
      for (final type in [
        ActivityFiles,
        RawEditor,
        RawTransforms,
        EncoderOptions,
        ActivityAutoFixOptions,
      ])
        ..._membersOf(type),
    };
    // Parameters of an excluded member need no entry of their own.
    bool underExcluded(String key) {
      final parts = key.split('.');
      if (parts.length < 3) return false;
      final owner = _members['${parts[0]}.${parts[1]}'];
      return owner != null && owner.startsWith('excluded');
    }

    final missing = members
        .where((m) => !_members.containsKey(m) && !underExcluded(m))
        .toList();
    expect(missing, isEmpty, reason: 'Members without a command-line form');
    final stale = _members.keys.where((k) => !members.contains(k)).toList();
    expect(stale, isEmpty, reason: 'Entries for members that no longer exist');
    for (final entry in _members.entries) {
      if (entry.value.startsWith('excluded')) continue;
      expectForm(entry.value, entry.key);
    }
  });

  test('every command-line option maps back to the library', () {
    final reached = <String, Set<String>>{};
    for (final form in [..._exports.values, ..._members.values].where(
      (f) =>
          !f.startsWith('excluded') &&
          !f.startsWith('data') &&
          !f.startsWith(_noCommandYet),
    )) {
      final parts = form.split(' ');
      if (parts.length > 1 && parts.first != 'members') {
        reached.putIfAbsent(parts[1].substring(2), () => {});
      }
    }
    for (final command in help.keys) {
      for (final option in help[command]!) {
        if (_inputOutputOptions.contains(option)) continue;
        expect(
          reached.containsKey(option),
          isTrue,
          reason: '$command --$option reaches no library member',
        );
      }
    }
  });
}
