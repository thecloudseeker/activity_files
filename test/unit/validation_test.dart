// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for activity validation.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('ValidationResult', () {
    test('isValid reflects error diagnostics', () {
      final result = ValidationResult(
        diagnostics: [
          const ValidationDiagnostic(
            severity: ValidationSeverity.error,
            code: 'test.error',
            message: 'An error',
          ),
        ],
      );
      expect(result.isValid, isFalse);
    });

    test('isValid true when only warnings', () {
      final result = ValidationResult(
        diagnostics: [
          const ValidationDiagnostic(
            severity: ValidationSeverity.warning,
            code: 'test.warning',
            message: 'A warning',
            suggestedFix: 'Fix it',
            priority: 2,
          ),
        ],
      );
      expect(result.isValid, isTrue);
      final w = result.warningDiagnostics.first;
      expect(w.suggestedFix, 'Fix it');
      expect(w.priority, 2);
    });

    test('backwards-compat errors/warnings strings populated', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final invalid = RawActivity(
        points: [
          GeoPoint(latitude: 95, longitude: 0, time: time),
          GeoPoint(latitude: 40, longitude: 200, time: time),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: time, value: 140),
            Sample(time: time, value: 141),
          ],
        },
      );
      final result = validateRawActivity(
        invalid,
        gapWarningThreshold: Duration.zero,
      );
      expect(result.errors.length, greaterThanOrEqualTo(3));
      expect(
        result.diagnostics.where((d) => d.isError).length,
        equals(result.errors.length),
      );
    });
  });

  group('validateRawActivity diagnostics', () {
    test('invalid latitude emits code and suggestedFix', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final activity = RawActivity(
        points: [GeoPoint(latitude: 95, longitude: 10, time: time)],
      );
      final result = validateRawActivity(activity);
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.coordinate.invalid_latitude',
      );
      expect(diag.severity, ValidationSeverity.error);
      expect(diag.suggestedFix, isNotNull);
      expect(diag.priority, isNotNull);
    });

    test('invalid longitude emits code and suggestedFix', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final activity = RawActivity(
        points: [GeoPoint(latitude: 45, longitude: 200, time: time)],
      );
      final result = validateRawActivity(activity);
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.coordinate.invalid_longitude',
      );
      expect(diag.suggestedFix, isNotNull);
    });

    test('negative power emits code and suggestedFix', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final activity = RawActivity(
        channels: {
          Channel.power: [Sample(time: time, value: -10)],
        },
      );
      final result = validateRawActivity(activity);
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.channel.negative_power',
      );
      expect(diag.severity, ValidationSeverity.error);
      expect(diag.suggestedFix, isNotNull);
    });

    test('out-of-range heart rate emits warning with suggestedFix', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final activity = RawActivity(
        channels: {
          Channel.heartRate: [Sample(time: time, value: 300)],
        },
      );
      final result = validateRawActivity(activity);
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.channel.heart_rate_out_of_range',
      );
      expect(diag.severity, ValidationSeverity.warning);
      expect(diag.suggestedFix, isNotNull);
    });

    test('distance decrease emits warning with suggestedFix', () {
      final t0 = DateTime.utc(2024, 1, 1, 12);
      final t1 = t0.add(const Duration(seconds: 10));
      final activity = RawActivity(
        channels: {
          Channel.distance: [
            Sample(time: t0, value: 100),
            Sample(time: t1, value: 90),
          ],
        },
      );
      final result = validateRawActivity(activity);
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.channel.distance_decrease',
      );
      expect(diag.severity, ValidationSeverity.warning);
      expect(diag.suggestedFix, isNotNull);
    });

    test('gap warning carries suggestedFix', () {
      final t0 = DateTime.utc(2024, 1, 1, 12);
      final t1 = t0.add(const Duration(minutes: 10));
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40, longitude: -105, time: t0),
          GeoPoint(latitude: 40.01, longitude: -105.01, time: t1),
        ],
      );
      final result = validateRawActivity(
        activity,
        gapWarningThreshold: const Duration(seconds: 60),
      );
      expect(result.errors, isEmpty);
      final gapDiag = result.diagnostics.firstWhere(
        (d) => d.code.endsWith('.gap'),
      );
      expect(gapDiag.severity, ValidationSeverity.warning);
      expect(gapDiag.suggestedFix, isNotNull);
    });

    test('out-of-order points emits error with suggestedFix', () {
      final t0 = DateTime.utc(2024, 1, 1, 12);
      final t1 = t0.subtract(const Duration(seconds: 1));
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40, longitude: -105, time: t0),
          GeoPoint(latitude: 40.01, longitude: -105.01, time: t1),
        ],
      );
      final result = validateRawActivity(
        activity,
        gapWarningThreshold: Duration.zero,
      );
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.points.out_of_order',
      );
      expect(diag.isError, isTrue);
      expect(diag.suggestedFix, isNotNull);
    });

    test('duplicate timestamp emits error with suggestedFix', () {
      final t = DateTime.utc(2024, 1, 1, 12);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40, longitude: -105, time: t),
          GeoPoint(latitude: 40.01, longitude: -105.01, time: t),
        ],
      );
      final result = validateRawActivity(
        activity,
        gapWarningThreshold: Duration.zero,
      );
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.points.duplicate_timestamp',
      );
      expect(diag.isError, isTrue);
      expect(diag.suggestedFix, isNotNull);
    });

    test('channel samples outside track emits warning with suggestedFix', () {
      final t0 = DateTime.utc(2024, 1, 1, 12);
      final t1 = t0.add(const Duration(minutes: 30));
      final before = t0.subtract(const Duration(minutes: 5));
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40, longitude: -105, time: t0),
          GeoPoint(latitude: 40.01, longitude: -105.01, time: t1),
        ],
        channels: {
          Channel.heartRate: [Sample(time: before, value: 120)],
        },
      );
      final result = validateRawActivity(activity);
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.channel.samples_before_track',
      );
      expect(diag.severity, ValidationSeverity.warning);
      expect(diag.suggestedFix, isNotNull);
    });
  });

  group('validateLapBoundariesList', () {
    test('inverted lap times emits error with suggestedFix', () {
      final t0 = DateTime.utc(2024, 1, 1, 12);
      final t1 = t0.subtract(const Duration(minutes: 5));
      final result = validateLapBoundariesList([
        Lap(startTime: t0, endTime: t1),
      ]);
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.laps.inverted_times',
      );
      expect(diag.isError, isTrue);
      expect(diag.suggestedFix, isNotNull);
    });

    test('overlapping laps emits overlap error with suggestedFix', () {
      final t0 = DateTime.utc(2024, 1, 1, 12);
      final t1 = t0.add(const Duration(minutes: 10));
      final t2 = t0.add(const Duration(minutes: 5));
      final t3 = t0.add(const Duration(minutes: 15));
      final result = validateLapBoundariesList([
        Lap(startTime: t0, endTime: t1),
        Lap(startTime: t2, endTime: t3),
      ]);
      final diag = result.diagnostics.firstWhere(
        (d) => d.code == 'validation.laps.overlap',
      );
      expect(diag.isError, isTrue);
      expect(diag.suggestedFix, contains(t1.toIso8601String()));
    });

    test('hasIssues reflects diagnostics', () {
      final t0 = DateTime.utc(2024, 1, 1, 12);
      final t1 = t0.add(const Duration(minutes: 5));
      final clean = validateLapBoundariesList([
        Lap(startTime: t0, endTime: t1),
      ]);
      expect(clean.hasIssues, isFalse);
    });
  });

  group('validateDeviceMetadata', () {
    test('empty metadata returns no diagnostics', () {
      const meta = ActivityDeviceMetadata();
      final diags = validateDeviceMetadata(meta);
      expect(diags, isEmpty);
    });

    test('valid known manufacturer returns no diagnostics', () {
      const meta = ActivityDeviceMetadata(
        manufacturer: 'Garmin',
        fitManufacturerId: 1,
      );
      final diags = validateDeviceMetadata(meta);
      expect(diags, isEmpty);
    });

    test('blank manufacturer string emits warning', () {
      const meta = ActivityDeviceMetadata(manufacturer: '   ');
      final diags = validateDeviceMetadata(meta);
      expect(
        diags.any((d) => d.code == 'validation.device.blank_field'),
        isTrue,
      );
      final diag = diags.firstWhere(
        (d) => d.code == 'validation.device.blank_field',
      );
      expect(diag.severity, ValidationSeverity.warning);
      expect(diag.suggestedFix, isNotNull);
    });

    test('invalid manufacturer ID emits error', () {
      const meta = ActivityDeviceMetadata(fitManufacturerId: 0);
      final diags = validateDeviceMetadata(meta);
      expect(
        diags.any(
          (d) => d.code == 'validation.device.invalid_fit_manufacturer_id',
        ),
        isTrue,
      );
      final diag = diags.firstWhere(
        (d) => d.code == 'validation.device.invalid_fit_manufacturer_id',
      );
      expect(diag.severity, ValidationSeverity.error);
      expect(diag.suggestedFix, isNotNull);
    });

    test('manufacturer ID 0xFFFF emits error', () {
      const meta = ActivityDeviceMetadata(fitManufacturerId: 0xFFFF);
      final diags = validateDeviceMetadata(meta);
      expect(
        diags.any(
          (d) => d.code == 'validation.device.invalid_fit_manufacturer_id',
        ),
        isTrue,
      );
    });

    test('manufacturer name mismatch emits warning with suggestedFix', () {
      const meta = ActivityDeviceMetadata(
        manufacturer: 'NotGarmin',
        fitManufacturerId: 1, // 1 = Garmin
      );
      final diags = validateDeviceMetadata(meta);
      final diag = diags.firstWhere(
        (d) => d.code == 'validation.device.manufacturer_name_mismatch',
      );
      expect(diag.severity, ValidationSeverity.warning);
      expect(diag.suggestedFix, contains('Garmin'));
    });

    test('name matching known ID (case-insensitive) emits no warning', () {
      const meta = ActivityDeviceMetadata(
        manufacturer: 'garmin', // lowercase, matches 'Garmin'
        fitManufacturerId: 1,
      );
      final diags = validateDeviceMetadata(meta);
      expect(
        diags.any(
          (d) => d.code == 'validation.device.manufacturer_name_mismatch',
        ),
        isFalse,
      );
    });

    test('negative product ID emits error', () {
      const meta = ActivityDeviceMetadata(fitProductId: -1);
      final diags = validateDeviceMetadata(meta);
      final diag = diags.firstWhere(
        (d) => d.code == 'validation.device.invalid_fit_product_id',
      );
      expect(diag.severity, ValidationSeverity.error);
      expect(diag.suggestedFix, isNotNull);
    });

    test('valid product ID with no name returns no diagnostics', () {
      const meta = ActivityDeviceMetadata(fitProductId: 3291);
      final diags = validateDeviceMetadata(meta);
      expect(diags.where((d) => d.isError), isEmpty);
    });
  });

  group('validateChannels', () {
    test('empty channel list emits warning', () {
      final channels = {Channel.heartRate: <Sample>[]};
      final diags = validateChannels(channels);
      expect(diags.any((d) => d.code == 'validation.channel.empty'), isTrue);
      final diag = diags.firstWhere(
        (d) => d.code == 'validation.channel.empty',
      );
      expect(diag.severity, ValidationSeverity.warning);
      expect(diag.suggestedFix, isNotNull);
    });

    test('single-sample channel emits warning', () {
      final t = DateTime.utc(2024, 1, 1, 12);
      final channels = {
        Channel.power: [Sample(time: t, value: 200)],
      };
      final diags = validateChannels(channels);
      expect(
        diags.any((d) => d.code == 'validation.channel.single_sample'),
        isTrue,
      );
    });

    test('two or more samples does not emit single_sample warning', () {
      final t0 = DateTime.utc(2024, 1, 1, 12);
      final t1 = t0.add(const Duration(seconds: 5));
      final channels = {
        Channel.power: [
          Sample(time: t0, value: 200),
          Sample(time: t1, value: 210),
        ],
      };
      final diags = validateChannels(channels);
      expect(
        diags.any((d) => d.code == 'validation.channel.single_sample'),
        isFalse,
      );
    });

    test('custom channel with a built-in name IS the built-in channel', () {
      // Channel.custom normalizes IDs (trim + lowercase), so
      // Channel.custom('heart_rate') is identical to Channel.heartRate and no
      // shadowing is possible; validateChannels intentionally has no such
      // check.
      final customChannel = Channel.custom('Heart_Rate');
      expect(customChannel, equals(Channel.heartRate));
      final t = DateTime.utc(2024, 1, 1, 12);
      final channels = {
        customChannel: [
          Sample(time: t, value: 70),
          Sample(time: t.add(const Duration(seconds: 1)), value: 72),
        ],
      };
      final diags = validateChannels(channels);
      expect(diags, isEmpty);
    });
  });

  group('DiagnosticCategory constants', () {
    test('all expected category strings are defined', () {
      expect(DiagnosticCategory.parse, 'parse');
      expect(DiagnosticCategory.lossy, 'lossy');
      expect(DiagnosticCategory.repaired, 'repaired');
      expect(DiagnosticCategory.validation, 'validation');
    });
  });

  group('ParseDiagnostic suggestedFix and priority', () {
    test('can be constructed with optional fields null', () {
      const d = ParseDiagnostic(
        severity: ParseSeverity.warning,
        code: 'test.code',
        message: 'test message',
      );
      expect(d.suggestedFix, isNull);
      expect(d.priority, isNull);
    });

    test('stores suggestedFix and priority', () {
      const d = ParseDiagnostic(
        severity: ParseSeverity.error,
        code: 'test.error',
        message: 'something broke',
        suggestedFix: 'Do the thing',
        priority: 0,
      );
      expect(d.suggestedFix, 'Do the thing');
      expect(d.priority, 0);
    });

    test(
      'DiagnosticsFormatter summary includes suggestedFix when requested',
      () {
        const d = ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'test.warn',
          message: 'a warning',
          suggestedFix: 'Fix suggestion',
        );
        final fmt = DiagnosticsFormatter([d]);
        final withFix = fmt.summary(includeSuggestedFix: true);
        expect(withFix, contains('Fix suggestion'));
        final withoutFix = fmt.summary(includeSuggestedFix: false);
        expect(withoutFix, isNot(contains('Fix suggestion')));
      },
    );
  });

  group('ParseFidelityMode (0.7.0)', () {
    test('enum has both expected values', () {
      expect(ParseFidelityMode.values, hasLength(2));
      expect(
        ParseFidelityMode.values,
        contains(ParseFidelityMode.strictFidelity),
      );
      expect(
        ParseFidelityMode.values,
        contains(ParseFidelityMode.pragmaticNormalize),
      );
    });

    test('strictFidelity and pragmaticNormalize are distinct', () {
      expect(
        ParseFidelityMode.strictFidelity,
        isNot(equals(ParseFidelityMode.pragmaticNormalize)),
      );
    });

    test('enum values have expected names', () {
      expect(ParseFidelityMode.strictFidelity.name, equals('strictFidelity'));
      expect(
        ParseFidelityMode.pragmaticNormalize.name,
        equals('pragmaticNormalize'),
      );
    });
  });
}
