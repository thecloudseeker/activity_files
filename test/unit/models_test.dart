// SPDX-License-Identifier: BSD-3-Clause
/// Unit tests for data models.
///
/// Tests all model classes and their properties: Channel, GeoPoint, Sample,
/// Lap, ActivityDeviceMetadata, GpxExtensionNode, and RawActivity.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Channel Type Coverage', () {
    test('all v2 channels have unique IDs', () {
      final ids = <String>{
        Channel.heartRate.id,
        Channel.cadence.id,
        Channel.power.id,
        Channel.temperature.id,
        Channel.waterTemperature.id,
        Channel.depth.id,
        Channel.speed.id,
        Channel.course.id,
        Channel.bearing.id,
        Channel.distance.id,
      };

      expect(ids.length, 10);
    });

    test('custom channels work with new channel types', () {
      final custom = Channel.custom('custom_sensor');
      expect(custom.id, 'custom_sensor');
      expect(custom == Channel.custom('CUSTOM_SENSOR'), true);
    });
  });

  group('Channel', () {
    test('predefined channels have correct IDs', () {
      expect(Channel.heartRate.id, 'heart_rate');
      expect(Channel.cadence.id, 'cadence');
      expect(Channel.power.id, 'power');
      expect(Channel.temperature.id, 'temperature');
      expect(Channel.waterTemperature.id, 'water_temperature');
      expect(Channel.depth.id, 'depth');
      expect(Channel.speed.id, 'speed');
      expect(Channel.course.id, 'course');
      expect(Channel.bearing.id, 'bearing');
      expect(Channel.distance.id, 'distance');
    });

    test('custom channels normalize ID to lowercase', () {
      expect(Channel.custom('HEART_RATE').id, 'heart_rate');
      expect(Channel.custom('  heart_rate  ').id, 'heart_rate');
      expect(Channel.custom('MyCustom').id, 'mycustom');
    });

    test('channels with same ID are equal', () {
      final ch1 = Channel.custom('test_channel');
      final ch2 = Channel.custom('TEST_CHANNEL');
      expect(ch1, equals(ch2));
      expect(ch1.hashCode, equals(ch2.hashCode));
    });

    test('channels with different IDs are not equal', () {
      final ch1 = Channel.custom('channel1');
      final ch2 = Channel.custom('channel2');
      expect(ch1, isNot(equals(ch2)));
      expect(ch1.hashCode, isNot(equals(ch2.hashCode)));
    });

    test('channel is not equal to non-channel objects', () {
      final ch = Channel.custom('test');
      final Object otherString = 'test';
      expect(ch == otherString, isFalse);
      expect(ch, isNotNull);
      final Object otherInt = 123;
      expect(ch == otherInt, isFalse);
    });

    test('channel toString returns proper format', () {
      expect(Channel.heartRate.toString(), 'Channel(heart_rate)');
      expect(Channel.custom('test').toString(), 'Channel(test)');
    });
  });

  group('GeoPoint', () {
    final baseTime = DateTime(2023, 6, 15, 12, 0, 0);

    test('creates geopoint with all fields', () {
      final point = GeoPoint(
        latitude: 40.7128,
        longitude: -74.0060,
        elevation: 10.5,
        time: baseTime,
      );
      expect(point.latitude, 40.7128);
      expect(point.longitude, -74.0060);
      expect(point.elevation, 10.5);
      expect(point.time, baseTime.toUtc());
    });

    test('creates geopoint without elevation', () {
      final point = GeoPoint(
        latitude: 51.5074,
        longitude: -0.1278,
        time: baseTime,
      );
      expect(point.latitude, 51.5074);
      expect(point.longitude, -0.1278);
      expect(point.elevation, isNull);
      expect(point.time, baseTime.toUtc());
    });

    test('converts time to UTC', () {
      final localTime = DateTime(2023, 6, 15, 12, 0, 0);
      final point = GeoPoint(latitude: 0, longitude: 0, time: localTime);
      expect(point.time.isUtc, isTrue);
    });

    test('copyWith creates new instance with overrides', () {
      final point = GeoPoint(
        latitude: 40.7128,
        longitude: -74.0060,
        elevation: 10.5,
        time: baseTime,
      );
      final copy = point.copyWith(latitude: 51.5074, elevation: 20.0);
      expect(copy.latitude, 51.5074);
      expect(copy.longitude, -74.0060);
      expect(copy.elevation, 20.0);
      expect(copy.time, baseTime.toUtc());
    });

    test('copyWith with time converts to UTC', () {
      final point = GeoPoint(latitude: 0, longitude: 0, time: baseTime);
      final newTime = DateTime(2023, 7, 1, 15, 30, 0);
      final copy = point.copyWith(time: newTime);
      expect(copy.time.isUtc, isTrue);
      expect(copy.time.year, 2023);
    });

    test('copyWith preserves null elevation', () {
      final point = GeoPoint(latitude: 0, longitude: 0, time: baseTime);
      final copy = point.copyWith();
      expect(copy.elevation, isNull);
    });
  });

  group('Sample', () {
    final baseTime = DateTime(2023, 6, 15, 12, 0, 0);

    test('creates sample with numeric value', () {
      final sample = Sample(time: baseTime, value: 145.5);
      expect(sample.time, baseTime.toUtc());
      expect(sample.value, 145.5);
    });

    test('handles integer and double values', () {
      final intSample = Sample(time: baseTime, value: 100);
      final doubleSample = Sample(time: baseTime, value: 100.5);
      expect(intSample.value, 100);
      expect(doubleSample.value, 100.5);
    });

    test('converts time to UTC', () {
      final localTime = DateTime(2023, 6, 15, 12, 0, 0);
      final sample = Sample(time: localTime, value: 50);
      expect(sample.time.isUtc, isTrue);
    });

    test('copyWith creates new instance with overrides', () {
      final sample = Sample(time: baseTime, value: 145.5);
      final newTime = DateTime(2023, 6, 15, 12, 1, 0);
      final copy = sample.copyWith(time: newTime, value: 155.0);
      expect(copy.time.toUtc().minute, 1);
      expect(copy.value, 155.0);
    });

    test('copyWith preserves original value if not overridden', () {
      final sample = Sample(time: baseTime, value: 123.4);
      final copy = sample.copyWith();
      expect(copy.value, 123.4);
    });

    test('copyWith with zero and negative values', () {
      final sample = Sample(time: baseTime, value: 0);
      final negCopy = sample.copyWith(value: -10.5);
      expect(negCopy.value, -10.5);
    });
  });

  group('Lap', () {
    final startTime = DateTime(2023, 6, 15, 12, 0, 0);
    final endTime = DateTime(2023, 6, 15, 12, 5, 0);

    test('creates lap with required fields', () {
      final lap = Lap(startTime: startTime, endTime: endTime);
      expect(lap.startTime, startTime.toUtc());
      expect(lap.endTime, endTime.toUtc());
      expect(lap.distanceMeters, isNull);
      expect(lap.name, isNull);
      expect(lap.sport, isNull);
    });

    test('creates lap with all fields', () {
      final lap = Lap(
        startTime: startTime,
        endTime: endTime,
        distanceMeters: 1000.0,
        name: 'Lap 1',
        sport: Sport.running,
      );
      expect(lap.distanceMeters, 1000.0);
      expect(lap.name, 'Lap 1');
      expect(lap.sport, Sport.running);
    });

    test('elapsed returns duration between start and end', () {
      final lap = Lap(startTime: startTime, endTime: endTime);
      expect(lap.elapsed, Duration(minutes: 5));
    });

    test('converts times to UTC', () {
      final lap = Lap(startTime: startTime, endTime: endTime);
      expect(lap.startTime.isUtc, isTrue);
      expect(lap.endTime.isUtc, isTrue);
    });

    test('copyWith creates new instance with overrides', () {
      final lap = Lap(
        startTime: startTime,
        endTime: endTime,
        distanceMeters: 500.0,
        name: 'Test Lap',
        sport: Sport.cycling,
      );
      final newStart = DateTime(2023, 6, 15, 12, 1, 0);
      final newEnd = DateTime(2023, 6, 15, 12, 13, 0);
      final copy = lap.copyWith(
        startTime: newStart,
        endTime: newEnd,
        distanceMeters: 1000.0,
      );
      expect(copy.startTime.toUtc().minute, 1);
      expect(copy.endTime.toUtc().minute, 13);
      expect(copy.distanceMeters, 1000.0);
      expect(copy.name, 'Test Lap');
      expect(copy.sport, Sport.cycling);
    });

    test('copyWith can override sport to null', () {
      final lap = Lap(
        startTime: startTime,
        endTime: endTime,
        sport: Sport.swimming,
      );
      final copy = lap.copyWith(sport: Sport.unknown);
      expect(copy.sport, Sport.unknown);
    });

    test('supports all sport types', () {
      for (final sport in Sport.values) {
        final lap = Lap(startTime: startTime, endTime: endTime, sport: sport);
        expect(lap.sport, sport);
      }
    });
  });

  group('ActivityDeviceMetadata', () {
    test('creates empty metadata', () {
      final metadata = ActivityDeviceMetadata();
      expect(metadata.isEmpty, isTrue);
      expect(metadata.isNotEmpty, isFalse);
      expect(metadata.manufacturer, isNull);
      expect(metadata.model, isNull);
      expect(metadata.product, isNull);
      expect(metadata.serialNumber, isNull);
      expect(metadata.softwareVersion, isNull);
      expect(metadata.fitManufacturerId, isNull);
      expect(metadata.fitProductId, isNull);
    });

    test('creates metadata with fields', () {
      final metadata = ActivityDeviceMetadata(
        manufacturer: 'Garmin',
        model: 'Forerunner 965',
        product: 'fr965',
        serialNumber: '123ABC',
        softwareVersion: '12.50',
        fitManufacturerId: 1,
        fitProductId: 2255,
      );
      expect(metadata.isEmpty, isFalse);
      expect(metadata.isNotEmpty, isTrue);
      expect(metadata.manufacturer, 'Garmin');
      expect(metadata.model, 'Forerunner 965');
      expect(metadata.product, 'fr965');
      expect(metadata.serialNumber, '123ABC');
      expect(metadata.softwareVersion, '12.50');
      expect(metadata.fitManufacturerId, 1);
      expect(metadata.fitProductId, 2255);
    });

    test('isEmpty returns true only when all fields are null or blank', () {
      var metadata = ActivityDeviceMetadata(manufacturer: '  ');
      expect(metadata.isEmpty, isTrue);

      metadata = ActivityDeviceMetadata(manufacturer: 'Garmin');
      expect(metadata.isEmpty, isFalse);

      metadata = ActivityDeviceMetadata(fitManufacturerId: 1);
      expect(metadata.isEmpty, isFalse);
    });

    test('copyWith creates new instance with overrides', () {
      final original = ActivityDeviceMetadata(
        manufacturer: 'Garmin',
        model: 'FR945',
      );
      final copy = original.copyWith(model: 'FR965', serialNumber: 'SN123');
      expect(copy.manufacturer, 'Garmin');
      expect(copy.model, 'FR965');
      expect(copy.serialNumber, 'SN123');
      expect(copy.product, isNull);
    });

    test('copyWith with FIT IDs', () {
      final original = ActivityDeviceMetadata(fitManufacturerId: 1);
      final copy = original.copyWith(fitProductId: 2255);
      expect(copy.fitManufacturerId, 1);
      expect(copy.fitProductId, 2255);
    });
  });

  group('GpxExtensionNode', () {
    test('creates node with required name', () {
      final node = GpxExtensionNode(name: 'extension');
      expect(node.name, 'extension');
      expect(node.namespacePrefix, isNull);
      expect(node.namespaceUri, isNull);
      expect(node.value, isNull);
      expect(node.attributes, isEmpty);
      expect(node.children, isEmpty);
    });

    test('creates node with all fields', () {
      final attrs = {'attr1': 'value1', 'attr2': 'value2'};
      final children = [
        GpxExtensionNode(name: 'child1'),
        GpxExtensionNode(name: 'child2'),
      ];
      final node = GpxExtensionNode(
        name: 'parent',
        namespacePrefix: 'ns',
        namespaceUri: 'http://example.com',
        value: 'text content',
        attributes: attrs,
        children: children,
      );
      expect(node.name, 'parent');
      expect(node.namespacePrefix, 'ns');
      expect(node.namespaceUri, 'http://example.com');
      expect(node.value, 'text content');
      expect(node.attributes, equals(attrs));
      expect(node.children, equals(children));
    });

    test('attributes and children are immutable', () {
      final mutableAttrs = {'key': 'value'};
      final mutableChildren = [GpxExtensionNode(name: 'child')];
      final node = GpxExtensionNode(
        name: 'test',
        attributes: mutableAttrs,
        children: mutableChildren,
      );
      expect(() {
        // ignore: avoid_types_on_closure_parameters
        node.attributes['new'] = 'val';
      }, throwsUnsupportedError);
      expect(() {
        // ignore: avoid_types_on_closure_parameters
        node.children.add(GpxExtensionNode(name: 'new'));
      }, throwsUnsupportedError);
    });

    test('copyWith creates new instance with overrides', () {
      final original = GpxExtensionNode(
        name: 'element',
        namespacePrefix: 'tpx',
        value: 'original',
      );
      final copy = original.copyWith(
        value: 'updated',
        namespaceUri: 'http://example.com',
      );
      expect(copy.name, 'element');
      expect(copy.namespacePrefix, 'tpx');
      expect(copy.value, 'updated');
      expect(copy.namespaceUri, 'http://example.com');
    });

    test('copyWith with attributes', () {
      final original = GpxExtensionNode(name: 'node', attributes: {'a': 'b'});
      final copy = original.copyWith(attributes: {'x': 'y', 'z': 'w'});
      expect(copy.attributes, equals({'x': 'y', 'z': 'w'}));
    });
  });

  group('RawActivity', () {
    final now = DateTime(2023, 6, 15, 12, 0, 0).toUtc();
    final later = DateTime(2023, 6, 15, 12, 5, 0).toUtc();

    test('creates empty activity', () {
      final activity = RawActivity();
      expect(activity.points, isEmpty);
      expect(activity.channels, isEmpty);
      expect(activity.laps, isEmpty);
      expect(activity.sport, Sport.unknown);
      expect(activity.creator, isNull);
      expect(activity.device, isNull);
      expect(activity.approximateDistance, 0);
    });

    test('creates activity with all fields', () {
      final points = [
        GeoPoint(latitude: 40.7, longitude: -74.0, time: now),
        GeoPoint(latitude: 40.8, longitude: -74.1, time: later),
      ];
      final samples = [Sample(time: now, value: 100)];
      final laps = [Lap(startTime: now, endTime: later)];
      final metadata = ActivityDeviceMetadata(manufacturer: 'Garmin');
      final extensions = [GpxExtensionNode(name: 'ext')];

      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: samples},
        laps: laps,
        sport: Sport.running,
        creator: 'TestApp v1.0',
        device: metadata,
        gpxMetadataName: 'My Run',
        gpxMetadataDescription: 'A great run',
        gpxIncludeCreatorMetadataDescription: false,
        gpxTrackName: 'Track 1',
        gpxTrackDescription: 'Track Description',
        gpxTrackType: 'Run',
        gpxMetadataExtensions: extensions,
        gpxTrackExtensions: extensions,
      );

      expect(activity.points, equals(points));
      expect(activity.channels[Channel.heartRate], equals(samples));
      expect(activity.laps, equals(laps));
      expect(activity.sport, Sport.running);
      expect(activity.creator, 'TestApp v1.0');
      expect(activity.device, isNotNull);
      expect(activity.gpxMetadataName, 'My Run');
      expect(activity.gpxIncludeCreatorMetadataDescription, isFalse);
    });

    test('channel returns samples for existing channel', () {
      final samples = [Sample(time: now, value: 150)];
      final activity = RawActivity(channels: {Channel.cadence: samples});
      expect(activity.channel(Channel.cadence), equals(samples));
    });

    test('channel returns empty list for missing channel', () {
      final activity = RawActivity();
      expect(activity.channel(Channel.power), isEmpty);
    });

    test('startTime returns first point time', () {
      final points = [
        GeoPoint(latitude: 0, longitude: 0, time: now),
        GeoPoint(latitude: 1, longitude: 1, time: later),
      ];
      final activity = RawActivity(points: points);
      expect(activity.startTime, now);
    });

    test('startTime returns null for empty activity', () {
      final activity = RawActivity();
      expect(activity.startTime, isNull);
    });

    test('endTime returns last point time', () {
      final points = [
        GeoPoint(latitude: 0, longitude: 0, time: now),
        GeoPoint(latitude: 1, longitude: 1, time: later),
      ];
      final activity = RawActivity(points: points);
      expect(activity.endTime, later);
    });

    test('endTime returns null for empty activity', () {
      final activity = RawActivity();
      expect(activity.endTime, isNull);
    });

    test('approximateDistance from distance channel', () {
      final samples = [
        Sample(time: now, value: 0),
        Sample(time: later, value: 1500),
      ];
      final activity = RawActivity(channels: {Channel.distance: samples});
      expect(activity.approximateDistance, 1500);
    });

    test('approximateDistance from geographic points (haversine)', () {
      final points = [
        GeoPoint(latitude: 40.7128, longitude: -74.0060, time: now),
        GeoPoint(latitude: 40.7580, longitude: -73.9855, time: later),
      ];
      final activity = RawActivity(points: points);
      expect(activity.approximateDistance, greaterThan(0));
      expect(activity.approximateDistance, lessThan(10000)); // ~6.4 km
    });

    test('approximateDistance returns 0 for single point', () {
      final points = [
        GeoPoint(latitude: 40.7128, longitude: -74.0060, time: now),
      ];
      final activity = RawActivity(points: points);
      expect(activity.approximateDistance, 0);
    });

    test('copyWith creates new instance with overrides', () {
      final original = RawActivity(
        sport: Sport.cycling,
        creator: 'OriginalApp',
      );
      final newPoints = [GeoPoint(latitude: 0, longitude: 0, time: now)];
      final copy = original.copyWith(points: newPoints, sport: Sport.running);
      expect(copy.sport, Sport.running);
      expect(copy.creator, 'OriginalApp');
      expect(copy.points, equals(newPoints));
    });

    test('copyWith preserves channels map', () {
      final samples = [Sample(time: now, value: 100)];
      final original = RawActivity(channels: {Channel.power: samples});
      final copy = original.copyWith();
      expect(copy.channels[Channel.power], equals(samples));
    });

    test('collections are unmodifiable', () {
      final activity = RawActivity(
        points: [GeoPoint(latitude: 0, longitude: 0, time: now)],
        channels: {Channel.heartRate: []},
        laps: [Lap(startTime: now, endTime: later)],
      );
      expect(
        () => (activity.points as List<dynamic>).add(
          GeoPoint(latitude: 1, longitude: 1, time: later),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => (activity.laps as List<dynamic>).add(
          Lap(startTime: now, endTime: later),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('Sport enum', () {
    test('sport enum has 7 values', () {
      expect(Sport.values.length, 7);
    });

    test('unknown is the first sport value', () {
      expect(Sport.values.first, Sport.unknown);
    });
  });

  group('ActivityFileFormat enum', () {
    test('format enum has 5 values', () {
      expect(ActivityFileFormat.values.length, 5);
    });
  });

  group('SwimStroke enum', () {
    test('has 7 values', () {
      expect(SwimStroke.values.length, 7);
    });
  });

  group('WorkoutSet', () {
    final start = DateTime.utc(2024, 1, 1, 10, 0, 0);
    final end = DateTime.utc(2024, 1, 1, 10, 0, 45);

    test('constructor stores fields', () {
      final s = WorkoutSet(
        startTime: start,
        endTime: end,
        isRest: false,
        exerciseCategory: 'Squat',
        repetitions: 10,
        weightKg: 80.0,
      );
      expect(s.startTime, start);
      expect(s.endTime, end);
      expect(s.isRest, isFalse);
      expect(s.exerciseCategory, 'Squat');
      expect(s.repetitions, 10);
      expect(s.weightKg, 80.0);
    });

    test('times are normalised to UTC', () {
      final localStart = DateTime(2024, 1, 1, 10, 0, 0);
      final s = WorkoutSet(
        startTime: localStart,
        endTime: localStart.add(const Duration(seconds: 30)),
        isRest: false,
      );
      expect(s.startTime.isUtc, isTrue);
      expect(s.endTime.isUtc, isTrue);
    });

    test('elapsed computes duration', () {
      final s = WorkoutSet(startTime: start, endTime: end, isRest: false);
      expect(s.elapsed, const Duration(seconds: 45));
    });

    test('isRest can be true', () {
      final s = WorkoutSet(startTime: start, endTime: end, isRest: true);
      expect(s.isRest, isTrue);
    });

    test('copyWith overrides individual fields', () {
      final s = WorkoutSet(
        startTime: start,
        endTime: end,
        isRest: false,
        exerciseCategory: 'Squat',
        repetitions: 10,
        weightKg: 80.0,
      );
      final copy = s.copyWith(repetitions: 12, weightKg: 90.0);
      expect(copy.repetitions, 12);
      expect(copy.weightKg, 90.0);
      expect(copy.exerciseCategory, 'Squat');
      expect(copy.isRest, isFalse);
    });

    test('copyWith can change isRest and startTime/endTime', () {
      final s = WorkoutSet(startTime: start, endTime: end, isRest: false);
      final newEnd = end.add(const Duration(seconds: 30));
      final copy = s.copyWith(isRest: true, endTime: newEnd);
      expect(copy.isRest, isTrue);
      expect(copy.endTime, newEnd.toUtc());
      expect(copy.startTime, start);
    });

    group('categoryLabel', () {
      test('returns label for known values', () {
        expect(WorkoutSet.categoryLabel(0), 'Bench Press');
        expect(WorkoutSet.categoryLabel(28), 'Squat');
        expect(WorkoutSet.categoryLabel(8), 'Deadlift');
        expect(WorkoutSet.categoryLabel(17), 'Lunge');
        expect(WorkoutSet.categoryLabel(32), 'Run');
      });

      test('returns null for null input', () {
        expect(WorkoutSet.categoryLabel(null), isNull);
      });

      test('returns null for unknown values', () {
        expect(WorkoutSet.categoryLabel(999), isNull);
        expect(WorkoutSet.categoryLabel(-1), isNull);
      });

      test('covers all 33 entries (0-32)', () {
        for (var i = 0; i <= 32; i++) {
          expect(
            WorkoutSet.categoryLabel(i),
            isNotNull,
            reason: 'Missing label for category $i',
          );
        }
        expect(WorkoutSet.categoryLabel(33), isNull);
      });
    });
  });

  group('Lap swim fields', () {
    final start = DateTime.utc(2024, 1, 1, 10, 0, 0);
    final end = DateTime.utc(2024, 1, 1, 10, 5, 0);

    test('swim fields default to null', () {
      final lap = Lap(startTime: start, endTime: end);
      expect(lap.numActiveLengths, isNull);
      expect(lap.swimStroke, isNull);
    });

    test('constructor stores swim fields', () {
      final lap = Lap(
        startTime: start,
        endTime: end,
        numActiveLengths: 20,
        swimStroke: SwimStroke.freestyle,
      );
      expect(lap.numActiveLengths, 20);
      expect(lap.swimStroke, SwimStroke.freestyle);
    });

    test('copyWith propagates swim fields', () {
      final lap = Lap(startTime: start, endTime: end);
      final copy = lap.copyWith(
        numActiveLengths: 10,
        swimStroke: SwimStroke.backstroke,
      );
      expect(copy.numActiveLengths, 10);
      expect(copy.swimStroke, SwimStroke.backstroke);
    });

    test('copyWith preserves swim fields when not overridden', () {
      final lap = Lap(
        startTime: start,
        endTime: end,
        numActiveLengths: 20,
        swimStroke: SwimStroke.breaststroke,
      );
      final copy = lap.copyWith(distanceMeters: 500.0);
      expect(copy.numActiveLengths, 20);
      expect(copy.swimStroke, SwimStroke.breaststroke);
    });

    test('copyWithoutSport clears sport but keeps all other metadata', () {
      final lap = Lap(
        startTime: start,
        endTime: end,
        distanceMeters: 500.0,
        name: 'Swim leg',
        sport: Sport.swimming,
        calories: 120,
        avgHeartRate: 130,
        maxHeartRate: 150,
        event: 9,
        eventType: 1,
        numActiveLengths: 20,
        swimStroke: SwimStroke.freestyle,
      );
      final copy = lap.copyWithoutSport();
      expect(copy.sport, isNull);
      expect(copy.startTime, lap.startTime);
      expect(copy.endTime, lap.endTime);
      expect(copy.distanceMeters, 500.0);
      expect(copy.name, 'Swim leg');
      expect(copy.calories, 120);
      expect(copy.avgHeartRate, 130);
      expect(copy.maxHeartRate, 150);
      expect(copy.event, 9);
      expect(copy.eventType, 1);
      expect(copy.numActiveLengths, 20);
      expect(copy.swimStroke, SwimStroke.freestyle);
    });
  });

  group('ActivitySummary swim and fitness fields', () {
    test('swim fields default to null', () {
      const summary = ActivitySummary();
      expect(summary.poolLengthMeters, isNull);
      expect(summary.numActiveLengths, isNull);
      expect(summary.swimStroke, isNull);
      expect(summary.subSport, isNull);
      expect(summary.totalCycles, isNull);
    });

    test('constructor stores swim and fitness fields', () {
      const summary = ActivitySummary(
        poolLengthMeters: 50.0,
        numActiveLengths: 40,
        swimStroke: SwimStroke.freestyle,
        subSport: 45,
        totalCycles: 200,
      );
      expect(summary.poolLengthMeters, 50.0);
      expect(summary.numActiveLengths, 40);
      expect(summary.swimStroke, SwimStroke.freestyle);
      expect(summary.subSport, 45);
      expect(summary.totalCycles, 200);
    });

    test('copyWith propagates swim fields', () {
      const summary = ActivitySummary();
      final copy = summary.copyWith(
        poolLengthMeters: 25.0,
        numActiveLengths: 80,
        swimStroke: SwimStroke.butterfly,
        subSport: 36,
        totalCycles: 500,
      );
      expect(copy.poolLengthMeters, 25.0);
      expect(copy.numActiveLengths, 80);
      expect(copy.swimStroke, SwimStroke.butterfly);
      expect(copy.subSport, 36);
      expect(copy.totalCycles, 500);
    });

    test('copyWith preserves swim fields when not overridden', () {
      const summary = ActivitySummary(
        poolLengthMeters: 50.0,
        swimStroke: SwimStroke.im,
        numActiveLengths: 40,
      );
      final copy = summary.copyWith(calories: 300.0);
      expect(copy.poolLengthMeters, 50.0);
      expect(copy.swimStroke, SwimStroke.im);
      expect(copy.numActiveLengths, 40);
    });
  });

  group('RawActivity.sets', () {
    final base = DateTime.utc(2024, 1, 1, 10, 0, 0);

    test('sets defaults to empty list', () {
      final activity = RawActivity();
      expect(activity.sets, isEmpty);
    });

    test('sets is unmodifiable', () {
      final activity = RawActivity();
      expect(
        () => (activity.sets as List<dynamic>).add(
          WorkoutSet(
            startTime: base,
            endTime: base.add(const Duration(seconds: 30)),
            isRest: false,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('constructor stores sets', () {
      final sets = [
        WorkoutSet(
          startTime: base,
          endTime: base.add(const Duration(seconds: 45)),
          isRest: false,
          exerciseCategory: 'Squat',
          repetitions: 10,
        ),
        WorkoutSet(
          startTime: base.add(const Duration(minutes: 1)),
          endTime: base.add(const Duration(minutes: 2)),
          isRest: true,
        ),
      ];
      final activity = RawActivity(sets: sets);
      expect(activity.sets, hasLength(2));
      expect(activity.sets.first.exerciseCategory, 'Squat');
      expect(activity.sets.last.isRest, isTrue);
    });

    test('copyWith propagates sets', () {
      final original = RawActivity();
      final sets = [
        WorkoutSet(
          startTime: base,
          endTime: base.add(const Duration(seconds: 30)),
          isRest: false,
        ),
      ];
      final copy = original.copyWith(sets: sets);
      expect(copy.sets, hasLength(1));
    });

    test('copyWith preserves sets when not overridden', () {
      final sets = [
        WorkoutSet(
          startTime: base,
          endTime: base.add(const Duration(seconds: 30)),
          isRest: false,
        ),
      ];
      final activity = RawActivity(sets: sets);
      final copy = activity.copyWith(sport: Sport.running);
      expect(copy.sets, hasLength(1));
    });
  });
}
