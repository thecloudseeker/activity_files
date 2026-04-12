// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for format conversion and interoperability.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/builders.dart';
import '../fixtures/sample_data.dart';

void main() {
  const encoderOptions = EncoderOptions(
    defaultMaxDelta: Duration(seconds: 3),
    precisionLatLon: 6,
    precisionEle: 2,
  );

  group('Format interop', () {
    test('GPX → Raw → TCX preserves HR and cadence', () {
      final gpxResult = ActivityParser.parse(sampleGpx, ActivityFileFormat.gpx);
      expect(gpxResult.warningDiagnostics, isEmpty);
      final activity = gpxResult.activity;

      final tcxString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.tcx,
        options: encoderOptions,
      );

      final tcxResult = ActivityParser.parse(tcxString, ActivityFileFormat.tcx);
      expect(tcxResult.warningDiagnostics, isEmpty);

      final tolerance = encoderOptions.defaultMaxDelta;
      final targetHr = activity.channel(Channel.heartRate);
      final roundHr = tcxResult.activity.channel(Channel.heartRate);
      for (final sample in targetHr) {
        expect(_hasMatchingSample(roundHr, sample, tolerance), isTrue);
      }

      final targetCad = activity.channel(Channel.cadence);
      final roundCad = tcxResult.activity.channel(Channel.cadence);
      for (final sample in targetCad) {
        expect(_hasMatchingSample(roundCad, sample, tolerance), isTrue);
      }
    });

    test('TCX → Raw → GPX preserves HR and cadence extensions', () {
      final tcxResult = ActivityParser.parse(sampleTcx, ActivityFileFormat.tcx);
      expect(tcxResult.warningDiagnostics, isEmpty);

      final gpx = ActivityEncoder.encode(
        tcxResult.activity,
        ActivityFileFormat.gpx,
        options: encoderOptions,
      );

      final gpxResult = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
      expect(gpxResult.warningDiagnostics, isEmpty);

      final originalHr = tcxResult.activity.channel(Channel.heartRate);
      final roundHr = gpxResult.activity.channel(Channel.heartRate);
      final originalCad = tcxResult.activity.channel(Channel.cadence);
      final roundCad = gpxResult.activity.channel(Channel.cadence);

      expect(
        roundHr.map((s) => s.value.round()),
        orderedEquals(originalHr.map((s) => s.value.round())),
      );
      expect(
        roundCad.map((s) => s.value.round()),
        orderedEquals(originalCad.map((s) => s.value.round())),
      );
    });

    test('FIT encode → parse round trip', () {
      final activity = buildSampleActivity();

      final fitString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      expect(fitString, isNotEmpty);

      final parsed = ActivityParser.parse(fitString, ActivityFileFormat.fit);
      expect(parsed.warningDiagnostics, isEmpty);
      expect(parsed.activity.points.length, activity.points.length);
      expect(
        parsed.activity.channel(Channel.heartRate).map((s) => s.value.round()),
        orderedEquals(
          activity.channel(Channel.heartRate).map((s) => s.value.round()),
        ),
      );
      expect(
        parsed.activity.channel(Channel.distance).last.value,
        closeTo(activity.channel(Channel.distance).last.value, 0.05),
      );
      final parsedSpeeds = parsed.activity
          .channel(Channel.speed)
          .map((s) => s.value)
          .toList();
      final originalSpeeds = activity
          .channel(Channel.speed)
          .map((s) => s.value)
          .toList();
      expect(parsedSpeeds.length, originalSpeeds.length);
      for (var i = 0; i < originalSpeeds.length; i++) {
        expect(parsedSpeeds[i], closeTo(originalSpeeds[i], 0.5));
      }
      expect(parsed.activity.sport, equals(Sport.cycling));
    });

    test('FIT encoder supports sensor-only activities', () {
      final start = DateTime.utc(2024, 2, 1, 6);
      final hrSamples = [
        Sample(time: start, value: 95),
        Sample(time: start.add(const Duration(seconds: 30)), value: 100),
        Sample(time: start.add(const Duration(minutes: 1)), value: 105),
      ];
      final activity = RawActivity(
        channels: {Channel.heartRate: hrSamples},
        sport: Sport.running,
      );

      final fitString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );

      final parsed = ActivityParser.parse(fitString, ActivityFileFormat.fit);

      expect(parsed.activity.points, isEmpty);
      final parsedHr = parsed.activity.channel(Channel.heartRate);
      expect(parsedHr.length, equals(hrSamples.length));
      expect(
        parsedHr.map((sample) => sample.value.round()),
        orderedEquals(hrSamples.map((sample) => sample.value.round())),
      );
    });

    test('FIT binary payload obeys header and CRC', () {
      final activity = buildSampleActivity();
      final fitString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );

      final bytes = base64Decode(fitString);
      expect(bytes.length, greaterThan(20));
      final headerSize = bytes[0];
      expect(headerSize, equals(14));
      final byteData = ByteData.sublistView(Uint8List.fromList(bytes));
      final dataSize = byteData.getUint32(4, Endian.little);
      expect(headerSize + dataSize + 2, equals(bytes.length));

      final payload = bytes.sublist(headerSize);
      final storedCrc =
          payload[payload.length - 2] | (payload[payload.length - 1] << 8);
      final computedCrc = _fitCrc(payload.sublist(0, payload.length - 2));
      expect(storedCrc, equals(computedCrc));
    });

    test('FIT parser reports trailer CRC mismatches', () {
      final activity = buildSampleActivity();
      final fitBytes = base64Decode(
        ActivityEncoder.encode(activity, ActivityFileFormat.fit),
      );
      final tampered = Uint8List.fromList(fitBytes);
      tampered[tampered.length - 1] ^= 0xFF;

      final result = ActivityParser.parseBytes(
        tampered,
        ActivityFileFormat.fit,
      );

      expect(
        result.diagnostics.where(
          (diagnostic) => diagnostic.code == 'fit.trailer.crc_mismatch',
        ),
        isNotEmpty,
      );
    });

    test('FIT parser warns when trailer is truncated', () {
      final activity = buildSampleActivity();
      final fitBytes = base64Decode(
        ActivityEncoder.encode(activity, ActivityFileFormat.fit),
      );
      final truncated = Uint8List.fromList(
        fitBytes.sublist(0, fitBytes.length - 2),
      );

      final result = ActivityParser.parseBytes(
        truncated,
        ActivityFileFormat.fit,
      );

      expect(
        result.diagnostics.where(
          (diagnostic) => diagnostic.code == 'fit.trailer.truncated',
        ),
        isNotEmpty,
      );
    });

    test('FIT raw round-trip preserves serialization', () {
      final activity = buildSampleActivity();
      final firstFit = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      final parsed = ActivityParser.parse(firstFit, ActivityFileFormat.fit);
      expect(parsed.warningDiagnostics, isEmpty);

      final secondFit = ActivityEncoder.encode(
        parsed.activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );

      final firstBytes = base64Decode(firstFit);
      final secondBytes = base64Decode(secondFit);
      expect(secondBytes.length, equals(firstBytes.length));

      final secondParsed = ActivityParser.parse(
        secondFit,
        ActivityFileFormat.fit,
      ).activity;
      expect(secondParsed.points.length, activity.points.length);
      expect(
        secondParsed.channel(Channel.power).map((s) => s.value.round()),
        orderedEquals(
          activity.channel(Channel.power).map((s) => s.value.round()),
        ),
      );
      expect(
        secondParsed.channel(Channel.temperature).map((s) => s.value.round()),
        orderedEquals(
          activity.channel(Channel.temperature).map((s) => s.value.round()),
        ),
      );
    });

    test('GPX round-trip retains point count and timestamps', () {
      final parseResult = ActivityParser.parse(
        sampleGpx,
        ActivityFileFormat.gpx,
      );
      final encoded = ActivityEncoder.encode(
        parseResult.activity,
        ActivityFileFormat.gpx,
        options: encoderOptions,
      );
      final roundTrip = ActivityParser.parse(encoded, ActivityFileFormat.gpx);

      final originalTimes = parseResult.activity.points
          .map((p) => p.time)
          .toList();
      final newTimes = roundTrip.activity.points.map((p) => p.time).toList();
      expect(newTimes.length, originalTimes.length);
      expect(newTimes, orderedEquals(originalTimes));
    });

    test('FIT compressed headers parsed from raw bytes', () {
      final bytes = _buildCompressedFitSample();
      final result = ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      expect(result.warningDiagnostics, isEmpty);

      final points = result.activity.points;
      expect(points.length, equals(2));

      final base = DateTime.utc(1989, 12, 31);
      expect(
        points.first.time,
        equals(base.add(const Duration(seconds: 1000))),
      );
      expect(points.last.time, equals(base.add(const Duration(seconds: 1001))));

      expect(points.first.latitude, closeTo(0.0, 1e-6));
      expect(points.last.latitude, closeTo(0.0005, 1e-6));
    });
  });
}

// Helper functions

bool _hasMatchingSample(
  List<Sample> samples,
  Sample target,
  Duration tolerance,
) {
  final targetMicros = target.time.microsecondsSinceEpoch;
  final limit = tolerance.inMicroseconds;
  for (final sample in samples) {
    final delta = (sample.time.microsecondsSinceEpoch - targetMicros).abs();
    if (delta <= limit && (sample.value - target.value).abs() < 0.5) {
      return true;
    }
  }
  return false;
}

int _fitCrc(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    var tmp = _fitCrcTable[crc & 0x0F];
    crc = (crc >> 4) & 0x0FFF;
    crc ^= tmp ^ _fitCrcTable[byte & 0x0F];
    tmp = _fitCrcTable[crc & 0x0F];
    crc = (crc >> 4) & 0x0FFF;
    crc ^= tmp ^ _fitCrcTable[(byte >> 4) & 0x0F];
  }
  return crc & 0xFFFF;
}

const List<int> _fitCrcTable = [
  0x0000,
  0xCC01,
  0xD801,
  0x1400,
  0xF001,
  0x3C00,
  0x2800,
  0xE401,
  0xA001,
  0x6C00,
  0x7800,
  0xB401,
  0x5000,
  0x9C01,
  0x8801,
  0x4400,
];

Uint8List _buildCompressedFitSample() {
  final data = BytesBuilder();
  data.add([
    0x40, // definition header for local message 0
    0x00, // reserved
    0x00, // little-endian architecture
    0x14,
    0x00, // global message 20 (record)
    0x03, // field count
    0xFD,
    0x04,
    0x86, // timestamp (uint32)
    0x00,
    0x04,
    0x85, // latitude (sint32)
    0x01,
    0x04,
    0x85, // longitude (sint32)
  ]);

  int writeInt32(int value) => value & 0xFFFFFFFF;
  List<int> int32LE(int value) => [
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ];

  const timestamp = 1000;
  data.add([
    0x00, // data message header (local 0)
    ...int32LE(timestamp),
    ...int32LE(writeInt32(_encodeSemicircles(0.0))),
    ...int32LE(writeInt32(_encodeSemicircles(0.0))),
  ]);

  data.add([
    0x89, // compressed header: local 0, offset 9s (~1s total delta)
    ...int32LE(writeInt32(_encodeSemicircles(0.0005))),
    ...int32LE(writeInt32(_encodeSemicircles(0.0005))),
  ]);

  final payload = data.toBytes();
  final header = _buildFitHeader(payload.length);
  final crc = _fitCrc(payload);

  return Uint8List.fromList([
    ...header,
    ...payload,
    crc & 0xFF,
    (crc >> 8) & 0xFF,
  ]);
}

Uint8List _buildFitHeader(int dataSize) {
  final header = Uint8List(14);
  final bd = ByteData.view(header.buffer);
  header[0] = 14;
  header[1] = 0x10;
  bd.setUint16(2, 0, Endian.little);
  bd.setUint32(4, dataSize, Endian.little);
  header.setRange(8, 12, '.FIT'.codeUnits);
  final crc = _fitCrc(header.sublist(0, 12));
  bd.setUint16(12, crc, Endian.little);
  return header;
}

int _encodeSemicircles(double degrees) {
  return ((degrees * 2147483648.0) / 180.0).round();
}
