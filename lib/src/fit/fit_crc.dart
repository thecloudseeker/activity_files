// SPDX-License-Identifier: BSD-3-Clause

/// Computes the FIT CRC over [bytes], returning a 16-bit checksum.
///
/// The optional [offset] and [length] arguments allow callers to hash a slice
/// within [bytes] without allocating intermediate buffers.
int computeFitCrc(List<int> bytes, {int offset = 0, int? length}) {
  if (offset < 0 || offset > bytes.length) {
    throw RangeError.range(offset, 0, bytes.length, 'offset');
  }
  final span = length ?? (bytes.length - offset);
  if (span < 0 || offset + span > bytes.length) {
    throw RangeError.range(span, 0, bytes.length - offset, 'length');
  }
  var crc = 0;
  final end = offset + span;
  for (var i = offset; i < end; i++) {
    final byte = bytes[i] & 0xFF;
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
