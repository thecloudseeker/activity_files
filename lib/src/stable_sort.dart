// SPDX-License-Identifier: BSD-3-Clause

/// Sorts [list] in place by [compare], keeping elements that compare equal in
/// their original order.
///
/// `List.sort` makes no such promise, and points or samples sharing a
/// timestamp must not swap places: their order is data.
void stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  final length = list.length;
  if (length < 2) return;
  if (length <= _insertionSortLimit) {
    _insertionSort(list, compare, 0, length);
    return;
  }
  // Bottom-up merge sort: sorted runs of the insertion-sort size are merged
  // pairwise into a scratch list and back until one run remains.
  for (var start = 0; start < length; start += _insertionSortLimit) {
    final end = start + _insertionSortLimit;
    _insertionSort(list, compare, start, end < length ? end : length);
  }
  var source = list;
  var target = List<T>.of(list, growable: false);
  for (var width = _insertionSortLimit; width < length; width *= 2) {
    for (var left = 0; left < length; left += 2 * width) {
      final middle = left + width < length ? left + width : length;
      final right = left + 2 * width < length ? left + 2 * width : length;
      _merge(source, target, compare, left, middle, right);
    }
    final swap = source;
    source = target;
    target = swap;
  }
  if (!identical(source, list)) {
    list.setRange(0, length, source);
  }
}

const _insertionSortLimit = 32;

void _insertionSort<T>(
  List<T> list,
  int Function(T a, T b) compare,
  int start,
  int end,
) {
  for (var i = start + 1; i < end; i++) {
    final element = list[i];
    var j = i;
    // Strictly greater, so an equal element stays behind the earlier one.
    while (j > start && compare(list[j - 1], element) > 0) {
      list[j] = list[j - 1];
      j--;
    }
    list[j] = element;
  }
}

void _merge<T>(
  List<T> source,
  List<T> target,
  int Function(T a, T b) compare,
  int left,
  int middle,
  int right,
) {
  var i = left;
  var j = middle;
  var k = left;
  while (i < middle && j < right) {
    // Taking from the left run on ties keeps equal elements in order.
    if (compare(source[j], source[i]) < 0) {
      target[k++] = source[j++];
    } else {
      target[k++] = source[i++];
    }
  }
  while (i < middle) {
    target[k++] = source[i++];
  }
  while (j < right) {
    target[k++] = source[j++];
  }
}
