// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  const encoderOptions = EncoderOptions(
    defaultMaxDelta: Duration(seconds: 3),
    precisionLatLon: 6,
    precisionEle: 2,
  );

  group('Format interop', () {
    test('GPX → Raw → TCX preserves HR and cadence', () {
      final gpxResult =
          ActivityParser.parse(_sampleGpx, ActivityFileFormat.gpx);
      expect(gpxResult.warnings, isEmpty);
      final activity = gpxResult.activity;

      final tcxString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.tcx,
        options: encoderOptions,
      );

      final tcxResult = ActivityParser.parse(tcxString, ActivityFileFormat.tcx);
      expect(tcxResult.warnings, isEmpty);

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
      final tcxResult =
          ActivityParser.parse(_sampleTcx, ActivityFileFormat.tcx);
      expect(tcxResult.warnings, isEmpty);

      final gpx = ActivityEncoder.encode(
        tcxResult.activity,
        ActivityFileFormat.gpx,
        options: encoderOptions,
      );

      final gpxResult = ActivityParser.parse(gpx, ActivityFileFormat.gpx);
      expect(gpxResult.warnings, isEmpty);

      final originalHr = tcxResult.activity.channel(Channel.heartRate);
      final roundHr = gpxResult.activity.channel(Channel.heartRate);
      final originalCad = tcxResult.activity.channel(Channel.cadence);
      final roundCad = gpxResult.activity.channel(Channel.cadence);

      expect(roundHr.map((s) => s.value.round()),
          orderedEquals(originalHr.map((s) => s.value.round())));
      expect(roundCad.map((s) => s.value.round()),
          orderedEquals(originalCad.map((s) => s.value.round())));
    });

    test('FIT encode → parse round trip', () {
      final activity = _buildSampleActivity();

      final fitString = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      expect(fitString, isNotEmpty);

      final parsed = ActivityParser.parse(fitString, ActivityFileFormat.fit);
      expect(parsed.warnings, isEmpty);
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
      final parsedSpeeds =
          parsed.activity.channel(Channel.speed).map((s) => s.value).toList();
      final originalSpeeds =
          activity.channel(Channel.speed).map((s) => s.value).toList();
      expect(parsedSpeeds.length, originalSpeeds.length);
      for (var i = 0; i < originalSpeeds.length; i++) {
        expect(parsedSpeeds[i], closeTo(originalSpeeds[i], 0.5));
      }
      expect(parsed.activity.sport, equals(Sport.cycling));
    });

    test('FIT binary payload obeys header and CRC', () {
      final activity = _buildSampleActivity();
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

    test('FIT raw round-trip preserves serialization', () {
      final activity = _buildSampleActivity();
      final firstFit = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      final parsed = ActivityParser.parse(firstFit, ActivityFileFormat.fit);
      expect(parsed.warnings, isEmpty);

      final secondFit = ActivityEncoder.encode(
        parsed.activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );

      final firstBytes = base64Decode(firstFit);
      final secondBytes = base64Decode(secondFit);
      expect(secondBytes.length, equals(firstBytes.length));

      final secondParsed =
          ActivityParser.parse(secondFit, ActivityFileFormat.fit).activity;
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
      final parseResult =
          ActivityParser.parse(_sampleGpx, ActivityFileFormat.gpx);
      final encoded = ActivityEncoder.encode(
        parseResult.activity,
        ActivityFileFormat.gpx,
        options: encoderOptions,
      );
      final roundTrip = ActivityParser.parse(encoded, ActivityFileFormat.gpx);

      final originalTimes =
          parseResult.activity.points.map((p) => p.time).toList();
      final newTimes = roundTrip.activity.points.map((p) => p.time).toList();
      expect(newTimes.length, originalTimes.length);
      expect(newTimes, orderedEquals(originalTimes));
    });

    test('FIT compressed headers parsed from raw bytes', () {
      final bytes = _buildCompressedFitSample();
      final result =
          ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

      expect(result.warnings, isEmpty);

      final points = result.activity.points;
      expect(points.length, equals(2));

      final base = DateTime.utc(1989, 12, 31);
      expect(points.first.time, equals(base.add(const Duration(seconds: 1000))));
      expect(points.last.time,
          equals(base.add(const Duration(seconds: 1001))));

      expect(points.first.latitude, closeTo(0.0, 1e-6));
      expect(points.last.latitude, closeTo(0.0005, 1e-6));
    });
  });

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
        (index) => Sample(
          time: points[index].time,
          value: 140 + index.toDouble(),
        ),
      );
      final activity = RawActivity(
        points: points,
        channels: {Channel.heartRate: hr},
      );

      final cropped = RawEditor(activity)
          .crop(start.add(const Duration(seconds: 10)),
              start.add(const Duration(seconds: 40)))
          .activity;
      expect(cropped.points.length, 4);

      final downsampled = RawEditor(activity)
          .downsampleTime(const Duration(seconds: 20))
          .activity;
      expect(downsampled.points.length, lessThan(activity.points.length));

      final resampled =
          RawTransforms.resample(activity, step: const Duration(seconds: 5));
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
  });

  group('Validation', () {
    test('flags duplicates and coordinate issues', () {
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

      final result =
          validateRawActivity(invalid, gapWarningThreshold: Duration.zero);
      expect(result.errors.length, greaterThanOrEqualTo(3));
    });

    test('reports large gaps as warnings', () {
      final time = DateTime.utc(2024, 1, 1, 12);
      final activity = RawActivity(
        points: [
          GeoPoint(latitude: 40, longitude: -105, time: time),
          GeoPoint(
              latitude: 40.01,
              longitude: -105.01,
              time: time.add(const Duration(minutes: 10))),
        ],
      );

      final result = validateRawActivity(activity,
          gapWarningThreshold: const Duration(seconds: 60));
      expect(result.errors, isEmpty);
      expect(result.warnings, isNotEmpty);
    });
  });
}

RawActivity _buildSampleActivity() {
  final baseTime = DateTime.utc(2024, 4, 1, 6);
  final points = [
    GeoPoint(
        latitude: 40.0, longitude: -105.0, elevation: 1600, time: baseTime),
    GeoPoint(
      latitude: 40.0005,
      longitude: -105.0005,
      elevation: 1601,
      time: baseTime.add(const Duration(seconds: 5)),
    ),
    GeoPoint(
      latitude: 40.0010,
      longitude: -105.0010,
      elevation: 1602,
      time: baseTime.add(const Duration(seconds: 10)),
    ),
  ];
  final hr = [
    Sample(time: points[0].time, value: 140),
    Sample(time: points[1].time, value: 142),
    Sample(time: points[2].time, value: 145),
  ];
  final cadence = [
    Sample(time: points[0].time, value: 80),
    Sample(time: points[1].time, value: 82),
    Sample(time: points[2].time, value: 84),
  ];
  final power = [
    Sample(time: points[0].time, value: 200),
    Sample(time: points[1].time, value: 210),
    Sample(time: points[2].time, value: 220),
  ];
  final temperature = [
    Sample(time: points[0].time, value: 21),
    Sample(time: points[1].time, value: 22),
    Sample(time: points[2].time, value: 23),
  ];

  final baseActivity = RawActivity(
    points: points,
    channels: {
      Channel.heartRate: hr,
      Channel.cadence: cadence,
      Channel.power: power,
      Channel.temperature: temperature,
    },
    laps: [
      Lap(
        startTime: points.first.time,
        endTime: points.last.time,
        distanceMeters: 150,
      ),
    ],
    sport: Sport.cycling,
    creator: 'unit-test device',
  );

  final result = RawTransforms.computeCumulativeDistance(baseActivity);
  final withDistance = result.activity;
  final withSpeed =
      RawEditor(withDistance).recomputeDistanceAndSpeed().activity;
  return withSpeed;
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

bool _hasMatchingSample(
    List<Sample> samples, Sample target, Duration tolerance) {
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

const String _sampleGpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="TestDevice"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <trk>
    <name>Sample Run</name>
    <type>Running</type>
    <trkseg>
      <trkpt lat="40.000000" lon="-105.000000">
        <ele>1600.0</ele>
        <time>2024-03-01T10:00:00Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>140</gpxtpx:hr>
            <gpxtpx:cad>82</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="40.000500" lon="-105.000500">
        <ele>1601.0</ele>
        <time>2024-03-01T10:00:10Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>142</gpxtpx:hr>
            <gpxtpx:cad>84</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
      <trkpt lat="40.001000" lon="-105.001000">
        <ele>1602.0</ele>
        <time>2024-03-01T10:00:20Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:hr>145</gpxtpx:hr>
            <gpxtpx:cad>86</gpxtpx:cad>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
''';

const String _sampleTcx = '''
<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2024-03-01T10:00:00Z</Id>
      <Lap StartTime="2024-03-01T10:00:00Z">
        <TotalTimeSeconds>20.0</TotalTimeSeconds>
        <DistanceMeters>140.0</DistanceMeters>
        <Track>
          <Trackpoint>
            <Time>2024-03-01T10:00:00Z</Time>
            <Position>
              <LatitudeDegrees>40.000000</LatitudeDegrees>
              <LongitudeDegrees>-105.000000</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1600.0</AltitudeMeters>
            <DistanceMeters>0.0</DistanceMeters>
            <HeartRateBpm>
              <Value>140</Value>
            </HeartRateBpm>
            <Cadence>82</Cadence>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-03-01T10:00:10Z</Time>
            <Position>
              <LatitudeDegrees>40.000500</LatitudeDegrees>
              <LongitudeDegrees>-105.000500</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1601.0</AltitudeMeters>
            <DistanceMeters>70.0</DistanceMeters>
            <HeartRateBpm>
              <Value>142</Value>
            </HeartRateBpm>
            <Cadence>84</Cadence>
          </Trackpoint>
          <Trackpoint>
            <Time>2024-03-01T10:00:20Z</Time>
            <Position>
              <LatitudeDegrees>40.001000</LatitudeDegrees>
              <LongitudeDegrees>-105.001000</LongitudeDegrees>
            </Position>
            <AltitudeMeters>1602.0</AltitudeMeters>
            <DistanceMeters>140.0</DistanceMeters>
            <HeartRateBpm>
              <Value>145</Value>
            </HeartRateBpm>
            <Cadence>86</Cadence>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
''';
