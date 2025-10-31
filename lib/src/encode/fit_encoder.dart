// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:typed_data';
import '../channel_mapper.dart';
import '../models.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';

/// Encoder for FIT payloads (limited profile support).
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
    if (activity.points.isEmpty) {
      throw ArgumentError('Cannot encode FIT without geographic points.');
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
    encoder.writeFileId(
      dataSection,
      localId: fileIdLocal,
      manufacturer: 1,
      product: 1,
      serial: 0,
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
      timestamp: activity.points.first.time,
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
    final channelMap = activity.channels.map(
      (key, value) => MapEntry(key, List<Sample>.from(value)),
    );
    for (final point in activity.points) {
      final timestampSeconds = point.time
          .toUtc()
          .difference(baseTime)
          .inSeconds;
      final lat = (point.latitude * 2147483648.0 / 180.0).round();
      final lon = (point.longitude * 2147483648.0 / 180.0).round();
      final altitudeRaw = ((point.elevation ?? 0) + 500.0) * 5.0;
      final snapshot = ChannelMapper.mapAt(
        point.time,
        channelMap,
        maxDelta: options.defaultMaxDelta,
      );
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
        altitudeRaw: altitudeRaw.round(),
        hr: hr,
        cadence: cadence,
        distanceMeters: channelMap.containsKey(Channel.distance)
            ? _lookupSample(channelMap[Channel.distance], point.time)
            : null,
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
    final crc = _computeFitCrc(fullData);
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

double? _lookupSample(List<Sample>? samples, DateTime timestamp) {
  if (samples == null || samples.isEmpty) {
    return null;
  }
  final target = timestamp.toUtc();
  Sample? nearest;
  int best = 1 << 62;
  for (final sample in samples) {
    final delta = sample.time.toUtc().difference(target).inMicroseconds.abs();
    if (delta < best) {
      best = delta;
      nearest = sample;
    }
  }
  return nearest?.value;
}

Uint8List _createHeader(int dataSize) {
  final header = Uint8List(14);
  final bd = header.buffer.asByteData();
  header[0] = 14; // header size
  header[1] = 0x10; // protocol version 1.0
  bd.setUint16(2, 0, Endian.little); // profile version unknown
  bd.setUint32(4, dataSize, Endian.little);
  header.setRange(8, 12, '.FIT'.codeUnits);
  final crc = _computeFitCrc(header.sublist(0, 12));
  bd.setUint16(12, crc, Endian.little);
  return header;
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
int _computeFitCrc(List<int> bytes) {
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
