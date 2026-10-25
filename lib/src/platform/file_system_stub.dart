// SPDX-License-Identifier: BSD-3-Clause
import 'dart:typed_data';

/// Returns `true` when [value] represents a platform file handle.
///
/// Stub implementation for platforms without `dart:io`; always `false`.
bool isPlatformFile(Object? value) => false;

/// Returns the path for [file] when available.
///
/// Stub implementation always returns `null`.
String? platformFilePath(Object? file) => null;

/// The size of [file] in bytes, or `null` when unsupported.
///
/// Stub implementation for platforms without `dart:io`; always returns `null`.
Future<int?> platformFileLength(Object? file) async => null;

/// Attempts to read [file] bytes, returning `null` when unsupported.
///
/// Stub implementation for platforms without `dart:io`; always returns `null`.
Future<({Uint8List bytes, String path})?> readPlatformFile(
  Object? file,
) async => null;

/// Determines whether [path] refers to an existing platform file.
///
/// Stub implementation for platforms without `dart:io`; always `false`.
bool platformPathExists(String path) => false;

/// The size of the file at [path] in bytes.
///
/// Stub implementation for platforms without `dart:io`; throws
/// [UnsupportedError] to signal the lack of file system access.
Future<int> platformPathLength(String path) async =>
    throw UnsupportedError('File system not available on this platform.');

/// Reads bytes from a platform path when available.
///
/// Stub implementation for platforms without `dart:io`; throws
/// [UnsupportedError] to signal the lack of file system access.
Future<Uint8List> readPlatformPath(String path) async =>
    throw UnsupportedError('File system not available on this platform.');
