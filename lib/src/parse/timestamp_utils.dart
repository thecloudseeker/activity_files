// SPDX-License-Identifier: BSD-3-Clause

final RegExp _timezoneOffsetPattern = RegExp(r'[Zz]$|[+-]\d{2}:?\d{2}$');

DateTime parseTimestampAssumeUtc(String text) {
  final trimmed = text.trim();
  return _timezoneOffsetPattern.hasMatch(trimmed)
      ? DateTime.parse(trimmed).toUtc()
      : DateTime.parse('${trimmed}Z').toUtc();
}
