// SPDX-License-Identifier: BSD-3-Clause
import 'package:activity_files/src/models.dart';
import 'package:activity_files/src/transforms.dart';
import 'package:test/test.dart';

void main() {
  group('RawEditor.trimInvalid', () {
    test('preserves sensor-only activities', () {
      final base = DateTime.utc(2024, 1, 1, 6);
      final invalidPoint = GeoPoint(
        latitude: 200, // outside valid range
        longitude: 0,
        time: base,
      );
      final activity = RawActivity(
        points: [invalidPoint],
        channels: {
          Channel.heartRate: [Sample(time: base, value: 140)],
        },
      );

      final trimmed = RawEditor(activity).trimInvalid().activity;

      expect(trimmed.points, isEmpty);
      final hr = trimmed.channel(Channel.heartRate);
      expect(hr, hasLength(1));
      expect(hr.single.value, equals(140));
    });

    test('continues to trim channels to the valid time window', () {
      final base = DateTime.utc(2024, 1, 1, 6);
      final invalid = GeoPoint(latitude: 200, longitude: 0, time: base);
      final validStart = GeoPoint(
        latitude: 40.0,
        longitude: -105.0,
        time: base.add(const Duration(seconds: 10)),
      );
      final validEnd = GeoPoint(
        latitude: 40.0001,
        longitude: -105.0001,
        time: base.add(const Duration(seconds: 40)),
      );
      final activity = RawActivity(
        points: [invalid, validStart, validEnd],
        channels: {
          Channel.heartRate: [
            Sample(time: base, value: 130), // before window
            Sample(time: base.add(const Duration(seconds: 20)), value: 150),
            Sample(time: base.add(const Duration(minutes: 1)), value: 160),
          ],
        },
      );

      final trimmed = RawEditor(activity).trimInvalid().activity;

      final hr = trimmed.channel(Channel.heartRate);
      expect(hr, hasLength(1));
      expect(hr.single.time, equals(base.add(const Duration(seconds: 20))));
      expect(trimmed.points, hasLength(2));
      expect(trimmed.points.first.time, equals(validStart.time));
      expect(trimmed.points.last.time, equals(validEnd.time));
    });
  });

  group('RawEditor.downsampleDistance', () {
    test('retains the terminal point despite a short final hop', () {
      final base = DateTime.utc(2024, 1, 2, 7);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0006, // ~66 m north
          longitude: -105.0,
          time: base.add(const Duration(seconds: 10)),
        ),
        GeoPoint(
          latitude: 40.00065, // only ~5 m from previous
          longitude: -105.0,
          time: base.add(const Duration(seconds: 20)),
        ),
      ];
      final activity = RawActivity(points: points);

      final downsampled = RawEditor(activity).downsampleDistance(50).activity;

      expect(downsampled.points, hasLength(3));
      expect(downsampled.points.last.time, equals(points.last.time));
    });

    test('retains the final point even when timestamps are identical', () {
      final base = DateTime.utc(2024, 1, 2, 7);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0006, // ~66 m north
          longitude: -105.0,
          time: base.add(const Duration(seconds: 10)),
        ),
        GeoPoint(
          latitude: 40.00065, // ~5 m hop but sharing the previous timestamp
          longitude: -105.0,
          time: base.add(const Duration(seconds: 10)),
        ),
      ];
      final activity = RawActivity(points: points);

      final downsampled = RawEditor(activity).downsampleDistance(50).activity;

      expect(downsampled.points, hasLength(3));
      expect(downsampled.points.last, same(points.last));
    });

    test('avoids duplicating the last point when already retained', () {
      final base = DateTime.utc(2024, 1, 2, 7);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0006,
          longitude: -105.0,
          time: base.add(const Duration(seconds: 10)),
        ),
      ];
      final activity = RawActivity(points: points);

      final downsampled = RawEditor(activity).downsampleDistance(50).activity;

      expect(downsampled.points, hasLength(2));
      expect(downsampled.points.last.time, equals(points.last.time));
    });

    test('resamples sensor channels near retained points', () {
      final base = DateTime.utc(2024, 1, 3, 8);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0006,
          longitude: -105.0,
          time: base.add(const Duration(seconds: 10)),
        ),
        GeoPoint(
          latitude: 40.0012,
          longitude: -105.0,
          time: base.add(const Duration(seconds: 20)),
        ),
      ];
      final hrSamples = [
        Sample(time: base.add(const Duration(milliseconds: 200)), value: 130),
        Sample(
          time: base.add(const Duration(seconds: 10, milliseconds: 300)),
          value: 135,
        ),
        Sample(
          time: base.add(const Duration(seconds: 20, milliseconds: 250)),
          value: 140,
        ),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hrSamples},
      );

      final downsampled = RawEditor(activity).downsampleDistance(50).activity;

      final hr = downsampled.channel(Channel.heartRate);
      expect(hr, hasLength(points.length));
      for (var i = 0; i < points.length; i++) {
        expect(hr[i].time, equals(points[i].time));
        expect(hr[i].value, equals(hrSamples[i].value));
      }
    });

    test('drops channel samples with no nearby retained point', () {
      final base = DateTime.utc(2024, 1, 3, 9);
      final points = [
        GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
        GeoPoint(
          latitude: 40.0006,
          longitude: -105.0,
          time: base.add(const Duration(seconds: 10)),
        ),
      ];
      final hrSamples = [
        Sample(time: base.subtract(const Duration(seconds: 30)), value: 120),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hrSamples},
      );

      final downsampled = RawEditor(activity).downsampleDistance(50).activity;

      expect(downsampled.channel(Channel.heartRate), isEmpty);
    });
  });

  group('RawEditor.smoothHR', () {
    test('applies a sliding window average', () {
      final base = DateTime.utc(2024, 1, 4, 6);
      final hrSamples = [
        Sample(time: base, value: 100),
        Sample(time: base.add(const Duration(seconds: 30)), value: 110),
        Sample(time: base.add(const Duration(seconds: 60)), value: 120),
        Sample(time: base.add(const Duration(seconds: 90)), value: 130),
      ];
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40.0, longitude: -105.0, time: base),
          GeoPoint(
            latitude: 40.0002,
            longitude: -105.0002,
            time: base.add(const Duration(seconds: 90)),
          ),
        ],
        channels: {Channel.heartRate: hrSamples},
      );

      final smoothed = RawEditor(activity).smoothHR(3).activity;
      final values =
          smoothed.channel(Channel.heartRate).map((sample) => sample.value);

      expect(values, orderedEquals([105, 110, 120, 125]));
    });
  });

  group('RawActivity.copyWith', () {
    test('reuses immutable collections when unchanged', () {
      final base = DateTime.utc(2024, 1, 5, 7);
      final point = GeoPoint(latitude: 40.0, longitude: -105.0, time: base);
      final hr = [Sample(time: base, value: 140)];
      final activity = RawActivity(
        points: [point],
        channels: {Channel.heartRate: hr},
      );
      // Populate the distance cache once to ensure it can be reused.
      expect(activity.approximateDistance, closeTo(0, 1e-9));

      final copy = activity.copyWith();

      expect(
        identical(copy.channels[Channel.heartRate], activity.channels[Channel.heartRate]),
        isTrue,
      );
      expect(
        identical(copy.points, activity.points),
        isTrue,
      );
      expect(copy.approximateDistance, equals(activity.approximateDistance));
    });
  });
}
