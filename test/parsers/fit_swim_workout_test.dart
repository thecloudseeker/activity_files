// SPDX-License-Identifier: BSD-3-Clause
/// FIT parser tests for swim metrics and strength-training set parsing.
library;

import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../helpers/fit_helpers.dart';

void main() {
  // A FIT timestamp well within the valid range [1, 1924992000].
  // Corresponds to roughly 2001-09-09 UTC (FIT epoch = Dec 31, 1989).
  const baseTs = 365_000_000;

  group('FIT swim session parsing', () {
    test('parses pool_length, num_active_lengths, and swim_stroke', () {
      final bytes = _buildSwimSessionFit(
        baseTs: baseTs,
        poolLengthCm: 5000, // 50 m
        numActiveLengths: 40,
        swimStroke: 0, // freestyle
        subSport: 0,
        totalCycles: 0xFFFFFFFF, // FIT invalid sentinel → null
      );
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      final summary = result.activity.summary;
      expect(summary, isNotNull);
      expect(summary!.poolLengthMeters, closeTo(50.0, 0.001));
      expect(summary.numActiveLengths, equals(40));
      expect(summary.swimStroke, equals(SwimStroke.freestyle));
    });

    test('decodes all swim stroke enum values from FIT', () {
      final strokeCases = {
        0: SwimStroke.freestyle,
        1: SwimStroke.backstroke,
        2: SwimStroke.breaststroke,
        3: SwimStroke.butterfly,
        4: SwimStroke.drill,
        5: SwimStroke.mixed,
        6: SwimStroke.im,
      };
      for (final entry in strokeCases.entries) {
        final bytes = _buildSwimSessionFit(
          baseTs: baseTs,
          poolLengthCm: 2500,
          numActiveLengths: 20,
          swimStroke: entry.key,
        );
        final summary = ActivityParser.parseBytes(
          bytes,
          ActivityFileFormat.fit,
        ).activity.summary;
        expect(
          summary?.swimStroke,
          equals(entry.value),
          reason: 'stroke value ${entry.key} should map to ${entry.value}',
        );
      }
    });

    test('unknown swim stroke value (7) produces null', () {
      final bytes = _buildSwimSessionFit(
        baseTs: baseTs,
        poolLengthCm: 2500,
        numActiveLengths: 10,
        swimStroke: 7, // out of range → null
      );
      final summary = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.summary;
      expect(summary?.swimStroke, isNull);
    });

    test('parses sub_sport as int (non-zero)', () {
      final bytes = _buildSwimSessionFit(
        baseTs: baseTs,
        poolLengthCm: 0,
        numActiveLengths: 0,
        swimStroke: 0,
        subSport: 45, // jump rope
      );
      final summary = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.summary;
      expect(summary?.subSport, equals(45));
    });

    test('sub_sport = 0 yields null', () {
      final bytes = _buildSwimSessionFit(
        baseTs: baseTs,
        poolLengthCm: 0,
        numActiveLengths: 0,
        swimStroke: 0,
        subSport: 0,
      );
      final summary = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.summary;
      expect(summary?.subSport, isNull);
    });

    test('parses total_cycles when below invalid sentinel', () {
      final bytes = _buildSwimSessionFit(
        baseTs: baseTs,
        poolLengthCm: 0,
        numActiveLengths: 0,
        swimStroke: 0,
        totalCycles: 1200,
      );
      final summary = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.summary;
      expect(summary?.totalCycles, equals(1200));
    });

    test('total_cycles = 0xFFFFFFFF (FIT invalid sentinel) yields null', () {
      final bytes = _buildSwimSessionFit(
        baseTs: baseTs,
        poolLengthCm: 0,
        numActiveLengths: 0,
        swimStroke: 0,
        totalCycles: 0xFFFFFFFF,
      );
      final summary = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.summary;
      expect(summary?.totalCycles, isNull);
    });

    test('pool_length is divided by 100 to get metres', () {
      final bytes = _buildSwimSessionFit(
        baseTs: baseTs,
        poolLengthCm: 2500, // 25 m
        numActiveLengths: 8,
        swimStroke: 0,
      );
      final summary = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.summary;
      expect(summary?.poolLengthMeters, closeTo(25.0, 0.001));
    });
  });

  group('FIT swim lap parsing', () {
    test('parses swim_stroke and num_active_lengths', () {
      final bytes = _buildSwimLapFit(
        baseTs: baseTs,
        lapElapsedSec: 600,
        swimStroke: 1, // backstroke
        numActiveLengths: 20,
      );
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      expect(result.activity.laps, hasLength(1));
      final lap = result.activity.laps.first;
      expect(lap.swimStroke, equals(SwimStroke.backstroke));
      expect(lap.numActiveLengths, equals(20));
    });

    test(
      'lap total_elapsed_time is decoded from milliseconds (scale 1000)',
      () {
        final bytes = _buildSwimLapFit(
          baseTs: baseTs,
          lapElapsedSec: 300,
          swimStroke: 2,
          numActiveLengths: 10,
        );
        final lap = ActivityParser.parseBytes(
          bytes,
          ActivityFileFormat.fit,
        ).activity.laps.first;
        expect(lap.elapsed, equals(const Duration(minutes: 5)));
      },
    );

    test('unknown swim stroke in lap yields null', () {
      final bytes = _buildSwimLapFit(
        baseTs: baseTs,
        lapElapsedSec: 300,
        swimStroke: 9, // out of range
        numActiveLengths: 10,
      );
      final lap = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.laps.first;
      expect(lap.swimStroke, isNull);
    });
  });

  group('FIT session avg_stroke_count parsing', () {
    test('avg_stroke_count is divided by 10', () {
      final bytes = _buildSwimSessionFit(
        baseTs: baseTs,
        poolLengthCm: 2500,
        numActiveLengths: 10,
        swimStroke: 0,
        avgStrokeCountRaw: 135, // 135 / 10 = 13.5
      );
      final summary = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.summary;
      expect(summary?.avgStrokeCount, closeTo(13.5, 0.001));
    });

    test(
      'avg_stroke_count = 0xFFFFFFFF (FIT invalid sentinel) yields null',
      () {
        final bytes = _buildSwimSessionFit(
          baseTs: baseTs,
          poolLengthCm: 2500,
          numActiveLengths: 10,
          swimStroke: 0,
          avgStrokeCountRaw: 0xFFFFFFFF,
        );
        final summary = ActivityParser.parseBytes(
          bytes,
          ActivityFileFormat.fit,
        ).activity.summary;
        expect(summary?.avgStrokeCount, isNull);
      },
    );
  });

  group('FIT strength set parsing', () {
    test('parses set fields into WorkoutSet', () {
      final bytes = _buildSetFit(
        baseTs: baseTs,
        setDurationSec: 60,
        setType: 1, // active
        repetitions: 12,
        weightRaw: 800, // 800 / 16 = 50.0 kg
        exerciseCategoryRaw: 28, // Squat
      );
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      expect(result.activity.sets, hasLength(1));
      final s = result.activity.sets.first;
      expect(s.isRest, isFalse);
      expect(s.repetitions, equals(12));
      expect(s.weightKg, closeTo(50.0, 0.001));
      expect(s.exerciseCategoryId, equals(28));
      expect(s.exerciseCategory, equals('Squat'));
    });

    test('set with set_type=0 has isRest=true', () {
      final bytes = _buildSetFit(
        baseTs: baseTs,
        setDurationSec: 60,
        setType: 0, // rest
        repetitions: 0,
        weightRaw: 0,
        exerciseCategoryRaw: 0,
      );
      final s = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.sets.first;
      expect(s.isRest, isTrue);
    });

    test('repetitions at 0xFFFF (FIT invalid) yields null', () {
      final bytes = _buildSetFit(
        baseTs: baseTs,
        setDurationSec: 45,
        setType: 1,
        repetitions: 0xFFFF, // FIT invalid sentinel
        weightRaw: 320,
        exerciseCategoryRaw: 0,
      );
      final s = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.sets.first;
      expect(s.repetitions, isNull);
    });

    test('weight at 0xFFFF (FIT invalid) yields null', () {
      final bytes = _buildSetFit(
        baseTs: baseTs,
        setDurationSec: 45,
        setType: 1,
        repetitions: 10,
        weightRaw: 0xFFFF, // FIT invalid sentinel
        exerciseCategoryRaw: 0,
      );
      final s = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.sets.first;
      expect(s.weightKg, isNull);
    });

    test('exerciseCategory is resolved via categoryLabel', () {
      final bytes = _buildSetFit(
        baseTs: baseTs,
        setDurationSec: 45,
        setType: 1,
        repetitions: 8,
        weightRaw: 1600, // 1600 / 16 = 100.0 kg
        exerciseCategoryRaw: 8, // Deadlift
      );
      final s = ActivityParser.parseBytes(
        bytes,
        ActivityFileFormat.fit,
      ).activity.sets.first;
      expect(s.exerciseCategoryId, equals(8));
      expect(s.exerciseCategory, equals('Deadlift'));
    });

    test('multiple sets are accumulated in order', () {
      final bytes = _buildMultiSetFit(baseTs: baseTs);
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);
      expect(result.activity.sets, hasLength(2));
      expect(result.activity.sets[0].isRest, isFalse);
      expect(result.activity.sets[1].isRest, isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// FIT byte builders
// ---------------------------------------------------------------------------

/// Wraps [data] bytes in a FIT file envelope (header + CRC).
Uint8List _wrapFit(List<int> data) {
  final payload = Uint8List.fromList(data);
  final header = buildFitHeader(payload.length);
  final crc = fitCrc(payload);
  return Uint8List.fromList([
    ...header,
    ...payload,
    crc & 0xFF,
    (crc >> 8) & 0xFF,
  ]);
}

/// One record point at [baseTs] (FIT seconds from epoch).
List<int> _recordDef0() => [
  0x40, 0x00, 0x00, 0x14, 0x00, 0x03,
  0xFD, 0x04, 0x86, // timestamp: uint32
  0x00, 0x04, 0x85, // lat: sint32
  0x01, 0x04, 0x85, // lon: sint32
];

List<int> _recordData0(int ts) => [
  0x00,
  ...uint32LeBytes(ts),
  ...int32LeBytes(encodeSemicircles(51.5)),
  ...int32LeBytes(encodeSemicircles(-0.12)),
];

/// Builds a FIT file with a record + session (global 18) carrying swim fields.
Uint8List _buildSwimSessionFit({
  required int baseTs,
  required int poolLengthCm,
  required int numActiveLengths,
  required int swimStroke,
  int subSport = 0,
  int totalCycles = 0xFFFFFFFF,
  int avgStrokeCountRaw = 0xFFFFFFFF,
}) {
  final data = <int>[];

  // Local 0: record definition + data
  data.addAll(_recordDef0());
  data.addAll(_recordData0(baseTs));

  // Local 1: session (global 18) definition.
  // Field numbers per the official FIT profile:
  // pool_length(44/uint16, scale 100), num_active_lengths(47/uint16),
  // swim_stroke(43/uint8), sub_sport(6/uint8), total_cycles(10/uint32),
  // avg_stroke_count(41/uint32, scale 10)
  data.addAll([
    0x41, 0x00, 0x00, 0x12, 0x00, 0x06,
    0x2C, 0x02, 0x84, // pool_length (44): uint16
    0x2F, 0x02, 0x84, // num_active_lengths (47): uint16
    0x2B, 0x01, 0x02, // swim_stroke (43): uint8
    0x06, 0x01, 0x02, // sub_sport (6): uint8
    0x0A, 0x04, 0x86, // total_cycles (10): uint32
    0x29, 0x04, 0x86, // avg_stroke_count (41): uint32
  ]);

  // Local 1: session data
  data.addAll([
    0x01,
    ...uint16LeBytes(poolLengthCm),
    ...uint16LeBytes(numActiveLengths),
    swimStroke,
    subSport,
    ...uint32LeBytes(totalCycles),
    ...uint32LeBytes(avgStrokeCountRaw),
  ]);

  return _wrapFit(data);
}

/// Builds a FIT file with a record + lap (global 19) carrying swim fields.
Uint8List _buildSwimLapFit({
  required int baseTs,
  required int lapElapsedSec,
  required int swimStroke,
  required int numActiveLengths,
}) {
  final data = <int>[];

  // Local 0: record
  data.addAll(_recordDef0());
  data.addAll(_recordData0(baseTs));

  // Local 1: lap (global 19) definition.
  // Field numbers per the official FIT profile:
  // start_time(2/uint32), total_elapsed_time(7/uint32, scale 1000),
  // swim_stroke(38/uint8), num_active_lengths(40/uint16)
  data.addAll([
    0x41, 0x00, 0x00, 0x13, 0x00, 0x04,
    0x02, 0x04, 0x86, // start_time (2): uint32
    0x07, 0x04, 0x86, // total_elapsed_time (7): uint32
    0x26, 0x01, 0x02, // swim_stroke (38): uint8
    0x28, 0x02, 0x84, // num_active_lengths (40): uint16
  ]);

  // Local 1: lap data
  data.addAll([
    0x01,
    ...uint32LeBytes(baseTs), // start_time
    ...uint32LeBytes(lapElapsedSec * 1000), // total_elapsed_time (ms)
    swimStroke,
    ...uint16LeBytes(numActiveLengths),
  ]);

  return _wrapFit(data);
}

/// Builds a FIT file with a record + one set message (global 225).
Uint8List _buildSetFit({
  required int baseTs,
  required int setDurationSec,
  required int setType,
  required int repetitions,
  required int weightRaw,
  required int exerciseCategoryRaw,
}) {
  final data = <int>[];

  // Local 0: record
  data.addAll(_recordDef0());
  data.addAll(_recordData0(baseTs));

  // Local 1: set (global 225 = 0x00E1) definition.
  // Field numbers per the official FIT profile:
  // timestamp(254/uint32, set end), start_time(6/uint32),
  // set_type(5/uint8, 0 = rest / 1 = active), repetitions(3/uint16),
  // weight(4/uint16, scale 16), category(7/uint16)
  data.addAll([
    0x41, 0x00, 0x00, 0xE1, 0x00, 0x06,
    0xFE, 0x04, 0x86, // timestamp (254, set end): uint32
    0x06, 0x04, 0x86, // start_time (6): uint32
    0x05, 0x01, 0x02, // set_type (5): uint8
    0x03, 0x02, 0x84, // repetitions (3): uint16
    0x04, 0x02, 0x84, // weight (4): uint16
    0x07, 0x02, 0x84, // category (7): uint16
  ]);

  // Local 1: set data
  final endTs = baseTs + setDurationSec;
  data.addAll([
    0x01,
    ...uint32LeBytes(endTs), // end timestamp
    ...uint32LeBytes(baseTs), // start_time
    setType,
    ...uint16LeBytes(repetitions),
    ...uint16LeBytes(weightRaw),
    ...uint16LeBytes(exerciseCategoryRaw),
  ]);

  return _wrapFit(data);
}

/// Builds a FIT file with two set messages (one active, one rest).
Uint8List _buildMultiSetFit({required int baseTs}) {
  final data = <int>[];

  // Local 0: record
  data.addAll(_recordDef0());
  data.addAll(_recordData0(baseTs));

  // Local 1: set (global 225) definition
  data.addAll([
    0x41, 0x00, 0x00, 0xE1, 0x00, 0x03,
    0xFE, 0x04, 0x86, // timestamp (254, set end): uint32
    0x06, 0x04, 0x86, // start_time (6): uint32
    0x05, 0x01, 0x02, // set_type (5): uint8
  ]);

  // Set 1: active (set_type 1)
  data.addAll([
    0x01,
    ...uint32LeBytes(baseTs + 60),
    ...uint32LeBytes(baseTs),
    1,
  ]);

  // Set 2: rest (set_type 0)
  data.addAll([
    0x01,
    ...uint32LeBytes(baseTs + 120),
    ...uint32LeBytes(baseTs + 60),
    0,
  ]);

  return _wrapFit(data);
}
