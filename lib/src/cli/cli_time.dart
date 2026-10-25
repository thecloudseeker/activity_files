// SPDX-License-Identifier: BSD-3-Clause
part of 'cli.dart';

final _durationPart = RegExp(r'(\d+(?:\.\d+)?)(ms|h|m|s)');
final _plainSeconds = RegExp(r'^\d+(?:\.\d+)?$');
final _zonedTimestamp = RegExp(r'(Z|[+-]\d\d:?\d\d)$');

/// Reads a duration: `90s`, `5m`, `1h20m30s`, `500ms`, or a plain number of
/// seconds. Units appear at most once each, largest first.
Duration _durationValue(String raw, String what, {bool allowZero = true}) {
  final duration = _tryDuration(raw.trim());
  if (duration == null || (!allowZero && duration == Duration.zero)) {
    _usage(
      '$what must be a duration such as 90s, 5m or 1h20m'
      '${allowZero ? '' : ' above 0'}, got "$raw".',
    );
  }
  return duration;
}

Duration? _tryDuration(String text) {
  if (text.isEmpty) return null;
  if (_plainSeconds.hasMatch(text)) {
    return _seconds(double.parse(text));
  }
  const order = ['h', 'm', 's', 'ms'];
  var rank = -1;
  var micros = 0.0;
  var consumed = 0;
  for (final match in _durationPart.allMatches(text)) {
    if (match.start != consumed) return null;
    final unitRank = order.indexOf(match[2]!);
    if (unitRank <= rank) return null;
    rank = unitRank;
    final value = double.parse(match[1]!);
    micros +=
        value *
        switch (match[2]) {
          'h' => Duration.microsecondsPerHour,
          'm' => Duration.microsecondsPerMinute,
          's' => Duration.microsecondsPerSecond,
          _ => Duration.microsecondsPerMillisecond,
        };
    consumed = match.end;
  }
  if (consumed != text.length) return null;
  return Duration(microseconds: micros.round());
}

Duration _seconds(double seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

/// A signed duration for `--shift-time`.
Duration _signedDuration(String raw, String what) {
  final text = raw.trim();
  final negative = text.startsWith('-');
  final body = text.startsWith('-') || text.startsWith('+')
      ? text.substring(1)
      : text;
  final duration = _durationValue(body, what);
  return negative ? -duration : duration;
}

/// A point in time as written on the command line, resolved against an
/// activity once it is loaded.
class _TimeSpec {
  _TimeSpec._(this.text, this._resolve);

  final String text;
  final DateTime Function(DateTime start, DateTime end) _resolve;

  factory _TimeSpec.parse(String raw, String what) {
    final text = raw.trim();
    if (text == 'start') return _TimeSpec._(text, (start, _) => start);
    if (text == 'end') return _TimeSpec._(text, (_, end) => end);
    if (text.startsWith('end-')) {
      final back = _durationValue(text.substring(4), what);
      return _TimeSpec._(text, (_, end) => end.subtract(back));
    }
    final offset = _tryDuration(text);
    if (offset != null) {
      return _TimeSpec._(text, (start, _) => start.add(offset));
    }
    final exact = DateTime.tryParse(text);
    if (exact != null && _zonedTimestamp.hasMatch(text)) {
      return _TimeSpec._(text, (_, _) => exact.toUtc());
    }
    _usage(
      '$what must be a duration from the start (5m), start, end, end-20m, or '
      'a timestamp with its zone (2024-05-01T07:35:00Z), got "$raw".',
    );
  }

  DateTime resolve(_TimeRange bounds) => _resolve(bounds.start, bounds.end);
}

/// The first and last recorded sample of an activity.
typedef _TimeRange = ({DateTime start, DateTime end});

_TimeRange _recordedRange(RawActivity activity) {
  DateTime? first;
  DateTime? last;
  void see(DateTime time) {
    if (first == null || time.isBefore(first!)) first = time;
    if (last == null || time.isAfter(last!)) last = time;
  }

  for (final point in activity.points) {
    see(point.time);
  }
  for (final samples in activity.channels.values) {
    for (final sample in samples) {
      see(sample.time);
    }
  }
  if (first == null) {
    throw _CliException(
      'The activity has no recorded samples, so a time cannot be placed.',
      _exitData,
    );
  }
  return (start: first!, end: last!);
}

(_TimeSpec, _TimeSpec) _range(String raw, String what) {
  final parts = raw.split('..');
  if (parts.length != 2) {
    _usage('$what must be a range FROM..TO, got "$raw".');
  }
  return (_TimeSpec.parse(parts[0], what), _TimeSpec.parse(parts[1], what));
}

/// One edit step, checked when it is read and applied to the activity later.
class _Step {
  _Step._(this.name, this.value, this._apply);

  final String name;
  final String? value;
  final RawEditor Function(RawEditor editor, _StepContext context) _apply;

  String get label => value == null ? '--$name' : '--$name $value';

  /// Applies the step; a step that does not fit the activity fails this file
  /// only.
  RawEditor apply(RawEditor editor, _StepContext context) {
    try {
      return _apply(editor, context);
    } on _CliException catch (e) {
      throw _FileFailure(e.message, e.exitCode);
    } on ArgumentError catch (e) {
      // An index or time the activity does not have; RangeError is an
      // ArgumentError. Anything else is an internal error.
      throw _FileFailure(
        '$label does not fit the activity: ${e.message}',
        _exitData,
      );
    }
  }

  factory _Step.parse(String name, String? value) {
    final what = '--$name';
    switch (name) {
      case 'sort-and-dedup':
        return _Step._(name, value, (e, _) => e.sortAndDedup());
      case 'strict-time-order':
        return _Step._(name, value, (e, _) => e.ensureStrictTimeOrder());
      case 'trim-invalid':
        return _Step._(name, value, (e, _) => e.trimInvalid());
      case 'recompute-distance-and-speed':
        return _Step._(name, value, (e, _) => e.recomputeDistanceAndSpeed());
      case 'auto-fix':
        return _Step._(name, value, (e, c) => e.autoFix(c.autoFix!));
    }
    final raw = value!;
    switch (name) {
      case 'crop':
        final (from, to) = _range(raw, what);
        return _Step._(name, value, (e, c) {
          final bounds = c.bounds(e);
          return e.crop(from.resolve(bounds), to.resolve(bounds));
        });
      case 'delete-range':
        final (from, to) = _range(raw, what);
        return _Step._(name, value, (e, c) {
          final bounds = c.bounds(e);
          return e.deleteRange(from.resolve(bounds), to.resolve(bounds));
        });
      case 'remove-pause':
        final (from, to) = _range(raw, what);
        return _Step._(name, value, (e, c) {
          final bounds = c.bounds(e);
          return e.removePause(from.resolve(bounds), to.resolve(bounds));
        });
      case 'shift-time':
        final delta = _signedDuration(raw, what);
        return _Step._(name, value, (e, _) => e.shiftTime(delta));
      case 'insert-pause':
        final parts = raw.split(',');
        if (parts.length != 2) {
          _usage('$what must be AT,DURATION, got "$raw".');
        }
        final at = _TimeSpec.parse(parts[0], what);
        final duration = _durationValue(parts[1], what);
        return _Step._(
          name,
          value,
          (e, c) => e.insertPause(at.resolve(c.bounds(e)), duration),
        );
      case 'insert-point':
        final parts = raw.split(',');
        if (parts.length != 3 && parts.length != 4) {
          _usage('$what must be TIME,LAT,LON or TIME,LAT,LON,ELE, got "$raw".');
        }
        final time = _TimeSpec.parse(parts[0], what);
        final latitude = _coordinate(parts[1], 90, what);
        final longitude = _coordinate(parts[2], 180, what);
        final elevation = parts.length == 4
            ? _finite(parts[3], '$what elevation')
            : null;
        return _Step._(
          name,
          value,
          (e, c) => e.insertPoint(
            GeoPoint(
              latitude: latitude,
              longitude: longitude,
              elevation: elevation,
              time: time.resolve(c.bounds(e)),
            ),
          ),
        );
      case 'update-point':
        final parts = raw.split(',');
        final index = _index(parts.first, what);
        double? latitude;
        double? longitude;
        double? elevation;
        _TimeSpec? time;
        for (final pair in parts.skip(1)) {
          final separator = pair.indexOf('=');
          final key = separator < 0 ? pair : pair.substring(0, separator);
          final field = separator < 0 ? '' : pair.substring(separator + 1);
          switch (key.trim()) {
            case 'lat':
              latitude = _coordinate(field, 90, what);
            case 'lon':
              longitude = _coordinate(field, 180, what);
            case 'ele':
              elevation = _finite(field, '$what ele');
            case 'time':
              time = _TimeSpec.parse(field, what);
            default:
              _usage(
                '$what takes INDEX followed by lat=, lon=, ele= or time=, '
                'got "$pair".',
              );
          }
        }
        if (parts.length < 2) {
          _usage('$what needs at least one of lat=, lon=, ele=, time=.');
        }
        return _Step._(
          name,
          value,
          (e, c) => e.updatePoint(
            index,
            latitude: latitude,
            longitude: longitude,
            elevation: elevation,
            time: time?.resolve(c.bounds(e)),
          ),
        );
      case 'delete-point':
        final index = _index(raw, what);
        return _Step._(name, value, (e, _) => e.deletePointAt(index));
      case 'downsample-time':
        final step = _durationValue(raw, what, allowZero: false);
        return _Step._(name, value, (e, _) => e.downsampleTime(step));
      case 'downsample-distance':
        final meters = _metersValue(raw, what);
        return _Step._(name, value, (e, _) => e.downsampleDistance(meters));
      case 'smooth-hr':
        final window = int.tryParse(raw.trim());
        if (window == null || window < 1) {
          _usage(
            '$what must be a whole number of samples above 0, got "$raw".',
          );
        }
        return _Step._(name, value, (e, _) => e.smoothHR(window));
      case 'mark-laps-by-distance':
        final meters = _metersValue(raw, what);
        return _Step._(name, value, (e, _) => e.markLapsByDistance(meters));
      case 'resample':
        final step = _durationValue(raw, what, allowZero: false);
        return _Step._(
          name,
          value,
          (e, _) => RawEditor(RawTransforms.resample(e.activity, step: step)),
        );
    }
    throw StateError('Unhandled step $name');
  }
}

/// What a step needs besides the activity.
class _StepContext {
  _StepContext({this.autoFix});

  final ActivityAutoFixOptions? autoFix;

  _TimeRange bounds(RawEditor editor) => _recordedRange(editor.activity);
}

int _index(String raw, String what) {
  final index = int.tryParse(raw.trim());
  if (index == null || index < 0) {
    _usage('$what needs a point index counting from 0, got "$raw".');
  }
  return index;
}

double _finite(String raw, String what) {
  final value = double.tryParse(raw.trim());
  if (value == null || !value.isFinite) {
    _usage('$what must be a number, got "$raw".');
  }
  return value;
}

double _coordinate(String raw, double limit, String what) {
  final value = _finite(raw, what);
  if (value < -limit || value > limit) {
    _usage('$what coordinate must be within -$limit and $limit, got "$raw".');
  }
  return value;
}
