// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import '../fit/fit_crc.dart';
import '../models.dart';
import 'activity_parser.dart';
import 'integrity_mode.dart';
import 'parse_result.dart';

/// Parser for FIT binary payloads (limited profile support).
/// Decodes numeric developer values and maps known fields to semantic channel names.
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

  /// Parse FIT bytes with configurable integrity handling.
  ///
  /// Use [integrityConfig] to control how CRC mismatches and truncation issues
  /// are handled:
  /// * [IntegrityMode.strict]: Throws on any issue (fail-fast)
  /// * [IntegrityMode.report]: Logs issues as diagnostics, continues (default)
  /// * [IntegrityMode.silent]: Ignores all issues silently
  ///
  /// When [IntegrityConfig.collectStats] is true, detailed statistics about
  /// issues are collected and exposed in the result.
  ActivityParseResult parseBytesWithIntegrity(
    Uint8List payload, {
    IntegrityConfig integrityConfig = const IntegrityConfig(),
  }) {
    return _parsePayloadWithIntegrity(
      payload,
      <ParseDiagnostic>[],
      integrityConfig: integrityConfig,
    );
  }

  ActivityParseResult _parsePayload(
    Uint8List payload,
    List<ParseDiagnostic> diagnostics,
  ) {
    final pass1Reader = _FitByteReader(payload);
    final header = _FitHeader.tryRead(pass1Reader);
    if (header == null) {
      throw FormatException(
        'Invalid FIT header: could not read magic number and dataSize.\n'
        '\n'
        'This usually means:\n'
        '  • The file is not a valid FIT file\n'
        '  • The file is corrupted or truncated\n'
        '  • The file was not transferred correctly (incomplete download)\n'
        '\n'
        'Please verify:\n'
        '  1. The file has a .fit extension and is not renamed\n'
        '  2. The file size is at least 14 bytes (minimum FIT header)\n'
        '  3. The file was downloaded/transferred completely\n'
        '  4. Try re-downloading the file from the source device\n'
        '\n'
        'File size: ${payload.length} bytes',
      );
    }
    if (header.headerSize > payload.length) {
      throw FormatException(
        'FIT header claims ${header.headerSize} bytes but file only has ${payload.length} bytes.\n'
        '\n'
        'The file is truncated or corrupted:\n'
        '  • Header size: ${header.headerSize} bytes\n'
        '  • Available data: ${payload.length} bytes\n'
        '  • Missing: ${header.headerSize - payload.length} bytes\n'
        '\n'
        'Solutions:\n'
        '  1. Re-download the file from the device/source\n'
        '  2. Check network/transfer logs for interruptions\n'
        '  3. Verify the file was saved/exported completely\n'
        '  4. If partial recovery is needed, use strictFitIntegrity: false',
      );
    }
    if (header.hasHeaderCrc) {
      final storedHeaderCrc =
          payload[header.headerSize - 2] |
          (payload[header.headerSize - 1] << 8);
      final computedHeaderCrc = computeFitCrc(
        payload,
        length: header.headerSize - 2,
      );
      if (storedHeaderCrc != computedHeaderCrc) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.error,
            code: 'fit.header.crc_mismatch',
            message:
                "FIT header CRC 0x${storedHeaderCrc.toRadixString(16).padLeft(4, '0')} does not match computed 0x${computedHeaderCrc.toRadixString(16).padLeft(4, '0')}.",
            node: const ParseNodeReference(path: 'fit.header'),
          ),
        );
      }
    }
    if (header.dataType != '.FIT') {
      throw FormatException(
        'Unsupported FIT file type: "${header.dataType}" (expected ".FIT").\n'
        '\n'
        'This file is either:\n'
        '  • Not a valid FIT file\n'
        '  • A corrupted FIT header\n'
        '  • A different file format entirely\n'
        '\n'
        'Please verify:\n'
        '  1. The file is a genuine FIT file from a fitness device\n'
        '  2. The file extension is .fit (correct format)\n'
        '  3. The file was not converted to another format\n'
        '  4. Check with the source device that exported this file\n'
        '\n'
        'If you believe this is a valid FIT file, please report it as a bug.',
      );
    }
    final dataLimit = header.headerSize + header.dataSize;

    // Keep definition state in-order as records appear in the stream.
    final definitions = <int, _FitMessageDefinition>{};
    final reader = _FitByteReader(payload)..position = header.headerSize;
    final lastTimestamps = <int, int>{};
    int? lastKnownTimestamp;
    final points = <GeoPoint>[];
    final hrSamples = <Sample>[];
    final cadenceSamples = <Sample>[];
    final powerSamples = <Sample>[];
    final tempSamples = <Sample>[];
    final speedSamples = <Sample>[];
    final distanceSamples = <Sample>[];
    final extraSamples = <Channel, List<Sample>>{};
    final laps = <Lap>[];
    var sawDataMessage = false;
    var unknownDefinitionCount = 0;
    var recoveredTimestampCount = 0;
    Sport sport = Sport.unknown;
    String? creator;
    ActivityDeviceMetadata? deviceMetadata;
    ActivitySummary? summary;
    if (dataLimit > payload.length) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'fit.header.size_mismatch',
          message: 'FIT header advertises data larger than available payload.',
          node: const ParseNodeReference(path: 'fit.header'),
        ),
      );
    }
    final trailerOffset = dataLimit;
    final hasTrailer = payload.length >= trailerOffset + 2;
    if (!hasTrailer) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'fit.trailer.truncated',
          message:
              'FIT trailer is missing or truncated; CRC validation skipped.',
          node: const ParseNodeReference(path: 'fit.trailer'),
        ),
      );
    } else {
      final storedCrc =
          payload[trailerOffset] | (payload[trailerOffset + 1] << 8);
      final computedCrc = computeFitCrc(
        payload,
        offset: header.headerSize,
        length: header.dataSize,
      );
      if (storedCrc != computedCrc) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.error,
            code: 'fit.trailer.crc_mismatch',
            message:
                "FIT trailer CRC 0x${storedCrc.toRadixString(16).padLeft(4, '0')} does not match computed 0x${computedCrc.toRadixString(16).padLeft(4, '0')}.",
            node: const ParseNodeReference(path: 'fit.trailer'),
          ),
        );
      }
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
          // Seed timestamp with offset to avoid skipping the message.
          compressedTimestamp = offset;
          lastTimestamps[localType] = offset;
        } else {
          compressedTimestamp = _applyCompressedTimestamp(previous, offset);
        }
      }
      if (isDefinition) {
        final definition = _FitMessageDefinition.read(
          reader,
          localType,
          hasDeveloper: hasDeveloper,
        );
        if (definition != null) {
          definitions[localType] = definition;
        }
        continue;
      }
      sawDataMessage = true;
      var definition = definitions[localType];
      if (definition == null) {
        unknownDefinitionCount++;
        if (unknownDefinitionCount <= 5) {
          diagnostics.add(
            ParseDiagnostic(
              severity: ParseSeverity.warning,
              code: 'fit.data.unknown_definition',
              message:
                  'Data message references unknown definition #$localType; attempting stream resynchronization.',
              node: ParseNodeReference(
                path: 'fit.message',
                description: 'localType=$localType',
              ),
            ),
          );
        }
        final progressBeforeResync = reader.position;
        final resynced = _resyncToDefinition(
          payload,
          reader,
          math.min(dataLimit, payload.length),
          definitions,
        );
        if (!resynced && reader.position <= progressBeforeResync) {
          if (reader.position < dataLimit) {
            reader.position = reader.position + 1;
          }
          if (unknownDefinitionCount <= 5) {
            diagnostics.add(
              ParseDiagnostic(
                severity: ParseSeverity.warning,
                code: 'fit.data.resync_failed',
                message:
                    'Unable to resynchronize after unknown definition #$localType; skipping one byte to continue parsing.',
                node: ParseNodeReference(
                  path: 'fit.message',
                  description: 'localType=$localType',
                ),
              ),
            );
          }
        }
        continue;
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
        lastKnownTimestamp = compressedTimestamp;
      } else {
        final rawTimestamp = values[253];
        if (rawTimestamp is num) {
          lastTimestamps[localType] = rawTimestamp.toInt();
          lastKnownTimestamp = rawTimestamp.toInt();
        }
      }
      final isCanonicalRecord = definition.globalId == 20;
      final isFallbackRecord =
          !isCanonicalRecord && _looksLikeRecordDefinition(definition);
      if (isCanonicalRecord || isFallbackRecord) {
        DateTime? timestamp = _decodeTimestamp(values[253]);
        if (timestamp == null) {
          final recoveredSeconds =
              lastTimestamps[localType] ?? lastKnownTimestamp;
          if (recoveredSeconds != null) {
            timestamp = DateTime.utc(
              1989,
              12,
              31,
            ).add(Duration(seconds: recoveredSeconds));
            recoveredTimestampCount++;
            if (recoveredTimestampCount <= 5) {
              diagnostics.add(
                ParseDiagnostic(
                  severity: ParseSeverity.warning,
                  code: 'fit.record.recovered_timestamp',
                  message:
                      'Record timestamp missing; reused recent timestamp context for best-effort extraction.',
                  node: ParseNodeReference(
                    path: 'fit.record',
                    description: 'localType=$localType',
                  ),
                ),
              );
            }
          }
        }
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
        final recordTime = timestamp;
        void addSample(Channel channel, num? value) {
          if (value == null) return;
          (extraSamples[channel] ??= <Sample>[]).add(
            Sample(time: recordTime, value: value.toDouble()),
          );
        }

        void addVendorField(int field) {
          addSample(
            Channel.custom('fit_field_$field'),
            _asNumber(values[field]),
          );
        }

        final lat = _decodeSemicircles(values[0]);
        final lon = _decodeSemicircles(values[1]);
        if (isFallbackRecord && (lat == null || lon == null)) {
          continue;
        }
        final altitude = _decodeAltitude(values[2]);
        if (lat != null && lon != null) {
          points.add(
            GeoPoint(
              latitude: lat,
              longitude: lon,
              elevation: altitude,
              time: recordTime,
            ),
          );
        }
        final hr = _asNumber(values[3]);
        if (hr != null) {
          hrSamples.add(Sample(time: recordTime, value: hr.toDouble()));
        }
        final cadence = _asNumber(values[4]);
        if (cadence != null) {
          cadenceSamples.add(
            Sample(time: recordTime, value: cadence.toDouble()),
          );
        }
        final distance = _asNumber(values[5]);
        if (distance != null) {
          distanceSamples.add(
            Sample(time: recordTime, value: distance.toDouble() / 100.0),
          );
        }
        final speed = _asNumber(values[6]);
        if (speed != null) {
          speedSamples.add(
            Sample(time: recordTime, value: speed.toDouble() / 1000.0),
          );
        }
        final power = _asNumber(values[7]);
        if (power != null) {
          powerSamples.add(Sample(time: recordTime, value: power.toDouble()));
        }
        final temp = _asNumber(values[13]);
        if (temp != null) {
          tempSamples.add(Sample(time: recordTime, value: temp.toDouble()));
        }
        addSample(Channel.custom('grade'), _decodeFitScaled(values[78], 100));
        addSample(Channel.custom('left_right_balance'), _asNumber(values[120]));
        addVendorField(53);
        addVendorField(73);
        addVendorField(87);
        addVendorField(107);
        addVendorField(134);
        addVendorField(135);
        addVendorField(136);
        addVendorField(143);
        for (final entry in values.entries) {
          if (!_isDeveloperFieldKey(entry.key)) {
            continue;
          }
          final numeric = _asNumber(entry.value);
          if (numeric == null) {
            continue;
          }
          final developerIndex = _developerIndexFromKey(entry.key);
          final developerFieldNumber = _developerFieldNumberFromKey(entry.key);
          addSample(
            Channel.custom(
              _developerChannelName(
                developerIndex: developerIndex,
                fieldNumber: developerFieldNumber,
              ),
            ),
            numeric,
          );
        }
        continue;
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
          summary = ActivitySummary(
            elapsedTime: _decodeFitDuration(values[8]),
            timerTime: _decodeFitDuration(values[9]),
            totalDistanceMeters: _decodeFitDistance(values[11]),
            calories: _asNumber(values[14])?.toDouble(),
            avgSpeed: _decodeFitSpeed(values[16]),
            maxSpeed: _decodeFitSpeed(values[17]),
            avgHeartRate: _asNumber(values[18])?.toDouble(),
            maxHeartRate: _asNumber(values[19])?.toDouble(),
            avgCadence: _asNumber(values[20])?.toDouble(),
            maxCadence: _asNumber(values[21])?.toDouble(),
            avgPower: _asNumber(values[22])?.toDouble(),
            maxPower: _asNumber(values[23])?.toDouble(),
          );
          break;
        case 19: // lap
          final start = _decodeTimestamp(values[2]);
          final totalTime = _decodeFitDuration(values[7]);
          final distanceMeters = _decodeFitDistance(values[8]);
          if (start != null && totalTime != null) {
            final end = start.add(totalTime);
            laps.add(
              Lap(
                startTime: start,
                endTime: end,
                distanceMeters: distanceMeters,
                name: 'Lap ${laps.length + 1}',
                calories: _asNumber(values[21])?.toDouble(),
                avgSpeed: _decodeFitSpeed(values[13]),
                maxSpeed: _decodeFitSpeed(values[14]),
                avgHeartRate: _asNumber(values[15])?.toDouble(),
                maxHeartRate: _asNumber(values[16])?.toDouble(),
                avgCadence: _asNumber(values[17])?.toDouble(),
                maxCadence: _asNumber(values[18])?.toDouble(),
                avgPower: _asNumber(values[19])?.toDouble(),
                maxPower: _asNumber(values[20])?.toDouble(),
                event: _asNumber(values[0])?.toInt(),
                eventType: _asNumber(values[1])?.toInt(),
              ),
            );
          }
          break;
        case 23: // device_info
          final manufacturerId = _asNumber(values[3])?.toInt();
          final serialId = _asNumber(values[4])?.toInt();
          final productId = _asNumber(values[5])?.toInt();
          final softwareVersion = _formatFitSoftwareVersion(values[6]);
          final manufacturerName = manufacturerId != null
              ? fitManufacturerNames[manufacturerId] ??
                    'manufacturer_$manufacturerId'
              : null;
          final previous = deviceMetadata;
          deviceMetadata = ActivityDeviceMetadata(
            manufacturer: manufacturerName ?? previous?.manufacturer,
            model: previous?.model,
            product: productId?.toString() ?? previous?.product,
            serialNumber: serialId?.toString() ?? previous?.serialNumber,
            softwareVersion: softwareVersion ?? previous?.softwareVersion,
            fitManufacturerId: manufacturerId ?? previous?.fitManufacturerId,
            fitProductId: productId ?? previous?.fitProductId,
          );
          break;
        case 34: // activity — field 0 is total_timer_time only; no elapsed_time field in this message
          final totalTimer = _decodeFitDuration(values[0]);
          if (totalTimer != null) {
            summary = (summary ?? const ActivitySummary()).copyWith(
              timerTime: summary?.timerTime ?? totalTimer,
            );
          }
          break;
        case 49: // file_creator
          final softwareVersion = _formatFitSoftwareVersion(values[0]);
          final previous = deviceMetadata;
          if (softwareVersion != null) {
            deviceMetadata = ActivityDeviceMetadata(
              manufacturer: previous?.manufacturer,
              model: previous?.model,
              product: previous?.product,
              serialNumber: previous?.serialNumber,
              softwareVersion: softwareVersion,
              fitManufacturerId: previous?.fitManufacturerId,
              fitProductId: previous?.fitProductId,
            );
          }
          if (creator == null || creator.trim().isEmpty) {
            final hwVersion = _asNumber(values[1])?.toInt();
            final details = <String>[];
            if (softwareVersion != null) {
              details.add('sw$softwareVersion');
            }
            if (hwVersion != null) {
              details.add('hw$hwVersion');
            }
            creator = details.isEmpty
                ? 'FIT FileCreator'
                : 'FIT FileCreator ${details.join(' ')}';
          }
          break;
        default:
          // Skip unhandled message types.
          break;
      }
    }
    // Filter points to find the largest temporally contiguous group.
    // This removes corrupted data at the start/end of files with invalid timestamps.
    final filteredPoints = _filterContiguousPoints(points, diagnostics);

    final channels = <Channel, Iterable<Sample>>{};
    if (hrSamples.isNotEmpty) channels[Channel.heartRate] = hrSamples;
    if (cadenceSamples.isNotEmpty) channels[Channel.cadence] = cadenceSamples;
    if (powerSamples.isNotEmpty) channels[Channel.power] = powerSamples;
    if (tempSamples.isNotEmpty) channels[Channel.temperature] = tempSamples;
    if (speedSamples.isNotEmpty) channels[Channel.speed] = speedSamples;
    if (distanceSamples.isNotEmpty) {
      channels[Channel.distance] = distanceSamples;
    }
    for (final entry in extraSamples.entries) {
      if (entry.value.isNotEmpty) {
        channels[entry.key] = entry.value;
      }
    }
    if (filteredPoints.isEmpty &&
        channels.isEmpty &&
        laps.isEmpty &&
        sawDataMessage) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'fit.no_usable_data',
          message:
              'FIT file did not yield any usable activity data; the file may be corrupt or unsupported.',
          node: const ParseNodeReference(path: 'fit.file'),
        ),
      );
    }
    if (unknownDefinitionCount > 5) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'fit.data.unknown_definition.summary',
          message:
              'Encountered ${unknownDefinitionCount - 5} additional unknown-definition messages while resynchronizing FIT stream.',
          node: const ParseNodeReference(path: 'fit.file'),
        ),
      );
    }
    final activity = RawActivity(
      points: filteredPoints,
      channels: channels,
      laps: laps,
      sport: sport,
      creator: creator,
      device: deviceMetadata != null && deviceMetadata.isNotEmpty
          ? deviceMetadata
          : null,
      summary: summary,
    );
    return ActivityParseResult(activity: activity, diagnostics: diagnostics);
  }

  /// Enhanced payload parsing with integrity configuration support.
  ///
  /// Wraps [_parsePayload] and adds integrity statistics collection when enabled.
  ActivityParseResult _parsePayloadWithIntegrity(
    Uint8List payload,
    List<ParseDiagnostic> diagnostics, {
    required IntegrityConfig integrityConfig,
  }) {
    // Collect stats if enabled
    final stats = integrityConfig.collectStats ? IntegrityStats() : null;

    final result = _parsePayload(payload, diagnostics);

    if (stats != null) {
      for (final diag in result.diagnostics) {
        if (diag.code == 'fit.header.crc_mismatch') {
          stats.headerCrcMismatches++;
          stats.crcMismatches++;
        } else if (diag.code == 'fit.trailer.crc_mismatch') {
          stats.trailerCrcMismatches++;
          stats.crcMismatches++;
        } else if (diag.code == 'fit.trailer.truncated' ||
            diag.code == 'fit.header.size_mismatch') {
          stats.truncatedSections++;
        }
      }
    }

    switch (integrityConfig.mode) {
      case IntegrityMode.strict:
        final integrityDiags = result.diagnostics.where(
          (d) =>
              d.code.startsWith('fit.header') ||
              d.code.startsWith('fit.trailer'),
        );
        if (integrityDiags.isNotEmpty) {
          final info = integrityDiags
              .map((d) => '${d.code}: ${d.message}')
              .join('\n  ');
          throw FormatException(
            'FIT integrity check failed (strict mode).\n  $info',
          );
        }
      case IntegrityMode.silent:
        return ActivityParseResult(
          activity: result.activity,
          diagnostics: const [],
          integrityStats: stats,
          integrityMode: integrityConfig.mode,
        );
      case IntegrityMode.report:
        break;
    }

    return ActivityParseResult(
      activity: result.activity,
      diagnostics: result.diagnostics,
      integrityStats: stats,
      integrityMode: integrityConfig.mode,
    );
  }
}

bool _resyncToDefinition(
  Uint8List payload,
  _FitByteReader reader,
  int dataLimit,
  Map<int, _FitMessageDefinition> definitions,
) {
  final start = reader.position;
  const maxScanBytes = 2048;
  final scanEnd = math.min(dataLimit, start + maxScanBytes);
  var cursor = start;
  while (cursor < scanEnd - 6) {
    final recordHeader = payload[cursor];
    final isCompressed = (recordHeader & 0x80) != 0;
    final isDefinition = !isCompressed && (recordHeader & 0x40) != 0;
    if (!isDefinition) {
      cursor++;
      continue;
    }
    final hasDeveloper = (recordHeader & 0x20) != 0;
    final localType = recordHeader & 0x0F;
    final probe = _FitByteReader(payload)..position = cursor + 1;
    final definition = _FitMessageDefinition.read(
      probe,
      localType,
      hasDeveloper: hasDeveloper,
    );
    if (definition == null ||
        definition.fields.isEmpty ||
        probe.position > dataLimit) {
      cursor++;
      continue;
    }
    definitions[localType] = definition;
    reader.position = probe.position;
    return true;
  }
  return false;
}

bool _looksLikeRecordDefinition(_FitMessageDefinition definition) {
  final fieldNumbers = definition.fields
      .map((field) => field.fieldNumber)
      .toSet();
  return fieldNumbers.contains(253) &&
      fieldNumbers.contains(0) &&
      fieldNumbers.contains(1);
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

const int _developerFieldKeyMask = 0x10000;

int _developerFieldKey(int developerIndex, int fieldNumber) =>
    _developerFieldKeyMask |
    ((developerIndex & 0xFF) << 8) |
    (fieldNumber & 0xFF);

bool _isDeveloperFieldKey(int key) => (key & _developerFieldKeyMask) != 0;

int _developerIndexFromKey(int key) => (key >> 8) & 0xFF;

int _developerFieldNumberFromKey(int key) => key & 0xFF;

const Map<(int, int), String> _knownDeveloperChannels = {
  // Common developer-field convention in running power ecosystems.
  (0, 0): 'running_power',
};

String _developerChannelName({
  required int developerIndex,
  required int fieldNumber,
}) {
  final known = _knownDeveloperChannels[(developerIndex, fieldNumber)];
  if (known != null) {
    return known;
  }
  return 'fit_dev_${developerIndex}_$fieldNumber';
}

String? _formatFitSoftwareVersion(Object? raw) {
  final value = _asNumber(raw)?.toDouble();
  if (value == null) {
    return null;
  }
  final scaled = value / 100.0;
  if (scaled.isNaN || !scaled.isFinite || scaled <= 0) {
    return null;
  }
  final trimmed = scaled.toStringAsFixed(2);
  if (trimmed.endsWith('00')) {
    return scaled.toStringAsFixed(0);
  }
  if (trimmed.endsWith('0')) {
    return scaled.toStringAsFixed(1);
  }
  return trimmed;
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
  // Reject timestamps outside reasonable range (1989-12-31 onwards to 2050-12-31)
  // FIT epoch is 1989-12-31, so:
  // - Min: 1989-12-31 00:00:01 = 1 second (allow from epoch start)
  // - Max: 2050-12-31 = ~1924992000 seconds
  // This filters obviously corrupted data while allowing valid activities.
  if (seconds < 1 || seconds > 1924992000) {
    return null;
  }
  return DateTime.utc(1989, 12, 31).add(Duration(seconds: seconds));
}

double? _decodeSemicircles(Object? raw) {
  if (raw is! num) {
    return null;
  }
  final value = raw.toInt();
  // Check for invalid marker values before conversion
  if (value == 0x7FFFFFFF || value == 0x80000000) {
    return null;
  }
  final degrees = (value * 180.0) / 2147483648.0;
  // Validate coordinate is within valid latitude/longitude range
  // This catches corrupted data that would result in invalid coordinates
  if (degrees < -180.0 || degrees > 180.0) {
    return null;
  }
  return degrees;
}

/// Filters points to keep only the largest temporally contiguous group.
/// This removes corrupted data with timestamps that are years apart from the main activity.
List<GeoPoint> _filterContiguousPoints(
  List<GeoPoint> points,
  List<ParseDiagnostic> diagnostics,
) {
  if (points.length <= 10) {
    // Skip filtering for small datasets (likely test data or very short activities)
    return points;
  }

  // Sort points by time
  final sorted = [...points]..sort((a, b) => a.time.compareTo(b.time));

  // Find groups where consecutive points are within a reasonable time window (24 hours)
  final groups = <List<GeoPoint>>[];
  var currentGroup = <GeoPoint>[sorted[0]];

  for (var i = 1; i < sorted.length; i++) {
    final gap = sorted[i].time.difference(sorted[i - 1].time);
    // If gap is more than 24 hours, start a new group
    if (gap.inHours > 24) {
      groups.add(currentGroup);
      currentGroup = <GeoPoint>[sorted[i]];
    } else {
      currentGroup.add(sorted[i]);
    }
  }
  groups.add(currentGroup);

  // Find the largest group
  if (groups.length == 1) {
    currentGroup = sorted;
  } else {
    currentGroup = groups.reduce((a, b) => a.length > b.length ? a : b);
  }

  // Additional filtering: remove points with coordinates far from their neighbors
  // This catches corrupted records with plausible timestamps but invalid coordinates
  final filtered = <GeoPoint>[];
  for (var i = 0; i < currentGroup.length; i++) {
    final point = currentGroup[i];
    var isValid = true;

    // Check distance from neighbors (skip first and last if they're outliers)
    if (currentGroup.length >= 3) {
      if (i == 0) {
        // Check first point against second
        final dist = _distance(point, currentGroup[1]);
        // If first point is >100km from second, it's likely corrupt
        if (dist > 100000) {
          isValid = false;
        }
      } else if (i == currentGroup.length - 1) {
        // Check last point against second-to-last
        final dist = _distance(point, currentGroup[i - 1]);
        // If last point is >100km from previous, it's likely corrupt
        if (dist > 100000) {
          isValid = false;
        }
      }
    }

    if (isValid) {
      filtered.add(point);
    }
  }

  final totalRemoved = points.length - filtered.length;
  if (totalRemoved > 0) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.warning,
        code: 'fit.points.filtered_outliers',
        message:
            'Removed $totalRemoved outlier point(s) with invalid timestamps or coordinates.',
        node: const ParseNodeReference(path: 'fit.points'),
      ),
    );
  }

  return filtered;
}

/// Calculate approximate distance in meters between two points using Haversine formula
double _distance(GeoPoint a, GeoPoint b) {
  const earthRadius = 6371000.0; // meters
  final lat1 = a.latitude * 0.017453292519943295; // degrees to radians
  final lat2 = b.latitude * 0.017453292519943295;
  final dLat = lat2 - lat1;
  final dLon = (b.longitude - a.longitude) * 0.017453292519943295;

  final sinDLat = math.sin(dLat / 2);
  final sinDLon = math.sin(dLon / 2);
  final a2 =
      sinDLat * sinDLat + math.cos(lat1) * math.cos(lat2) * sinDLon * sinDLon;
  final c = 2 * math.asin(math.sqrt(a2));

  return earthRadius * c;
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

Duration? _decodeFitDuration(Object? raw) {
  final value = _asNumber(raw)?.toDouble();
  if (value == null) return null;
  return Duration(milliseconds: (value * 1000).round());
}

double? _decodeFitDistance(Object? raw) {
  return _decodeFitScaled(raw, 100);
}

double? _decodeFitSpeed(Object? raw) {
  return _decodeFitScaled(raw, 1000);
}

double? _decodeFitScaled(Object? raw, double scale) {
  final value = _asNumber(raw)?.toDouble();
  if (value == null) return null;
  return value / scale;
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
    required this.hasHeaderCrc,
  });
  final int headerSize;
  final int protocolVersion;
  final int profileVersion;
  final int dataSize;
  final String dataType;
  final bool hasHeaderCrc;
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
      final dataType = utf8.decode(reader.readBytes(4), allowMalformed: true);
      final hasHeaderCrc = size > 12;
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
        hasHeaderCrc: hasHeaderCrc,
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
      final reserved = reader.readUint8();
      if (reserved != 0) {
        return null;
      }
      final architecture = reader.readUint8();
      if (architecture != 0 && architecture != 1) {
        return null;
      }
      final littleEndian = architecture == 0;
      final globalMessage = reader.readUint16(
        endian: littleEndian ? Endian.little : Endian.big,
      );
      final fieldCount = reader.readUint8();
      if (fieldCount > 96) {
        return null;
      }
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
        final value = reader.readDeveloperValue(
          developerField.size,
          endian: isLittleEndian ? Endian.little : Endian.big,
        );
        if (value != null) {
          values[_developerFieldKey(
                developerField.developerIndex,
                developerField.fieldNumber,
              )] =
              value;
        }
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
    if (length <= 0) return Uint8List(0);
    final available = bytes.length - position;
    final safe = length > available ? available : length;
    if (safe <= 0) {
      position = bytes.length;
      return Uint8List(0);
    }
    final slice = bytes.sublist(position, position + safe);
    position += safe;
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
    if (size <= 0 || position >= bytes.length) {
      position = bytes.length;
      return null;
    }
    final data = bytes.buffer.asByteData();
    Object? value;
    switch (baseType & 0x1F) {
      case 0x00: // enum
      case 0x02: // uint8
      case 0x0A: // uint8z
        if (position >= bytes.length) {
          position = bytes.length;
          return null;
        }
        final raw = bytes[position];
        position += size;
        if (raw == 0xFF) return null;
        value = raw;
        break;
      case 0x01: // sint8
        if (position >= bytes.length) {
          position = bytes.length;
          return null;
        }
        final raw = data.getInt8(position);
        position += size;
        if (raw == 0x7F) return null;
        value = raw;
        break;
      case 0x03: // sint16
        if (position + 2 > bytes.length) {
          position = bytes.length;
          return null;
        }
        final raw = data.getInt16(position, endian);
        position += 2;
        if (raw == 0x7FFF) return null;
        value = raw;
        break;
      case 0x04: // uint16
      case 0x0B: // uint16z
        if (position + 2 > bytes.length) {
          position = bytes.length;
          return null;
        }
        final raw = data.getUint16(position, endian);
        position += 2;
        if (raw == 0xFFFF) return null;
        value = raw;
        break;
      case 0x05: // sint32
        if (position + 4 > bytes.length) {
          position = bytes.length;
          return null;
        }
        final raw = data.getInt32(position, endian);
        position += 4;
        if (raw == 0x7FFFFFFF) return null;
        value = raw;
        break;
      case 0x06: // uint32
      case 0x0C: // uint32z
        if (position + 4 > bytes.length) {
          position = bytes.length;
          return null;
        }
        final raw = data.getUint32(position, endian);
        position += 4;
        if (raw == 0xFFFFFFFF) return null;
        value = raw;
        break;
      case 0x07: // string
        final rawBytes = readBytes(size);
        final nul = rawBytes.indexOf(0);
        final slice = nul >= 0 ? rawBytes.sublist(0, nul) : rawBytes;
        value = utf8.decode(slice, allowMalformed: true);
        break;
      default:
        final rawBytes = readBytes(size);
        value = rawBytes;
        break;
    }
    return value;
  }

  Object? readDeveloperValue(int size, {Endian endian = Endian.little}) {
    if (size <= 0 || position >= bytes.length) {
      position = bytes.length;
      return null;
    }
    final available = bytes.length - position;
    final safeSize = size > available ? available : size;
    if (safeSize <= 0) {
      position = bytes.length;
      return null;
    }
    final data = bytes.buffer.asByteData();
    switch (safeSize) {
      case 1:
        final raw = bytes[position];
        position += 1;
        return raw == 0xFF ? null : raw;
      case 2:
        final raw = data.getUint16(position, endian);
        position += 2;
        return raw == 0xFFFF ? null : raw;
      case 3:
        final a = bytes[position];
        final b = bytes[position + 1];
        final c = bytes[position + 2];
        position += 3;
        final raw = endian == Endian.little
            ? (a | (b << 8) | (c << 16))
            : ((a << 16) | (b << 8) | c);
        return raw == 0xFFFFFF ? null : raw;
      case 4:
        final raw = data.getUint32(position, endian);
        position += 4;
        return raw == 0xFFFFFFFF ? null : raw;
      default:
        final raw = readBytes(safeSize);
        final allInvalid = raw.every((byte) => byte == 0xFF);
        return allInvalid ? null : raw;
    }
  }
}
