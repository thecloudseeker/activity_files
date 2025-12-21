// SPDX-License-Identifier: BSD-3-Clause
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import '../channel_mapper.dart';
import '../fit/fit_crc.dart';
import '../models.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';

/// Encoder for FIT payloads (limited profile support).
// TODO(0.7.0)(feature): Allow selecting FIT protocol/profile version when broader profile coverage is implemented.
///
/// The emitted binary stream contains the following message sequence:
/// * file_id (global 0)
/// * session (global 18) when sport metadata is available
/// * zero or more lap messages (global 19)
/// * record messages (global 20) for each geographic sample
///
/// The resulting binary is returned as base64 so that callers can safely handle
/// it using existing string-oriented APIs.
class FitEncoder implements ActivityFormatEncoder {
  const FitEncoder();
  @override
  String encode(RawActivity activity, EncoderOptions options) {
    final recordSamples = _recordSamples(activity);
    if (recordSamples.isEmpty) {
      throw ArgumentError(
        'Cannot encode FIT without geographic points or sensor samples.',
      );
    }
    final builder = BytesBuilder();
    final definitionSection = BytesBuilder();
    final dataSection = BytesBuilder();
    final encoder = _FitMessageEncoder();
    // file_id definition + data
    final fileIdLocal = 0;
    encoder.writeDefinition(
      definitionSection,
      localId: fileIdLocal,
      globalId: 0,
      fields: const [
        _FitField(number: 0, size: 1, type: _FitBaseType.enumType), // type
        _FitField(
          number: 1,
          size: 2,
          type: _FitBaseType.uint16,
        ), // manufacturer
        _FitField(number: 2, size: 2, type: _FitBaseType.uint16), // product
        _FitField(number: 3, size: 4, type: _FitBaseType.uint32z), // serial
      ],
    );
    final deviceMetadata = activity.device;
    final manufacturerId =
        deviceMetadata?.fitManufacturerId ??
        _fitManufacturerId(deviceMetadata?.manufacturer) ??
        1;
    final productId =
        deviceMetadata?.fitProductId ??
        _parseFitUint(deviceMetadata?.product) ??
        1;
    final serialNumber = _parseFitUint(deviceMetadata?.serialNumber) ?? 0;
    encoder.writeFileId(
      dataSection,
      localId: fileIdLocal,
      manufacturer: manufacturerId,
      product: productId,
      serial: serialNumber,
    );
    // Session message for sport metadata when available.
    const sessionLocal = 1;
    encoder.writeDefinition(
      definitionSection,
      localId: sessionLocal,
      globalId: 18,
      fields: const [
        _FitField(number: 253, size: 4, type: _FitBaseType.uint32), // timestamp
        _FitField(number: 5, size: 1, type: _FitBaseType.enumType), // sport
      ],
    );
    encoder.writeSession(
      dataSection,
      localId: sessionLocal,
      timestamp: recordSamples.first.time,
      sport: activity.sport,
    );
    // Lap messages (optional).
    const lapLocal = 2;
    if (activity.laps.isNotEmpty) {
      encoder.writeDefinition(
        definitionSection,
        localId: lapLocal,
        globalId: 19,
        fields: const [
          _FitField(
            number: 253,
            size: 4,
            type: _FitBaseType.uint32,
          ), // timestamp
          _FitField(
            number: 2,
            size: 4,
            type: _FitBaseType.uint32,
          ), // start_time
          _FitField(
            number: 7,
            size: 4,
            type: _FitBaseType.uint32,
          ), // total_elapsed_time (ms/1000)
          _FitField(
            number: 8,
            size: 4,
            type: _FitBaseType.uint32,
          ), // total_distance (m)
        ],
      );
      for (final lap in activity.laps) {
        encoder.writeLap(dataSection, localId: lapLocal, lap: lap);
      }
    }
    // Record definition (lat/long/altitude + main sensors).
    const recordLocal = 3;
    final recordFields = <_FitField>[
      const _FitField(number: 253, size: 4, type: _FitBaseType.uint32),
      const _FitField(number: 0, size: 4, type: _FitBaseType.sint32),
      const _FitField(number: 1, size: 4, type: _FitBaseType.sint32),
      const _FitField(number: 2, size: 2, type: _FitBaseType.uint16),
    ];
    final extraRecordFields = <int, _FitField>{
      for (final field in recordFields) field.number: field,
    };
    void addField(int fieldNum, _FitField field) {
      if (!extraRecordFields.containsKey(fieldNum)) {
        recordFields.add(field);
        extraRecordFields[fieldNum] = field;
      }
    }

    if (activity.channel(Channel.heartRate).isNotEmpty) {
      addField(
        3,
        const _FitField(number: 3, size: 1, type: _FitBaseType.uint8),
      );
    }
    if (activity.channel(Channel.cadence).isNotEmpty) {
      addField(
        4,
        const _FitField(number: 4, size: 1, type: _FitBaseType.uint8),
      );
    }
    if (activity.channel(Channel.distance).isNotEmpty) {
      addField(
        5,
        const _FitField(number: 5, size: 4, type: _FitBaseType.uint32),
      );
    }
    if (activity.channel(Channel.speed).isNotEmpty) {
      addField(
        6,
        const _FitField(number: 6, size: 2, type: _FitBaseType.uint16),
      );
    }
    if (activity.channel(Channel.power).isNotEmpty) {
      addField(
        7,
        const _FitField(number: 7, size: 2, type: _FitBaseType.uint16),
      );
    }
    if (activity.channel(Channel.temperature).isNotEmpty) {
      addField(
        13,
        const _FitField(number: 13, size: 1, type: _FitBaseType.sint8),
      );
    }
    encoder.writeDefinition(
      definitionSection,
      localId: recordLocal,
      globalId: 20,
      fields: recordFields,
    );
    final baseTime = DateTime.utc(1989, 12, 31);
    final hrTolerance = options.maxDeltaFor(Channel.heartRate);
    final cadenceTolerance = options.maxDeltaFor(Channel.cadence);
    final powerTolerance = options.maxDeltaFor(Channel.power);
    final tempTolerance = options.maxDeltaFor(Channel.temperature);
    final speedTolerance = options.maxDeltaFor(Channel.speed);
    final distanceTolerance = options.maxDeltaFor(Channel.distance);
    final searchDelta =
        [
          hrTolerance,
          cadenceTolerance,
          powerTolerance,
          tempTolerance,
          speedTolerance,
          distanceTolerance,
          options.defaultMaxDelta,
        ].fold<Duration>(
          options.defaultMaxDelta,
          (previous, current) => current > previous ? current : previous,
        );
    final channelCursor = ChannelMapper.cursor(
      activity.channels,
      maxDelta: searchDelta,
    );
    for (final sample in recordSamples) {
      final timestampSeconds = sample.time
          .toUtc()
          .difference(baseTime)
          .inSeconds;
      final lat = sample.latitude != null
          ? (sample.latitude! * 2147483648.0 / 180.0).round()
          : _invalidSemicircle;
      final lon = sample.longitude != null
          ? (sample.longitude! * 2147483648.0 / 180.0).round()
          : _invalidSemicircle;
      final altitudeRaw = _encodeAltitude(sample.elevation);
      final snapshot = channelCursor.snapshot(sample.time);
      final hr =
          snapshot.heartRateDelta != null &&
              snapshot.heartRateDelta! <= hrTolerance
          ? snapshot.heartRate
          : null;
      final cadence =
          snapshot.cadenceDelta != null &&
              snapshot.cadenceDelta! <= cadenceTolerance
          ? snapshot.cadence
          : null;
      final power =
          snapshot.powerDelta != null && snapshot.powerDelta! <= powerTolerance
          ? snapshot.power
          : null;
      final temp =
          snapshot.temperatureDelta != null &&
              snapshot.temperatureDelta! <= tempTolerance
          ? snapshot.temperature
          : null;
      final speed =
          snapshot.speedDelta != null && snapshot.speedDelta! <= speedTolerance
          ? snapshot.speed
          : null;
      encoder.writeRecord(
        dataSection,
        localId: recordLocal,
        timestampSeconds: timestampSeconds,
        latitude: lat,
        longitude: lon,
        altitudeRaw: altitudeRaw,
        hr: hr,
        cadence: cadence,
        distanceMeters: _valueWithinChannel(
          snapshot,
          Channel.distance,
          distanceTolerance,
        ),
        speed: speed,
        power: power,
        temperature: temp,
        extraFields: extraRecordFields,
      );
    }
    final dataBytes = dataSection.toBytes();
    final headerBytes = definitionSection.toBytes();
    builder.add(headerBytes);
    builder.add(dataBytes);
    final fullData = builder.toBytes();
    final crc = computeFitCrc(fullData);
    final dataWithCrc = BytesBuilder()
      ..add(fullData)
      ..addByte(crc & 0xFF)
      ..addByte((crc >> 8) & 0xFF);
    final payload = dataWithCrc.toBytes();
    final header = _createHeader(fullData.length);
    final combined = BytesBuilder()
      ..add(header)
      ..add(payload);
    return base64Encode(combined.toBytes());
  }
}

const int _invalidSemicircle = 0x7FFFFFFF;

double? _valueWithinChannel(
  ChannelSnapshot snapshot,
  Channel channel,
  Duration tolerance,
) {
  final reading = snapshot.reading(channel);
  if (reading == null) {
    return null;
  }
  return reading.delta <= tolerance ? reading.value : null;
}

int _encodeAltitude(double? elevation) {
  if (elevation == null || elevation.isNaN) {
    return 0xFFFF;
  }
  final scaled = ((elevation + 500.0) * 5.0).round();
  if (scaled < 0) {
    return 0;
  }
  if (scaled > 0xFFFF) {
    return 0xFFFF;
  }
  return scaled;
}

List<_RecordSample> _recordSamples(RawActivity activity) {
  if (activity.points.isNotEmpty) {
    return [
      for (final point in activity.points)
        _RecordSample(
          time: point.time,
          latitude: point.latitude,
          longitude: point.longitude,
          elevation: point.elevation,
        ),
    ];
  }
  final timestamps = SplayTreeSet<DateTime>();
  for (final series in activity.channels.values) {
    for (final sample in series) {
      timestamps.add(sample.time);
    }
  }
  if (timestamps.isEmpty) {
    return const <_RecordSample>[];
  }
  return [for (final time in timestamps) _RecordSample(time: time)];
}

class _RecordSample {
  const _RecordSample({
    required this.time,
    this.latitude,
    this.longitude,
    this.elevation,
  });

  final DateTime time;
  final double? latitude;
  final double? longitude;
  final double? elevation;
}

Uint8List _createHeader(int dataSize) {
  final header = Uint8List(14);
  final bd = header.buffer.asByteData();
  header[0] = 14; // header size
  header[1] = 0x10; // protocol version 1.0
  bd.setUint16(2, 0, Endian.little); // profile version unknown
  bd.setUint32(4, dataSize, Endian.little);
  header.setRange(8, 12, '.FIT'.codeUnits);
  final crc = computeFitCrc(header, length: 12);
  bd.setUint16(12, crc, Endian.little);
  return header;
}

int? _fitManufacturerId(String? name) {
  if (name == null) {
    return null;
  }
  final normalized = name.trim().toLowerCase();
  if (normalized.isEmpty) {
    return null;
  }
  for (final entry in fitManufacturerNames.entries) {
    if (entry.value.toLowerCase() == normalized) {
      return entry.key;
    }
  }
  return int.tryParse(normalized);
}

int? _parseFitUint(String? value) {
  if (value == null) {
    return null;
  }
  return int.tryParse(value.trim());
}

class _FitMessageEncoder {
  void writeDefinition(
    BytesBuilder destination, {
    required int localId,
    required int globalId,
    required List<_FitField> fields,
  }) {
    destination.addByte(0x40 | (localId & 0x0F));
    destination.addByte(0); // reserved
    destination.addByte(0); // little-endian architecture
    final bd = ByteData(2)..setUint16(0, globalId, Endian.little);
    destination.add(bd.buffer.asUint8List());
    destination.addByte(fields.length);
    for (final field in fields) {
      destination.add(field.encode());
    }
  }

  void writeFileId(
    BytesBuilder destination, {
    required int localId,
    required int manufacturer,
    required int product,
    required int serial,
  }) {
    destination.addByte(localId);
    destination.addByte(4); // file type activity
    final bd = ByteData(8);
    bd.setUint16(0, manufacturer, Endian.little);
    bd.setUint16(2, product, Endian.little);
    bd.setUint32(4, serial, Endian.little);
    destination.add(bd.buffer.asUint8List());
  }

  void writeSession(
    BytesBuilder destination, {
    required int localId,
    required DateTime timestamp,
    required Sport sport,
  }) {
    destination.addByte(localId);
    final base = DateTime.utc(1989, 12, 31);
    final seconds = timestamp.toUtc().difference(base).inSeconds;
    final bd = ByteData(5);
    bd.setUint32(0, seconds, Endian.little);
    bd.setUint8(4, _encodeSport(sport));
    destination.add(bd.buffer.asUint8List());
  }

  void writeLap(
    BytesBuilder destination, {
    required int localId,
    required Lap lap,
  }) {
    destination.addByte(localId);
    final base = DateTime.utc(1989, 12, 31);
    final timestamp = lap.endTime.toUtc().difference(base).inSeconds;
    final start = lap.startTime.toUtc().difference(base).inSeconds;
    final elapsed = lap.elapsed.inMilliseconds / 1000.0;
    final distance = lap.distanceMeters ?? 0.0;
    final bd = ByteData(16);
    bd.setUint32(0, timestamp, Endian.little);
    bd.setUint32(4, start, Endian.little);
    bd.setUint32(8, (elapsed * 1000).round(), Endian.little);
    bd.setUint32(12, distance.round(), Endian.little);
    destination.add(bd.buffer.asUint8List());
  }

  void writeRecord(
    BytesBuilder destination, {
    required int localId,
    required int timestampSeconds,
    required int latitude,
    required int longitude,
    required int altitudeRaw,
    double? hr,
    double? cadence,
    double? distanceMeters,
    double? speed,
    double? power,
    double? temperature,
    required Map<int, _FitField> extraFields,
  }) {
    destination.addByte(localId);
    final bd = ByteData(12);
    bd.setUint32(0, timestampSeconds, Endian.little);
    bd.setInt32(4, latitude, Endian.little);
    bd.setInt32(8, longitude, Endian.little);
    destination.add(bd.buffer.asUint8List());
    final altData = ByteData(2)..setUint16(0, altitudeRaw, Endian.little);
    destination.add(altData.buffer.asUint8List());
    void writeOptional(int fieldNumber, void Function() body) {
      if (extraFields.containsKey(fieldNumber)) {
        body();
      }
    }

    writeOptional(3, () {
      destination.addByte(hr != null ? hr.round().clamp(0, 255) : 0xFF);
    });
    writeOptional(4, () {
      destination.addByte(
        cadence != null ? cadence.round().clamp(0, 255) : 0xFF,
      );
    });
    writeOptional(5, () {
      final rawValue = distanceMeters;
      final bd = ByteData(4);
      if (rawValue == null) {
        bd.setUint32(0, 0xFFFFFFFF, Endian.little);
      } else {
        final scaled = (rawValue * 100).round();
        bd.setUint32(0, _clampUint32(scaled), Endian.little);
      }
      destination.add(bd.buffer.asUint8List());
    });
    writeOptional(6, () {
      final bd = ByteData(2);
      if (speed == null) {
        bd.setUint16(0, 0xFFFF, Endian.little);
      } else {
        final scaled = (speed * 1000).round();
        bd.setUint16(0, _clampUint16(scaled), Endian.little);
      }
      destination.add(bd.buffer.asUint8List());
    });
    writeOptional(7, () {
      final bd = ByteData(2);
      if (power == null) {
        bd.setUint16(0, 0xFFFF, Endian.little);
      } else {
        bd.setUint16(0, _clampUint16(power.round()), Endian.little);
      }
      destination.add(bd.buffer.asUint8List());
    });
    writeOptional(13, () {
      final bd = ByteData(1);
      if (temperature == null) {
        bd.setInt8(0, 0x7F);
      } else {
        bd.setInt8(0, temperature.round().clamp(-128, 127));
      }
      destination.add(bd.buffer.asUint8List());
    });
  }

  int _encodeSport(Sport sport) {
    switch (sport) {
      case Sport.running:
        return 0;
      case Sport.cycling:
        return 1;
      case Sport.swimming:
        return 2;
      case Sport.walking:
        return 11;
      default:
        return 3; // other
    }
  }
}

class _FitField {
  const _FitField({
    required this.number,
    required this.size,
    required this.type,
  });
  final int number;
  final int size;
  final _FitBaseType type;
  Uint8List encode() {
    return Uint8List.fromList([number, size, type.code]);
  }
}

enum _FitBaseType {
  enumType(0x00),
  sint8(0x01),
  uint8(0x02),
  uint16(0x84),
  sint32(0x85),
  uint32(0x86),
  uint32z(0x8C);

  const _FitBaseType(this.code);
  final int code;
}

int _clampUint16(int value) =>
    value < 0 ? 0 : (value > 0xFFFF ? 0xFFFF : value);
int _clampUint32(int value) =>
    value < 0 ? 0 : (value > 0xFFFFFFFF ? 0xFFFFFFFF : value);
