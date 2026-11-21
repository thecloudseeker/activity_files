// SPDX-License-Identifier: BSD-3-Clause

/// Parses [text] as a finite double, or returns null.
///
/// `double.tryParse` accepts `NaN`, `Infinity` and values that overflow to
/// infinity such as `1e999`. The model holds only finite numbers, so those
/// count as unreadable here and take the same warning path as any other
/// malformed number.
double? parseFiniteDouble(String? text) {
  if (text == null) return null;
  final value = double.tryParse(text);
  return value != null && value.isFinite ? value : null;
}

/// Whether [text] reads as a number that is not finite (`NaN`, `Infinity`,
/// `1e999`). Lets a parser that skips non-numeric text on purpose, such as a
/// free-text CSV column, still report a number it cannot keep.
bool isNonFiniteNumber(String text) {
  final value = double.tryParse(text);
  return value != null && !value.isFinite;
}
