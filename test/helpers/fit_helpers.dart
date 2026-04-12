// SPDX-License-Identifier: BSD-3-Clause
/// FIT file format test helpers.
///
/// Provides utilities for building FIT binary data, computing CRCs,
/// and encoding values in FIT format.
library;

import 'dart:typed_data';

/// Computes FIT CRC checksum for the given bytes.
int fitCrc(List<int> bytes) {
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

/// Builds a FIT file header with the given data size.
Uint8List buildFitHeader(int dataSize) {
  final header = Uint8List(14);
  final bd = ByteData.view(header.buffer);
  header[0] = 14;
  header[1] = 0x10;
  bd.setUint16(2, 0, Endian.little);
  bd.setUint32(4, dataSize, Endian.little);
  header.setRange(8, 12, '.FIT'.codeUnits);
  final crc = fitCrc(header.sublist(0, 12));
  bd.setUint16(12, crc, Endian.little);
  return header;
}

/// Encodes degrees to FIT semicircles format.
int encodeSemicircles(double degrees) {
  return ((degrees * 2147483648.0) / 180.0).round();
}

/// Builds a compressed FIT sample for testing timestamp compression.
Uint8List buildCompressedFitSample() {
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
    ...int32LE(writeInt32(encodeSemicircles(0.0))),
    ...int32LE(writeInt32(encodeSemicircles(0.0))),
  ]);

  data.add([
    0x89, // compressed header: local 0, offset 9s (~1s total delta)
    ...int32LE(writeInt32(encodeSemicircles(0.0005))),
    ...int32LE(writeInt32(encodeSemicircles(0.0005))),
  ]);

  final payload = data.toBytes();
  final header = buildFitHeader(payload.length);
  final crc = fitCrc(payload);

  return Uint8List.fromList([
    ...header,
    ...payload,
    crc & 0xFF,
    (crc >> 8) & 0xFF,
  ]);
}

/// Builds a FIT file with developer data fields for testing.
Uint8List buildFitFileWithDeveloperData() {
  final definition = BytesBuilder();
  definition
    ..add([0x40 | 0x20, 0x00, 0x00])
    ..add(uint16LeBytes(20))
    ..addByte(3)
    ..add([0xFD, 0x04, 0x86])
    ..add([0x00, 0x04, 0x85])
    ..add([0x01, 0x04, 0x85])
    ..addByte(1)
    ..add([0x01, 0x02, 0x00]);

  final record = BytesBuilder();
  record
    ..addByte(0x00)
    ..add(uint32LeBytes(1000))
    ..add(int32LeBytes(encodeSemicircles(0)))
    ..add(int32LeBytes(encodeSemicircles(0)))
    ..add([0x12, 0x34]);

  final fullDataBuilder = BytesBuilder()
    ..add(definition.toBytes())
    ..add(record.toBytes());
  final fullData = fullDataBuilder.toBytes();
  final crc = fitCrc(fullData);
  final payloadBuilder = BytesBuilder()
    ..add(fullData)
    ..addByte(crc & 0xFF)
    ..addByte((crc >> 8) & 0xFF);
  final payload = payloadBuilder.toBytes();
  final header = buildFitHeader(fullData.length);
  return Uint8List.fromList([...header, ...payload]);
}

/// Encodes a uint16 value in little-endian format.
List<int> uint16LeBytes(int value) => [value & 0xFF, (value >> 8) & 0xFF];

/// Encodes a uint32 value in little-endian format.
List<int> uint32LeBytes(int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

/// Encodes a sint32 value in little-endian format.
List<int> int32LeBytes(int value) {
  final unsigned = value & 0xFFFFFFFF;
  return uint32LeBytes(unsigned);
}

/// Encodes a UTF-16 LE string with BOM for testing encoding detection.
List<int> encodeUtf16LeWithBom(String value) {
  final encoded = <int>[0xFF, 0xFE]; // BOM
  for (final unit in value.codeUnits) {
    encoded.add(unit & 0xFF);
    encoded.add((unit >> 8) & 0xFF);
  }
  return encoded;
}

/// Dummy function for isolate computation tests.
int isolatedComputation() => 73;
