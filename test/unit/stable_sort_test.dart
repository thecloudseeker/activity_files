// SPDX-License-Identifier: BSD-3-Clause
library;

import 'dart:math';

import 'package:activity_files/src/stable_sort.dart';
import 'package:test/test.dart';

void main() {
  test('sorts like List.sort and keeps equal keys in order', () {
    final random = Random(7);
    for (final length in [0, 1, 2, 31, 32, 33, 64, 65, 1000, 4097]) {
      // Few distinct keys, so most elements tie with others.
      final items = [
        for (var i = 0; i < length; i++) (key: random.nextInt(8), order: i),
      ];
      final sorted = [...items];
      stableSort(sorted, (a, b) => a.key.compareTo(b.key));

      expect(
        sorted.map((e) => e.key),
        [...items.map((e) => e.key)]..sort(),
        reason: 'length $length',
      );
      for (var i = 1; i < sorted.length; i++) {
        if (sorted[i].key == sorted[i - 1].key) {
          expect(
            sorted[i].order,
            greaterThan(sorted[i - 1].order),
            reason: 'length $length, index $i',
          );
        }
      }
    }
  });

  test('an already sorted list stays the same list', () {
    final list = [for (var i = 0; i < 100; i++) i];
    stableSort(list, (a, b) => a.compareTo(b));
    expect(list, [for (var i = 0; i < 100; i++) i]);
  });
}
