// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:typed_data';
import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

/// Parser for FIT binary payloads (limited profile support).
///
/// The decoder focuses on the subset of the FIT profile required to populate
/// the unified [RawActivity] model: geographic points, heart-rate/cadence/power
/// channels, laps, and high level sport metadata. Unsupported constructs are
/// skipped with warnings rather than raising hard errors.
class FitParser implements ActivityFormatParser {
  const FitParser();

  @override
  ActivityParseResult parse(String input) {
    final diagnostics = <ParseDiagnostic>[];
    final payload = _decodePayload(input.trim(), diagnostics);
    return _parsePayload(payload, diagnostics);
  }

  ActivityParseResult parseBytes(Uint8List payload) {
    return _parsePayload(payload, <ParseDiagnostic>[]);
  }

  ActivityParseResult _parsePayload(
    Uint8List payload,
    List<ParseDiagnostic> diagnostics,
  ) {
    final reader = _FitByteReader(payload);
    final header = _FitHeader.tryRead(reader);
    if (header == null) {
      throw FormatException('Invalid FIT header.');
    }
    if (header.dataType != '.FIT') {
      throw FormatException('Unsupported FIT file type: ${header.dataType}');
    }
    final definitions = <int, _FitMessageDefinition>{};
    final lastTimestamps = <int, int>{};
    final points = <GeoPoint>[];
    final hrSamples = <Sample>[];
    final cadenceSamples = <Sample>[];
    final powerSamples = <Sample>[];
    final tempSamples = <Sample>[];
    final speedSamples = <Sample>[];
    final distanceSamples = <Sample>[];
    final laps = <Lap>[];
    Sport sport = Sport.unknown;
    String? creator;
    ActivityDeviceMetadata? deviceMetadata;
    final dataLimit = header.headerSize + header.dataSize;
    if (dataLimit > payload.length) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'fit.header.size_mismatch',
          message: 'FIT header advertises data larger than available payload.',
          node: const ParseNodeReference(path: 'fit.header'),
        ),
      );
    }
    reader.position = header.headerSize;
    while (reader.position < payload.length && reader.position < dataLimit) {
      final recordHeader = reader.readUint8();
      final isCompressed = (recordHeader & 0x80) != 0;
      final isDefinition = !isCompressed && (recordHeader & 0x40) != 0;
      final hasDeveloper = !isCompressed && (recordHeader & 0x20) != 0;
      var localType = recordHeader & 0x0F;
      int? compressedTimestamp;
      if (isCompressed) {
        localType = (recordHeader >> 5) & 0x03;
        final offset = recordHeader & 0x1F;
        final previous = lastTimestamps[localType];
        if (previous == null) {
          final definition = definitions[localType];
          diagnostics.add(
            ParseDiagnostic(
              severity: ParseSeverity.warning,
              code: 'fit.compressed_header.missing_timestamp',
              message:
                  'Encountered compressed header for local message $localType without prior timestamp; skipping.',
              node: ParseNodeReference(
                path: 'fit.message',
                description: 'localType=$localType',
              ),
            ),
          );
          if (definition != null) {
            reader.skip(definition.dataSize(compressedTimestamp: true));
          } else {
            reader.skipRemaining(dataLimit - reader.position);
            break;
          }
          continue;
        }
        compressedTimestamp = _applyCompressedTimestamp(previous, offset);
      }
      if (isDefinition) {
        final definition = _FitMessageDefinition.read(
          reader,
          localType,
          hasDeveloper: hasDeveloper,
        );
        if (definition != null) {
          definitions[localType] = definition;
        } else {
          diagnostics.add(
            ParseDiagnostic(
              severity: ParseSeverity.warning,
              code: 'fit.definition.malformed',
              message: 'Malformed FIT definition message skipped.',
              node: ParseNodeReference(
                path: 'fit.definition',
                description: 'localType=$localType',
              ),
            ),
          );
        }
        continue;
      }
      final definition = definitions[localType];
      if (definition == null) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.warning,
            code: 'fit.definition.missing',
            message:
                'Data message references unknown definition #$localType; aborting parse.',
            node: ParseNodeReference(
              path: 'fit.message',
              description: 'localType=$localType',
            ),
          ),
        );
        reader.skipRemaining(dataLimit - reader.position);
        break;
      }
      final values = definition.readValues(
        reader,
        compressedTimestamp: isCompressed,
      );
      if (values == null) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.warning,
            code: 'fit.data.read_failed',
            message: 'Failed to read data message for ${definition.globalId}.',
            node: ParseNodeReference(
              path: 'fit.message',
              description: 'globalId=${definition.globalId}',
            ),
          ),
        );
        reader.skip(definition.dataSize(compressedTimestamp: isCompressed));
        continue;
      }
      if (compressedTimestamp != null) {
        values[253] = compressedTimestamp;
        lastTimestamps[localType] = compressedTimestamp;
      } else {
        final rawTimestamp = values[253];
        if (rawTimestamp is num) {
          lastTimestamps[localType] = rawTimestamp.toInt();
        }
      }
      switch (definition.globalId) {
        case 0: // file_id
          final manufacturer = values[1];
          final product = values[2];
          final serial = values[3];
          final manufacturerId = manufacturer is num
              ? manufacturer.toInt()
              : null;
          final productId = product is num ? product.toInt() : null;
          final serialId = serial is num ? serial.toInt() : null;
          final manufacturerName = manufacturerId != null
              ? fitManufacturerNames[manufacturerId] ??
                    'manufacturer_$manufacturerId'
              : null;
          deviceMetadata = ActivityDeviceMetadata(
            manufacturer: manufacturerName,
            product: productId?.toString(),
            serialNumber: serialId?.toString(),
            fitManufacturerId: manufacturerId,
            fitProductId: productId,
          );
          final parts = <String>['FIT Device'];
          if (manufacturerName != null) {
            parts.add(manufacturerName);
          } else if (manufacturerId != null) {
            parts.add('m$manufacturerId');
          }
          if (productId != null) {
            parts.add('p$productId');
          }
          if (serialId != null) {
            parts.add('s$serialId');
          }
          creator = parts.join(' ');
          break;
        case 18: // session
          final sportValue = values[5];
          if (sportValue is int) {
            sport = _mapSport(sportValue);
          }
          break;
        case 19: // lap
          final start = _decodeTimestamp(values[2]);
          final totalTime = _asNumber(values[7])?.toDouble();
          final distanceMeters = _asNumber(values[8])?.toDouble();
          if (start != null && totalTime != null) {
            final end = start.add(
              Duration(milliseconds: (totalTime * 1000).round()),
            );
            laps.add(
              Lap(
                startTime: start,
                endTime: end,
                distanceMeters: distanceMeters,
                name: 'Lap ${laps.length + 1}',
              ),
            );
          }
          break;
        case 20: // record
          final timestamp = _decodeTimestamp(values[253]);
          if (timestamp == null) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'fit.record.missing_timestamp',
                message: 'Record without timestamp skipped.',
                node: ParseNodeReference(
                  path: 'fit.record',
                  description: 'localType=$localType',
                ),
              ),
            );
            continue;
          }
          final lat = _decodeSemicircles(values[0]);
          final lon = _decodeSemicircles(values[1]);
          final altitude = _decodeAltitude(values[2]);
          if (lat != null && lon != null) {
            points.add(
              GeoPoint(
                latitude: lat,
                longitude: lon,
                elevation: altitude,
                time: timestamp,
              ),
            );
          }
          final hr = _asNumber(values[3]);
          if (hr != null) {
            hrSamples.add(Sample(time: timestamp, value: hr.toDouble()));
          }
          final cadence = _asNumber(values[4]);
          if (cadence != null) {
            cadenceSamples.add(
              Sample(time: timestamp, value: cadence.toDouble()),
            );
          }
          final distance = _asNumber(values[5]);
          if (distance != null) {
            distanceSamples.add(
              Sample(time: timestamp, value: distance.toDouble() / 100.0),
            );
          }
          final speed = _asNumber(values[6]);
          if (speed != null) {
            speedSamples.add(
              Sample(time: timestamp, value: speed.toDouble() / 1000.0),
            );
          }
          final power = _asNumber(values[7]);
          if (power != null) {
            powerSamples.add(Sample(time: timestamp, value: power.toDouble()));
          }
          final temp = _asNumber(values[13]);
          if (temp != null) {
            tempSamples.add(Sample(time: timestamp, value: temp.toDouble()));
          }
          break;
        default:
          // Skip unhandled message types.
          break;
      }
    }
    final channels = <Channel, Iterable<Sample>>{};
    if (hrSamples.isNotEmpty) channels[Channel.heartRate] = hrSamples;
    if (cadenceSamples.isNotEmpty) channels[Channel.cadence] = cadenceSamples;
    if (powerSamples.isNotEmpty) channels[Channel.power] = powerSamples;
    if (tempSamples.isNotEmpty) channels[Channel.temperature] = tempSamples;
    if (speedSamples.isNotEmpty) channels[Channel.speed] = speedSamples;
    if (distanceSamples.isNotEmpty) {
      channels[Channel.distance] = distanceSamples;
    }
    final activity = RawActivity(
      points: points,
      channels: channels,
      laps: laps,
      sport: sport,
      creator: creator,
      device: deviceMetadata != null && deviceMetadata.isNotEmpty
          ? deviceMetadata
          : null,
    );
    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
  }
}

Uint8List _decodePayload(String input, List<ParseDiagnostic> diagnostics) {
  try {
    return Uint8List.fromList(base64Decode(input));
  } on FormatException {
    throw FormatException(
      'FIT payloads must be base64-encoded when provided as String. '
      'Use ActivityParser.parseBytes for raw binary data.',
    );
  }
}

int _applyCompressedTimestamp(int previous, int offset) {
  const mask = 0x1F;
  final base = previous & ~mask;
  var value = base | offset;
  if (value <= previous) {
    value += mask + 1;
  }
  return value & 0xFFFFFFFF;
}

Sport _mapSport(int value) {
  switch (value) {
    case 0:
      return Sport.running;
    case 1:
      return Sport.cycling;
    case 2:
      return Sport.swimming;
    case 11:
      return Sport.walking;
    default:
      return Sport.other;
  }
}

DateTime? _decodeTimestamp(Object? raw) {
  if (raw is! num) {
    return null;
  }
  final seconds = raw.toInt();
  if (seconds == 0 || seconds == 0xFFFFFFFF) {
    return null;
  }
  return DateTime.utc(1989, 12, 31).add(Duration(seconds: seconds));
}

double? _decodeSemicircles(Object? raw) {
  if (raw is! num) {
    return null;
  }
  final value = raw.toInt();
  if (value == 0x7FFFFFFF || value == 0x80000000) {
    return null;
  }
  return (value * 180.0) / 2147483648.0;
}

double? _decodeAltitude(Object? raw) {
  if (raw is! num) {
    return null;
  }
  final value = raw.toInt();
  if (value == 0xFFFF) {
    return null;
  }
  return (value / 5.0) - 500.0;
}

num? _asNumber(Object? raw) {
  if (raw is! num) {
    return null;
  }
  final value = raw.toInt();
  switch (value) {
    case 0xFF:
    case 0xFFFF:
    case 0xFFFFFF:
    case 0xFFFFFFFF:
      return null;
    default:
      return raw;
  }
}

class _FitHeader {
  _FitHeader({
    required this.headerSize,
    required this.protocolVersion,
    required this.profileVersion,
    required this.dataSize,
    required this.dataType,
  });
  final int headerSize;
  final int protocolVersion;
  final int profileVersion;
  final int dataSize;
  final String dataType;
  static _FitHeader? tryRead(_FitByteReader reader) {
    final start = reader.position;
    try {
      final size = reader.readUint8();
      if (size < 12) {
        return null;
      }
      final protocol = reader.readUint8();
      final profile = reader.readUint16();
      final dataSize = reader.readUint32();
      final dataType = utf8.decode(reader.readBytes(4));
      final remaining = size - 12;
      if (remaining > 0) {
        reader.skip(remaining);
      }
      return _FitHeader(
        headerSize: size,
        protocolVersion: protocol,
        profileVersion: profile,
        dataSize: dataSize,
        dataType: dataType,
      );
    } catch (_) {
      reader.position = start;
      return null;
    }
  }
}

class _FitMessageDefinition {
  _FitMessageDefinition({
    required this.localId,
    required this.globalId,
    required this.isLittleEndian,
    required this.fields,
    required this.developerFields,
  });
  final int localId;
  final int globalId;
  final bool isLittleEndian;
  final List<_FitFieldDefinition> fields;
  final List<_FitDeveloperFieldDefinition> developerFields;
  int get _developerDataSize =>
      developerFields.fold(0, (total, field) => total + field.size);
  static _FitMessageDefinition? read(
    _FitByteReader reader,
    int localId, {
    required bool hasDeveloper,
  }) {
    try {
      reader.readUint8(); // reserved
      final architecture = reader.readUint8();
      final littleEndian = architecture == 0;
      final globalMessage = reader.readUint16(
        endian: littleEndian ? Endian.little : Endian.big,
      );
      final fieldCount = reader.readUint8();
      final fields = <_FitFieldDefinition>[];
      for (var i = 0; i < fieldCount; i++) {
        fields.add(
          _FitFieldDefinition(
            fieldNumber: reader.readUint8(),
            size: reader.readUint8(),
            baseType: reader.readUint8(),
          ),
        );
      }
      final developerFields = <_FitDeveloperFieldDefinition>[];
      if (hasDeveloper) {
        final developerCount = reader.readUint8();
        for (var i = 0; i < developerCount; i++) {
          developerFields.add(
            _FitDeveloperFieldDefinition(
              fieldNumber: reader.readUint8(),
              size: reader.readUint8(),
              developerIndex: reader.readUint8(),
            ),
          );
        }
      }
      return _FitMessageDefinition(
        localId: localId,
        globalId: globalMessage,
        isLittleEndian: littleEndian,
        fields: fields,
        developerFields: developerFields,
      );
    } catch (_) {
      return null;
    }
  }

  int dataSize({bool compressedTimestamp = false}) {
    var total = _developerDataSize;
    for (final field in fields) {
      if (compressedTimestamp && field.fieldNumber == 253) {
        continue;
      }
      total += field.size;
    }
    return total;
  }

  Map<int, Object?>? readValues(
    _FitByteReader reader, {
    bool compressedTimestamp = false,
  }) {
    final values = <int, Object?>{};
    for (final field in fields) {
      if (compressedTimestamp && field.fieldNumber == 253) {
        values[field.fieldNumber] = null;
        continue;
      }
      final value = reader.readBaseType(
        field.baseType,
        field.size,
        endian: isLittleEndian ? Endian.little : Endian.big,
      );
      if (value != null) {
        values[field.fieldNumber] = value;
      }
    }
    for (final developerField in developerFields) {
      if (developerField.size > 0) {
        reader.skip(developerField.size);
      }
    }
    return values;
  }
}

class _FitDeveloperFieldDefinition {
  const _FitDeveloperFieldDefinition({
    required this.fieldNumber,
    required this.size,
    required this.developerIndex,
  });
  final int fieldNumber;
  final int size;
  final int developerIndex;
}

class _FitFieldDefinition {
  const _FitFieldDefinition({
    required this.fieldNumber,
    required this.size,
    required this.baseType,
  });
  final int fieldNumber;
  final int size;
  final int baseType;
}

class _FitByteReader {
  _FitByteReader(this.bytes);
  final Uint8List bytes;
  int position = 0;
  int readUint8() {
    return bytes[position++];
  }

  int readUint16({Endian endian = Endian.little}) {
    final value = bytes.buffer.asByteData().getUint16(position, endian);
    position += 2;
    return value;
  }

  int readUint32({Endian endian = Endian.little}) {
    final value = bytes.buffer.asByteData().getUint32(position, endian);
    position += 4;
    return value;
  }

  Uint8List readBytes(int length) {
    final slice = bytes.sublist(position, position + length);
    position += length;
    return Uint8List.fromList(slice);
  }

  int get remaining => bytes.length - position;

  void skip(int length) {
    if (length <= 0) {
      return;
    }
    position += length;
    if (position > bytes.length) {
      position = bytes.length;
    }
  }

  void skipRemaining(int length) {
    skip(length);
  }

  Object? readBaseType(
    int baseType,
    int size, {
    Endian endian = Endian.little,
  }) {
    final data = bytes.buffer.asByteData();
    Object? value;
    switch (baseType & 0x1F) {
      case 0x00: // enum
      case 0x02: // uint8
      case 0x0A: // uint8z
        final raw = bytes[position];
        position += size;
        if (raw == 0xFF) return null;
        value = raw;
        break;
      case 0x01: // sint8
        final raw = data.getInt8(position);
        position += size;
        if (raw == 0x7F) return null;
        value = raw;
        break;
      case 0x03: // sint16
        final raw = data.getInt16(position, endian);
        position += 2;
        if (raw == 0x7FFF) return null;
        value = raw;
        break;
      case 0x04: // uint16
      case 0x0B: // uint16z
        final raw = data.getUint16(position, endian);
        position += 2;
        if (raw == 0xFFFF) return null;
        value = raw;
        break;
      case 0x05: // sint32
        final raw = data.getInt32(position, endian);
        position += 4;
        if (raw == 0x7FFFFFFF) return null;
        value = raw;
        break;
      case 0x06: // uint32
      case 0x0C: // uint32z
        final raw = data.getUint32(position, endian);
        position += 4;
        if (raw == 0xFFFFFFFF) return null;
        value = raw;
        break;
      case 0x07: // string
        final rawBytes = readBytes(size);
        final nul = rawBytes.indexOf(0);
        final slice = nul >= 0 ? rawBytes.sublist(0, nul) : rawBytes;
        value = utf8.decode(slice);
        break;
      default:
        final rawBytes = readBytes(size);
        value = rawBytes;
        break;
    }
    return value;
  }
}
