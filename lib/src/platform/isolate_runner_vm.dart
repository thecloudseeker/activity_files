// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:isolate';

/// Whether the current platform supports isolate spawning.
const bool isolatesSupported = true;

/// Runs [task] with optional isolate offloading.
Future<T> runWithIsolation<T>(
  FutureOr<T> Function() task, {
  required bool useIsolate,
}) {
  if (!useIsolate) {
    return Future.sync(task);
  }
  return Isolate.run(task);
}
