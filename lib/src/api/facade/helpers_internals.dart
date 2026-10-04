// SPDX-License-Identifier: BSD-3-Clause
part of '../activity_files_facade.dart';

final List<SportMapper> _sportMappers = <SportMapper>[];

Sport? _resolveSport(dynamic source) {
  final custom = _applySportMappers(source);
  if (custom != null) {
    return custom;
  }
  final primitive = _inferSportPrimitive(source);
  if (primitive != null) {
    return primitive;
  }
  if (source is Map) {
    for (final value in source.values) {
      final nested = _resolveSport(value);
      if (nested != null) {
        return nested;
      }
    }
  } else if (source is Iterable) {
    for (final value in source) {
      final nested = _resolveSport(value);
      if (nested != null) {
        return nested;
      }
    }
  }
  return null;
}

Sport? _applySportMappers(dynamic source) {
  for (var i = _sportMappers.length - 1; i >= 0; i--) {
    final result = _sportMappers[i](source);
    if (result != null) {
      return result;
    }
  }
  return null;
}

Sport? _inferSportPrimitive(dynamic source) => switch (source) {
  null => null,
  final Sport sport => sport,
  final String text => _inferSportFromString(text),
  final num value
      when value.toInt() >= 0 && value.toInt() < _sportByNumericId.length =>
    _sportByNumericId[value.toInt()],
  _ => null,
};

final RegExp _sportDelimiter = RegExp(r'[^a-z0-9]+');

/// Keyword matching order matters: earlier entries win on mixed labels.
const Map<Sport, List<String>> _sportKeywords = {
  Sport.running: ['run', 'running', 'jog', 'jogging'],
  Sport.cycling: ['cycle', 'cycling', 'bike', 'biking', 'ride'],
  Sport.swimming: ['swim', 'swimming'],
  Sport.walking: ['walk', 'walking'],
  Sport.hiking: ['hike', 'hiking'],
  Sport.other: ['other'],
};

const List<Sport> _sportByNumericId = [
  Sport.other,
  Sport.running,
  Sport.cycling,
  Sport.swimming,
  Sport.walking,
  Sport.hiking,
];

Sport? _inferSportFromString(String text) {
  final tokens = text
      .trim()
      .toLowerCase()
      .split(_sportDelimiter)
      .where((token) => token.isNotEmpty)
      .toSet();
  for (final entry in _sportKeywords.entries) {
    if (entry.value.any(tokens.contains)) {
      return entry.key;
    }
  }
  return null;
}
