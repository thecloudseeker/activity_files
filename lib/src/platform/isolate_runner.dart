// SPDX-License-Identifier: BSD-3-Clause
// Isolates use Dart's built-in concurrency primitives - no additional audit needed.
export 'isolate_runner_stub.dart'
    if (dart.library.isolate) 'isolate_runner_vm.dart';
