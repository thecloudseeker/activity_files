// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for isolate platform adapters.
library;

import 'package:activity_files/src/platform/isolate_runner.dart'
    as isolate_runner;
import 'package:activity_files/src/platform/isolate_runner_stub.dart'
    as isolate_stub;
import 'package:activity_files/src/platform/isolate_runner_vm.dart'
    as isolate_vm;
import 'package:test/test.dart';

void main() {
  group('Isolate adapters', () {
    test(
      'isolate runner stub executes inline when isolates unsupported',
      () async {
        var invoked = false;
        final result = await isolate_stub.runWithIsolation(() {
          invoked = true;
          return 7;
        }, useIsolate: true);
        expect(isolate_stub.isolatesSupported, isFalse);
        expect(result, equals(7));
        expect(invoked, isTrue);
      },
    );

    test('isolate runner VM offloads when isolates supported', () async {
      expect(isolate_vm.isolatesSupported, isTrue);
      final inline = await isolate_vm.runWithIsolation(
        () => 11,
        useIsolate: false,
      );
      expect(inline, equals(11));
      final offloaded = await isolate_vm.runWithIsolation(
        _isolatedComputation,
        useIsolate: true,
      );
      expect(offloaded, equals(73));
      final shared = await isolate_runner.runWithIsolation(
        _isolatedComputation,
        useIsolate: true,
      );
      expect(shared, equals(73));
    });
  });
}

int _isolatedComputation() => 73;
