// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';

/// Whether the current platform supports isolate spawning.
const bool isolatesSupported = false;

/// Fallback implementation that executes [task] on the current isolate.
Future<T> runWithIsolation<T>(
  FutureOr<T> Function() task, {
  required bool useIsolate,
}) async {
  // Ignore [useIsolate]; no isolate support is available.
  return Future.sync(task);
}
