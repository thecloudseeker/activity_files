// SPDX-License-Identifier: BSD-3-Clause
import 'dart:io';
import 'dart:typed_data';

/// Returns `true` when [value] is a `File` instance.
bool isPlatformFile(Object? value) => value is File;

/// Returns the file path when [file] is a `File`.
String? platformFilePath(Object? file) => file is File ? file.path : null;

/// Reads [file] bytes when [file] is a `File`.
///
/// Returns `null` for non-`File` inputs to simplify conditional call sites.
Future<({Uint8List bytes, String path})?> readPlatformFile(Object? file) async {
  if (file is! File) {
    return null;
  }
  final bytes = await file.readAsBytes();
  return (bytes: Uint8List.fromList(bytes), path: file.path);
}

/// Determines whether [path] refers to an existing file.
bool platformPathExists(String path) => File(path).existsSync();

/// Reads bytes from [path].
Future<Uint8List> readPlatformPath(String path) async =>
    Uint8List.fromList(await File(path).readAsBytes());
