// SPDX-License-Identifier: BSD-3-Clause
/// A call with arguments that cannot mean anything stops at an assertion
/// during development; in a release build, where assertions are off, it
/// changes nothing and reports `call.invalid_argument` (or, for `merge` of
/// nothing, gives an empty activity). The release half runs
/// `release/impossible_calls.dart` without assertions.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  test('with assertions on, an impossible crop stops', () {
    final t0 = DateTime.utc(2024, 1, 1, 10);
    expect(
      () => ActivityFiles.edit(
        RawActivity(),
      ).crop(t0, t0.subtract(const Duration(hours: 1))),
      throwsA(isA<AssertionError>()),
    );
  });

  test('without assertions, nothing throws and nothing changes', () {
    final run = Process.runSync(Platform.resolvedExecutable, [
      'run',
      'test/never_throw/release/impossible_calls.dart',
    ]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    final results =
        jsonDecode((run.stdout as String).trim().split('\n').last)
            as Map<String, Object?>;
    for (final MapEntry(key: call, value: result) in results.entries) {
      expect(result, isA<Map<String, Object?>>(), reason: '$call: $result');
      final map = result! as Map<String, Object?>;
      if (call == 'merge') {
        expect(map['points'], 0);
      } else if (call == 'resample') {
        expect(map['points'], 3);
      } else if (call == 'convertAndExport') {
        expect(map['codes'], contains('call.invalid_argument'));
      } else {
        expect(map['points'], 3, reason: call);
        expect(map['codes'], ['call.invalid_argument'], reason: call);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
