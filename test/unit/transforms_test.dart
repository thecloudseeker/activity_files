// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for activity transforms.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Transforms', () {
    test('crop, downsample, and resample adjust counts', () {
      final start = DateTime.utc(2024, 1, 1, 12);
      final points = List.generate(
        6,
        (index) => GeoPoint(
          latitude: 40.0 + index * 0.001,
          longitude: -105.0 + index * 0.001,
          elevation: 1600 + index.toDouble(),
          time: start.add(Duration(seconds: index * 10)),
        ),
      );
      final hr = List.generate(
        6,
        (index) =>
            Sample(time: points[index].time, value: 140 + index.toDouble()),
      );
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hr},
      );

      final cropped = RawEditor(activity)
          .crop(
            start.add(const Duration(seconds: 10)),
            start.add(const Duration(seconds: 40)),
          )
          .activity;
      expect(cropped.points.length, 4);

      final downsampled = RawEditor(
        activity,
      ).downsampleTime(const Duration(seconds: 20)).activity;
      expect(downsampled.points.length, lessThan(activity.points.length));

      final resampled = RawTransforms.resample(
        activity,
        step: const Duration(seconds: 5),
      );
      expect(resampled.points.length, greaterThan(activity.points.length));
      expect(
        resampled.channel(Channel.heartRate).length,
        equals(activity.channel(Channel.heartRate).length),
      );

      final (activity: withDistance, totalDistance: total) =
          RawTransforms.computeCumulativeDistance(activity);
      expect(withDistance.channel(Channel.distance), isNotEmpty);
      expect(total, greaterThan(0));
    });

    test('markLapsByDistance computes split distances and remainder', () {
      final base = DateTime.utc(2024, 1, 2);
      final points = [
        GeoPoint(latitude: 40, longitude: -105, time: base),
        GeoPoint(
          latitude: 40.0005,
          longitude: -105.0005,
          time: base.add(const Duration(minutes: 5)),
        ),
        GeoPoint(
          latitude: 40.0007,
          longitude: -105.0007,
          time: base.add(const Duration(minutes: 10)),
        ),
        GeoPoint(
          latitude: 40.0009,
          longitude: -105.0009,
          time: base.add(const Duration(minutes: 15)),
        ),
      ];
      final distances = [
        Sample(time: points[0].time, value: 0),
        Sample(time: points[1].time, value: 800),
        Sample(time: points[2].time, value: 1800),
        Sample(time: points[3].time, value: 2300),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.distance: distances},
      );
      final laps = RawEditor(activity).markLapsByDistance(1000).activity.laps;
      expect(laps.length, 3);
      final rounded = laps
          .map((lap) => lap.distanceMeters?.round())
          .toList(growable: false);
      expect(rounded, equals([1000, 1000, 300]));
      expect(laps.last.distanceMeters, closeTo(300, 1e-6));
    });

    test('markLapsByDistance tolerates distance resets', () {
      final base = DateTime.utc(2024, 1, 5);
      final samples = <Sample>[
        Sample(time: base, value: 0),
        Sample(time: base.add(const Duration(minutes: 5)), value: 1100),
        Sample(time: base.add(const Duration(minutes: 10)), value: 1500),
        Sample(time: base.add(const Duration(minutes: 15)), value: 200),
        Sample(time: base.add(const Duration(minutes: 20)), value: 800),
        Sample(time: base.add(const Duration(minutes: 25)), value: 1400),
      ];
      final activity = RawActivity(channels: {Channel.distance: samples});

      final laps = RawEditor(activity).markLapsByDistance(1000).activity.laps;

      expect(laps.length, equals(3));
      expect(laps[0].distanceMeters, closeTo(1000, 1e-6));
      expect(laps[1].distanceMeters, closeTo(1000, 1e-6));
      expect(laps[2].distanceMeters, closeTo(700, 1e-6));
    });

    test('downsampleTime retains trailing point and channel samples', () {
      final base = DateTime.utc(2024, 1, 3, 6);
      final points = [
        GeoPoint(latitude: 40, longitude: -105, time: base),
        GeoPoint(
          latitude: 40.0002,
          longitude: -105.0002,
          time: base.add(const Duration(seconds: 3)),
        ),
        GeoPoint(
          latitude: 40.0004,
          longitude: -105.0004,
          time: base.add(const Duration(seconds: 5)),
        ),
      ];
      final hrSamples = [
        Sample(time: points[0].time, value: 140),
        Sample(time: points[2].time, value: 145),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hrSamples},
      );
      final downsampled = RawEditor(
        activity,
      ).downsampleTime(const Duration(seconds: 4)).activity;
      expect(downsampled.points.last.time, points.last.time);
      final hr = downsampled.channel(Channel.heartRate);
      expect(hr, isNotEmpty);
      expect(hr.last.time, points.last.time);
      expect(hr.last.value, closeTo(145, 1e-9));
    });

    test('sortAndDedup keeps latest sample for duplicate timestamps', () {
      final timestamp = DateTime.utc(2024, 1, 4, 7);
      final points = [GeoPoint(latitude: 40, longitude: -105, time: timestamp)];
      final samples = [
        Sample(time: timestamp, value: 150),
        Sample(time: timestamp, value: 155),
      ];
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: samples},
      );
      final normalized = RawEditor(activity).sortAndDedup().activity;
      final hr = normalized.channel(Channel.heartRate);
      expect(hr.length, 1);
      expect(hr.single.value, closeTo(155, 1e-9));
    });
  });
}
