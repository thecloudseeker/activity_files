// SPDX-License-Identifier: BSD-3-Clause
part of 'cli.dart';

const _activityExtensions = {'gpx', 'tcx', 'fit', 'csv', 'geojson', 'json'};

const _extensionFor = {
  ActivityFileFormat.gpx: 'gpx',
  ActivityFileFormat.tcx: 'tcx',
  ActivityFileFormat.fit: 'fit',
  ActivityFileFormat.csv: 'csv',
  ActivityFileFormat.geojson: 'geojson',
};

/// One input: a file, or stdin when [path] is null.
class _Input {
  _Input.file(String this.path, {this.relative})
    : display = path,
      unreadable = null;
  _Input.stdin()
    : path = null,
      relative = null,
      display = 'stdin',
      unreadable = null;

  /// A folder that could not be listed; it fails like a file that cannot be
  /// read, and the run goes on.
  _Input.unreadableFolder(String this.path, String this.unreadable)
    : relative = null,
      display = path;

  final String? path;

  /// The path below the folder it was found in, for mirrored output names.
  final String? relative;
  final String display;

  /// Why this input cannot be read, known before reading it.
  final String? unreadable;

  bool get isStdin => path == null;

  /// The name without folder and extension.
  String get stem {
    if (isStdin) return 'stdin';
    final name = path!.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}

/// The inputs of [command], with folders expanded. Exits 64 for no input and
/// 66 for a path that does not exist.
List<_Input> _inputs(ArgResults command) {
  final raw = command['input'] as List<String>;
  if (raw.isEmpty) _usage('--input is required (a file, a folder, or -).');
  if (raw.contains('-') && raw.length > 1) {
    _usage('- (stdin) cannot be combined with other inputs.');
  }
  final recursive = command['recursive'] == true;
  final inputs = <_Input>[];
  for (final path in raw) {
    if (path == '-') {
      inputs.add(_Input.stdin());
      continue;
    }
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      throw _CliException('Input not found: $path', _exitNoInput);
    }
    if (type != FileSystemEntityType.directory) {
      inputs.add(_Input.file(path));
      continue;
    }
    final root = Directory(path);
    final found = <_Input>[];
    final visited = <String>{};
    void scan(Directory folder) {
      // A linked folder is listed once, so a link loop ends.
      if (!visited.add(_resolved(folder.path))) return;
      final List<FileSystemEntity> entities;
      try {
        entities = folder.listSync();
      } on FileSystemException catch (e) {
        found.add(
          _Input.unreadableFolder(
            folder.path,
            'Could not read the folder: ${e.osError?.message ?? e.message}',
          ),
        );
        return;
      }
      for (final entity in entities) {
        final name = entity.path.split(RegExp(r'[\\/]')).last;
        if (name.startsWith('.')) continue;
        if (entity is Directory) {
          if (recursive) scan(entity);
          continue;
        }
        if (entity is! File) continue;
        final dot = name.lastIndexOf('.');
        final extension = dot < 0 ? '' : name.substring(dot + 1);
        if (!_activityExtensions.contains(extension.toLowerCase())) continue;
        final relative = entity.path
            .substring(root.path.length)
            .replaceFirst(RegExp(r'^[\\/]+'), '');
        found.add(_Input.file(entity.path, relative: relative));
      }
    }

    scan(root);
    found.sort((a, b) => a.path!.compareTo(b.path!));
    if (found.isEmpty) {
      throw _CliException('No activity files found in $path', _exitNoInput);
    }
    inputs.addAll(found);
  }
  return inputs;
}

/// Whether [inputs] is more than one file, or a folder.
bool _isBatch(List<_Input> inputs) =>
    inputs.length > 1 || inputs.any((input) => input.relative != null);

/// An input as the library's source: a [File] keeps the extension for
/// format detection, stdin is a stream the library stops reading once it
/// passes `--max-payload-bytes`.
Object _source(_Input input) {
  if (input.unreadable case final reason?) {
    throw _FileFailure(reason, _exitNoInput);
  }
  return input.isStdin ? stdin : File(input.path!);
}

/// [path] with links, `.` and `..` resolved, or made absolute when it cannot
/// be resolved.
String _resolved(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return File(path).absolute.path;
  }
}

/// Where each input's output goes, or `-` for stdout. Checked completely
/// before anything is read or written.
Map<_Input, String> _plannedOutputs(
  ArgResults command,
  List<_Input> inputs,
  ActivityFileFormat? Function(_Input input) formatFor,
) {
  final output = _string(command, 'output');
  // A trailing separator would double up in the planned paths.
  final outDir = _string(
    command,
    'out-dir',
  )?.replaceFirst(RegExp(r'(?<=.)[\\/]+$'), '');
  if (output != null && outDir != null) {
    _usage('Use either -o or --out-dir, not both.');
  }
  if (_isBatch(inputs)) {
    if (output != null) {
      _usage('-o takes a single input file; use --out-dir for several.');
    }
    if (outDir == null) _usage('Several inputs or a folder need --out-dir.');
  } else if (output == null && outDir == null) {
    _usage('Name the output with -o FILE, -o - for stdout, or --out-dir.');
  }
  if (output != null) return {inputs.single: output};

  if (inputs.any((input) => input.isStdin)) {
    _usage('stdin input needs -o.');
  }
  // Paths are compared without case: on macOS and Windows Run.fit and
  // run.fit are one file.
  final planned = <_Input, String>{};
  final owners = <String, _Input>{};
  final inputPaths = {
    for (final input in inputs)
      if (input.unreadable == null) _resolved(input.path!).toLowerCase(),
  };
  for (final input in inputs) {
    if (input.unreadable != null) continue;
    final format = formatFor(input);
    final relative = input.relative ?? input.path!.split(RegExp(r'[\\/]')).last;
    final dot = relative.lastIndexOf('.');
    final base = dot <= 0 ? relative : relative.substring(0, dot);
    // Without a target format the output keeps the input's own extension.
    final path = format == null
        ? '$outDir/$relative'
        : '$outDir/$base.${_extensionFor[format]}';
    final clash = owners[path.toLowerCase()];
    if (clash != null) {
      _usage(
        'Both ${clash.display} and ${input.display} would be written to '
        '$path; nothing was written.',
      );
    }
    if (File(path).existsSync() &&
        inputPaths.contains(_resolved(path).toLowerCase())) {
      _usage('$path would overwrite an input file; nothing was written.');
    }
    owners[path.toLowerCase()] = input;
    planned[input] = path;
  }
  return planned;
}

/// Writes [result] to [target] (`-` for stdout); [createFolders] makes the
/// folders of an `--out-dir` target. Exits 70 when writing fails.
Future<void> _write(
  ActivityExportResult result,
  String target, {
  required bool createFolders,
}) async {
  final bytes = result.isBinary
      ? result.asBytes()
      : Uint8List.fromList(utf8.encode(result.encoded));
  if (target == '-') {
    if (result.isBinary && stdout.hasTerminal) {
      throw _CliException(
        'Refusing to write a binary FIT file to a terminal; redirect stdout '
        'or name an output file.',
      );
    }
    stdout.add(bytes);
    await stdout.flush();
    return;
  }
  try {
    final file = File(target);
    if (createFolders) file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  } on FileSystemException catch (e) {
    throw _CliException(
      'Could not write $target: ${e.osError?.message ?? e.message}',
      _exitSoftware,
    );
  }
}
