// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../fit/fit_crc.dart';
import '../fit/fit_epoch.dart';
import '../fit/fit_record_fields.dart';
import '../fit/fit_sport.dart';
import '../geo_math.dart';
import '../identifier_sanitizer.dart';
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
      // A header CRC of 0x0000 means "not computed" per the FIT spec and
      // must not be verified (common on Edge 810-era files).
      if (storedHeaderCrc != 0 && storedHeaderCrc != computedHeaderCrc) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.error,
            code: 'fit.header.crc_mismatch',
            message:
                "FIT header CRC 0x${storedHeaderCrc.toRadixString(16).padLeft(4, '0')} does not match computed 0x${computedHeaderCrc.toRadixString(16).padLeft(4, '0')}.",
            node: const ParseNodeReference(path: 'fit.header'),
            suggestedFix:
                'Re-download or re-export the FIT file from the source device. If the file is otherwise valid, try parsing with IntegrityMode.silent to recover data.',
            priority: 1,
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
    final skippedGlobalIds = <int>{};
    final laps = <Lap>[];
    var inferredLapStarts = 0;
    var clampedLapDurations = 0;
    final sets = <WorkoutSet>[];
    final additionalSessions = <ActivitySummary>[];
    final events = <ActivityEvent>[];
    final swimLengths = <SwimLength>[];
    var primarySessionSeen = false;
    var sawDataMessage = false;
    var unknownDefinitionCount = 0;
    var recoveredTimestampCount = 0;
    // State for record field 8 (compressed_speed_distance): the 12-bit distance
    // component is a wrapping accumulator (1/16 m), decoded across records.
    var csdDistanceAccum = 0;
    var csdLastRaw = 0;
    var csdSeen = false;
    Sport sport = Sport.unknown;
    String? creator;
    ActivityDeviceMetadata? deviceMetadata;
    ActivitySummary? summary;
    // Developer-field registry built from field_description (206) messages,
    // keyed by _developerFieldKey. Names channels and selects the declared
    // base type when decoding developer values (a float32 developer field
    // read by size alone would decode as garbage).
    final developerFieldNames = <int, String>{};
    final developerBaseTypes = <int, int>{};
    final developerFieldScales = <int, double>{};
    final developerFieldOffsets = <int, double>{};
    if (dataLimit > payload.length) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'fit.header.size_mismatch',
          message: 'FIT header advertises data larger than available payload.',
          node: const ParseNodeReference(path: 'fit.header'),
          suggestedFix:
              'The file is truncated. Re-download or re-export the activity from the device and try again.',
          priority: 0,
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
          suggestedFix:
              'The file is likely incomplete. Re-download or re-export the activity and ensure the full file was transferred.',
          priority: 0,
        ),
      );
    } else {
      final storedCrc =
          payload[trailerOffset] | (payload[trailerOffset + 1] << 8);
      // The trailer CRC covers the header AND the data records. Computing it
      // over the data alone only agreed for files whose 14-byte header ends
      // with a valid header CRC (the running CRC returns to zero after a
      // block that ends with its own CRC) — legacy 12-byte headers and
      // headers with CRC 0x0000 were falsely flagged.
      final computedCrc = computeFitCrc(
        payload,
        length: header.headerSize + header.dataSize,
      );
      if (storedCrc != computedCrc) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.error,
            code: 'fit.trailer.crc_mismatch',
            message:
                "FIT trailer CRC 0x${storedCrc.toRadixString(16).padLeft(4, '0')} does not match computed 0x${computedCrc.toRadixString(16).padLeft(4, '0')}.",
            node: const ParseNodeReference(path: 'fit.trailer'),
            suggestedFix:
                'The data may be corrupted. Re-download the file from the device; if recovery is needed, parse with IntegrityMode.silent.',
            priority: 1,
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
        // Per spec, the compressed-timestamp reference is "the last
        // timestamp recorded from any previously decoded record" -- one
        // running value, not one per local message type. Fall back to the
        // global reference when this local type has never itself carried a
        // timestamp, instead of misreading the raw 0-31 offset as an
        // absolute FIT-epoch second count.
        final reference = lastTimestamps[localType] ?? lastKnownTimestamp;
        if (reference == null) {
          // No timestamp reference established anywhere in the file yet;
          // seed with the raw offset so the message isn't skipped outright.
          compressedTimestamp = offset;
          lastTimestamps[localType] = offset;
        } else {
          compressedTimestamp = _applyCompressedTimestamp(reference, offset);
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
              suggestedFix:
                  'The file may contain non-standard message ordering. Parsing continues in best-effort mode; re-export the activity if data appears incomplete.',
              priority: 2,
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
                suggestedFix:
                    'Some data may be lost. Re-exporting the original activity from the device is the most reliable fix.',
                priority: 2,
              ),
            );
          }
        }
        continue;
      }
      final values = definition.readValues(
        reader,
        compressedTimestamp: isCompressed,
        developerBaseTypes: developerBaseTypes,
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
            suggestedFix:
                'The message data may be corrupted. Parsing continues in best-effort mode; re-export the activity if data gaps appear.',
            priority: 2,
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
      if (definition.globalId == 20) {
        DateTime? timestamp = _decodeTimestamp(values[253]);
        if (timestamp == null) {
          final recoveredSeconds =
              lastTimestamps[localType] ?? lastKnownTimestamp;
          if (recoveredSeconds != null) {
            timestamp = fitEpoch.add(Duration(seconds: recoveredSeconds));
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
                  suggestedFix:
                      'Timestamps were inferred from context. Re-exporting the activity from the device will produce a file with explicit timestamps.',
                  priority: 3,
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
              suggestedFix:
                  'This record cannot be placed on the timeline. Re-export the activity from the device to obtain a complete timestamped stream.',
              priority: 2,
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

        final lat = _decodeSemicircles(values[0]);
        final lon = _decodeSemicircles(values[1]);
        // enhanced_altitude (78) shares altitude (2)'s scale/offset formula
        // but is uint32-wide; prefer it when present.
        final altitude =
            _decodeAltitude(values[78]) ?? _decodeAltitude(values[2]);
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
        final hr = _asNumber(values[fitFieldHeartRate]);
        if (hr != null) {
          hrSamples.add(Sample(time: recordTime, value: hr.toDouble()));
        }
        final cadence = _asNumber(values[fitFieldCadence]);
        if (cadence != null) {
          cadenceSamples.add(
            Sample(time: recordTime, value: cadence.toDouble()),
          );
        }
        final distance = _asNumber(values[fitFieldDistance]);
        if (distance != null) {
          distanceSamples.add(
            Sample(
              time: recordTime,
              value: distance.toDouble() / fitFieldDistanceScale,
            ),
          );
        }
        final speed = _asNumber(values[fitFieldSpeed]);
        if (speed != null) {
          speedSamples.add(
            Sample(
              time: recordTime,
              value: speed.toDouble() / fitFieldSpeedScale,
            ),
          );
        }
        // Legacy record field 8 (compressed_speed_distance): 3 bytes packing a
        // 12-bit speed (scale 100, m/s) and a 12-bit distance delta accumulator
        // (scale 16, m). Used by older ANT+/Garmin devices instead of the
        // separate speed (6) and distance (5) fields. Explicit fields win.
        final csd = values[8];
        if (csd is List<int> &&
            csd.length >= 3 &&
            !(csd[0] == 0xFF && csd[1] == 0xFF && csd[2] == 0xFF)) {
          final packed = csd[0] | (csd[1] << 8) | (csd[2] << 16);
          final speedRaw = packed & 0x0FFF;
          final distRaw = (packed >> 12) & 0x0FFF;
          if (csdSeen) {
            csdDistanceAccum += (distRaw - csdLastRaw) & 0x0FFF;
          }
          csdLastRaw = distRaw;
          csdSeen = true;
          if (speed == null && speedRaw != 0x0FFF) {
            speedSamples.add(Sample(time: recordTime, value: speedRaw / 100.0));
          }
          if (distance == null) {
            distanceSamples.add(
              Sample(time: recordTime, value: csdDistanceAccum / 16.0),
            );
          }
        }
        final power = _asNumber(values[fitFieldPower]);
        if (power != null) {
          powerSamples.add(Sample(time: recordTime, value: power.toDouble()));
        }
        final temp = _asNumber(values[fitFieldTemperature]);
        if (temp != null) {
          tempSamples.add(Sample(time: recordTime, value: temp.toDouble()));
        }
        addSample(
          Channel.custom('grade'),
          _decodeFitScaled(values[fitFieldGrade], fitFieldGradeScale),
        );
        addSample(
          Channel.custom('left_right_balance'),
          _asNumber(values[fitFieldLeftRightBalance]),
        );
        addSample(
          Channel.custom('ebike_assist_level_percent'),
          _asNumber(values[fitFieldEbikeAssistLevelPercent]),
        );
        for (final entry in values.entries) {
          // A field can decode to a scalar num or (for an array-width field,
          // e.g. a 1/2/4-byte-wide developer field declared with size > its
          // element width) a List<num>; expand an array into one indexed
          // channel per element instead of silently dropping every element
          // past the first, matching how session/lap-level array fields
          // already fan out via _extraFitArrays. The reader
          // (_FitByteReader._readNumeric/_readFloat/_readInt64) has already
          // dropped any individual element matching the type's invalid
          // sentinel (e.g. unused trailing slots in a fixed-width array), so
          // every element reaching this loop is a genuinely present sample.
          final raw = entry.value;
          final elements = raw is List<num>
              ? raw
              : (raw is num ? [raw] : const <num>[]);
          if (elements.isEmpty) {
            continue;
          }
          final isArray = raw is List<num> && raw.length > 1;
          for (var i = 0; i < elements.length; i++) {
            final numeric = elements[i];
            final suffix = isArray ? '_$i' : '';
            if (_isDeveloperFieldKey(entry.key)) {
              // field_description supplies the channel name and optional
              // scale/offset (spec formula: raw / scale - offset); files
              // without one fall back to the generic fit_dev_<i>_<n> name.
              var value = numeric.toDouble();
              final scale = developerFieldScales[entry.key];
              if (scale != null) value = value / scale;
              final offset = developerFieldOffsets[entry.key];
              if (offset != null) value = value - offset;
              addSample(
                Channel.custom(
                  '${developerFieldNames[entry.key] ?? _developerChannelName(developerIndex: _developerIndexFromKey(entry.key), fieldNumber: _developerFieldNumberFromKey(entry.key))}$suffix',
                ),
                value,
              );
            } else if (!_dedicatedRecordFields.contains(entry.key)) {
              // Unknown native record fields (e.g. running dynamics) are
              // preserved generically as fit_field_<n> channels with their raw
              // (unscaled) values so no sensor data is silently dropped.
              addSample(
                Channel.custom('fit_field_${entry.key}$suffix'),
                numeric,
              );
            }
          }
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
          final fileIdProductName = values[8];
          deviceMetadata = ActivityDeviceMetadata(
            manufacturer: manufacturerName,
            model:
                fileIdProductName is String &&
                    fileIdProductName.trim().isNotEmpty
                ? fileIdProductName.trim()
                : null,
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
          final sessionSport = sportValue is int
              ? sportFromFitId(sportValue)
              : null;
          // Field numbers follow the official FIT profile for the session
          // message (global 18): 7 total_elapsed_time (s, scale 1000),
          // 8 total_timer_time (s, scale 1000), 9 total_distance (m, scale
          // 100), 11 total_calories, 14/15 avg/max_speed (m/s, scale 1000),
          // 16/17 avg/max_heart_rate, 18/19 avg/max_cadence,
          // 20/21 avg/max_power, 6 sub_sport, 10 total_cycles,
          // 41 avg_stroke_count (strokes/length, scale 10), 43 swim_stroke,
          // 44 pool_length (m, scale 100), 47 num_active_lengths.
          final poolLengthRaw = _asNumber(values[44]);
          final subSportRaw = _asNumber(values[6])?.toInt();
          final totalCyclesRaw = _asNumber(values[10])?.toInt();
          final avgStrokeRaw = _asNumber(values[41]);
          final sessionSummary = ActivitySummary(
            elapsedTime: _decodeFitDuration(values[7]),
            timerTime: _decodeFitDuration(values[8]),
            totalDistanceMeters: _decodeFitDistance(values[9]),
            calories: _asNumber(values[11])?.toDouble(),
            avgSpeed: _decodeFitSpeed(values[14]),
            maxSpeed: _decodeFitSpeed(values[15]),
            avgHeartRate: _asNumber(values[16])?.toDouble(),
            maxHeartRate: _asNumber(values[17])?.toDouble(),
            avgCadence: _asNumber(values[18])?.toDouble(),
            maxCadence: _asNumber(values[19])?.toDouble(),
            avgPower: _asNumber(values[20])?.toDouble(),
            maxPower: _asNumber(values[21])?.toDouble(),
            poolLengthMeters: poolLengthRaw != null
                ? poolLengthRaw.toDouble() / 100.0
                : null,
            numActiveLengths: _asNumber(values[47])?.toInt(),
            swimStroke: _decodeSwimStroke(_asNumber(values[43])?.toInt()),
            avgStrokeCount: avgStrokeRaw != null
                ? avgStrokeRaw.toDouble() / 10.0
                : null,
            subSport: subSportRaw != null && subSportRaw != 0
                ? subSportRaw
                : null,
            totalCycles: totalCyclesRaw,
            sport: sessionSport,
            extraFitFields: _extraFitFields(values, _dedicatedSessionFields),
            extraFitArrays: _extraFitArrays(values, _dedicatedSessionFields),
          );
          // Multi-session files (e.g. triathlons): the first session becomes
          // the primary summary and sport; later sessions are preserved in
          // RawActivity.additionalSessions instead of overwriting it.
          if (!primarySessionSeen) {
            primarySessionSeen = true;
            // Keep a timer time merged earlier by an activity message (34).
            final existingTimer = summary?.timerTime;
            summary = sessionSummary.timerTime == null && existingTimer != null
                ? sessionSummary.copyWith(timerTime: existingTimer)
                : sessionSummary;
            if (sessionSport != null) {
              sport = sessionSport;
            }
          } else {
            additionalSessions.add(sessionSummary);
          }
          break;
        case 19: // lap
          // Field numbers follow the official FIT profile for the lap
          // message (global 19): 2 start_time, 7 total_elapsed_time
          // (s, scale 1000), 253 timestamp (end, used when start/elapsed
          // are absent, e.g. encoders that only stamp the lap's close),
          // 9 total_distance (m, scale 100), 11 total_calories,
          // 13/14 avg/max_speed (m/s, scale 1000), 15/16 avg/max_heart_rate,
          // 17/18 avg/max_cadence, 19/20 avg/max_power, 0 event,
          // 1 event_type, 38 swim_stroke, 40 num_active_lengths.
          final declaredStart = _decodeTimestamp(values[2]);
          final totalTime = _decodeFitDuration(values[7]);
          final distanceMeters = _decodeFitDistance(values[9]);
          final end =
              (declaredStart != null && totalTime != null
                  ? declaredStart.add(totalTime)
                  : null) ??
              _decodeTimestamp(values[253]);
          // Some encoders omit start_time/total_elapsed_time and only stamp
          // the lap's close; infer a start from the previous lap's end, or
          // (for the first lap) the activity's first point, rather than
          // dropping the lap entirely.
          var start =
              declaredStart ??
              (laps.isNotEmpty
                  ? laps.last.endTime
                  : (points.isNotEmpty ? points.first.time : null));
          if (declaredStart == null && start != null) {
            inferredLapStarts++;
          }
          if (start != null && end != null && start.isAfter(end)) {
            // A corrupted/reordered lap message (e.g. a stale timestamp
            // field) can make the inferred/declared start land after the
            // end; clamp to a zero-length lap instead of writing a
            // negative duration into the encoded output.
            start = end;
            clampedLapDurations++;
          }
          if (start != null && end != null) {
            laps.add(
              Lap(
                startTime: start,
                endTime: end,
                distanceMeters: distanceMeters,
                name: 'Lap ${laps.length + 1}',
                calories: _asNumber(values[11])?.toDouble(),
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
                numActiveLengths: _asNumber(values[40])?.toInt(),
                swimStroke: _decodeSwimStroke(_asNumber(values[38])?.toInt()),
                extraFitFields: _extraFitFields(values, _dedicatedLapFields),
                extraFitArrays: _extraFitArrays(values, _dedicatedLapFields),
              ),
            );
          }
          break;
        case 21: // event (timer start/stop, markers)
          // Field numbers per the FIT profile: 253 timestamp, 0 event,
          // 1 event_type, 3 data.
          final eventTime = _decodeTimestamp(values[253]);
          final eventRaw = _asNumber(values[0])?.toInt();
          final eventTypeRaw = _asNumber(values[1])?.toInt();
          if (eventTime != null && eventRaw != null && eventTypeRaw != null) {
            events.add(
              ActivityEvent(
                time: eventTime,
                event: eventRaw,
                eventType: eventTypeRaw,
                data: _asNumber(values[3])?.toInt(),
              ),
            );
          }
          break;
        case 101: // length (per-length pool-swim data)
          // Field numbers per the FIT profile: 253 timestamp (end),
          // 2 start_time, 3 total_elapsed_time (s, scale 1000),
          // 5 total_strokes, 6 avg_speed (m/s, scale 1000), 7 swim_stroke,
          // 12 length_type (0 idle, 1 active).
          final lengthStart = _decodeTimestamp(values[2]);
          final lengthElapsed = _decodeFitDuration(values[3]);
          final lengthEnd =
              _decodeTimestamp(values[253]) ??
              (lengthStart != null && lengthElapsed != null
                  ? lengthStart.add(lengthElapsed)
                  : null);
          if (lengthStart != null && lengthEnd != null) {
            swimLengths.add(
              SwimLength(
                startTime: lengthStart,
                endTime: lengthEnd,
                isActive: _asNumber(values[12])?.toInt() != 0,
                totalStrokes: _asNumber(values[5])?.toInt(),
                avgSpeed: _decodeFitSpeed(values[6]),
                swimStroke: _decodeSwimStroke(_asNumber(values[7])?.toInt()),
              ),
            );
          }
          break;
        case 225: // set (strength training)
          // Field numbers follow the official FIT profile for the set
          // message (global 225): 254 timestamp (set end), 6 start_time,
          // 5 set_type (0 = rest, 1 = active), 3 repetitions,
          // 4 weight (kg, scale 16), 7 category.
          final setEnd = _decodeTimestamp(values[254]);
          final setStart = _decodeTimestamp(values[6]);
          final setDuration = _decodeFitDuration(values[0]);
          final setTypeRaw = _asNumber(values[5])?.toInt();
          if (setEnd != null) {
            final start =
                setStart ??
                (setDuration != null ? setEnd.subtract(setDuration) : setEnd);
            final weightRaw = _asNumber(values[4]);
            final catRaw = _asNumber(values[7])?.toInt();
            sets.add(
              WorkoutSet(
                startTime: start,
                endTime: setEnd,
                isRest: setTypeRaw == 0,
                exerciseCategoryId: catRaw,
                exerciseCategory: WorkoutSet.categoryLabel(catRaw),
                repetitions: _asNumber(values[3])?.toInt(),
                weightKg: weightRaw != null
                    ? weightRaw.toDouble() / 16.0
                    : null,
              ),
            );
          }
          break;
        case 23: // device_info
          // Official profile: 0 device_index, 2 manufacturer,
          // 3 serial_number, 4 product, 5 software_version (scale 100),
          // 27 product_name. These offsets must match exactly: reading
          // fields 2–5 shifted by one swaps hardware_version in as the
          // software version and the serial number as the manufacturer.
          //
          // Real files carry one device_info per connected sensor;
          // device_index 0 is the recording head unit ("creator"). Only its
          // metadata describes the device — a paired speed sensor must not
          // overwrite the head unit's name. Messages without a device_index
          // are treated as the creator (some watches omit it).
          final deviceIndex = _asNumber(values[0])?.toInt();
          if (deviceIndex != null && deviceIndex != 0) {
            break;
          }
          final manufacturerId = _asNumber(values[2])?.toInt();
          final serialId = _asNumber(values[3])?.toInt();
          final productId = _asNumber(values[4])?.toInt();
          final softwareVersion = _formatFitSoftwareVersion(values[5]);
          final productName = values[27];
          final model = productName is String && productName.trim().isNotEmpty
              ? productName.trim()
              : null;
          final manufacturerName = manufacturerId != null
              ? fitManufacturerNames[manufacturerId] ??
                    'manufacturer_$manufacturerId'
              : null;
          final previous = deviceMetadata;
          deviceMetadata = ActivityDeviceMetadata(
            manufacturer: manufacturerName ?? previous?.manufacturer,
            model: model ?? previous?.model,
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
        case 206: // field_description — developer field metadata
          // Official profile: 0 developer_data_index, 1
          // field_definition_number, 2 fit_base_type_id, 3 field_name,
          // 6 scale, 7 offset. Registers the name, base type, and scaling
          // used when decoding this developer field in data messages.
          final devIndex = _asNumber(values[0])?.toInt();
          final devFieldNumber = _asNumber(values[1])?.toInt();
          if (devIndex == null || devFieldNumber == null) {
            break;
          }
          final devKey = _developerFieldKey(devIndex, devFieldNumber);
          final devBaseType = _asNumber(values[2])?.toInt();
          if (devBaseType != null) {
            developerBaseTypes[devKey] = devBaseType;
          }
          final devName = values[3];
          if (devName is String) {
            final channelId = sanitizeIdentifier(devName);
            if (channelId != null) {
              developerFieldNames[devKey] = channelId;
            }
          }
          final devScale = _asNumber(values[6])?.toDouble();
          if (devScale != null && devScale > 0 && devScale != 1) {
            developerFieldScales[devKey] = devScale;
          }
          final devOffset = _asNumber(values[7])?.toDouble();
          if (devOffset != null && devOffset != 0) {
            developerFieldOffsets[devKey] = devOffset;
          }
          break;
        default:
          // Vendor-specific or otherwise undocumented message: no generic
          // representation exists, so it's skipped, but the global ID is
          // recorded to distinguish this from "no such data" (see the
          // fit.message.vendor_skipped summary below).
          skippedGlobalIds.add(definition.globalId);
          break;
      }
    }
    // Filter points to find the largest temporally contiguous group.
    // This removes corrupted data at the start/end of files with invalid timestamps.
    final filteredPoints = _filterContiguousPoints(points, diagnostics);

    if (inferredLapStarts > 0) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.info,
          code: 'fit.lap.start_time_inferred',
          message:
              '$inferredLapStarts lap(s) had no start_time or '
              'total_elapsed_time field; start was inferred from the '
              'previous lap or the activity\'s first point.',
          node: const ParseNodeReference(path: 'fit.lap'),
        ),
      );
    }
    if (clampedLapDurations > 0) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.warning,
          code: 'fit.lap.negative_duration_clamped',
          message:
              '$clampedLapDurations lap(s) had a start time after their '
              'end time (corrupted or reordered lap message); clamped to '
              'a zero-length lap.',
          node: const ParseNodeReference(path: 'fit.lap'),
        ),
      );
    }
    if (skippedGlobalIds.isNotEmpty) {
      final ids = skippedGlobalIds.toList()..sort();
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.info,
          code: 'fit.message.vendor_skipped',
          message:
              'Message global ID(s) $ids have no generic representation '
              'in this library and were not decoded.',
          node: const ParseNodeReference(path: 'fit.message'),
        ),
      );
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
          suggestedFix:
              'Verify the file is a valid activity FIT file (not a course or workout file). Re-export from the device, or inspect with Garmin FIT SDK tools.',
          priority: 0,
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
          suggestedFix:
              'The file uses non-standard message ordering. Parsed data may be incomplete; re-export the activity from the device for a clean file.',
          priority: 2,
        ),
      );
    }
    if (additionalSessions.isNotEmpty) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.info,
          code: 'fit.multi_session',
          message:
              'Multi-session FIT file (${additionalSessions.length + 1} '
              'sessions); additional sessions preserved in '
              'RawActivity.additionalSessions.',
          node: const ParseNodeReference(path: 'fit.session'),
        ),
      );
    }
    final activity = RawActivity(
      points: filteredPoints,
      channels: channels,
      laps: laps,
      sets: sets,
      sport: sport,
      creator: creator,
      device: deviceMetadata != null && deviceMetadata.isNotEmpty
          ? deviceMetadata
          : null,
      summary: summary,
      additionalSessions: additionalSessions,
      events: events,
      lengths: swimLengths,
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
        // Only suppress integrity-related diagnostics, not everything: an
        // unrelated info diagnostic (multi-session detection, outlier
        // filtering, etc.) about data that parsed fine shouldn't disappear
        // just because the caller opted out of caring about a corrupt
        // header/trailer.
        return ActivityParseResult(
          activity: result.activity,
          diagnostics: result.diagnostics
              .where(
                (d) =>
                    !d.code.startsWith('fit.header') &&
                    !d.code.startsWith('fit.trailer'),
              )
              .toList(),
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

/// Record (global 20) field numbers with dedicated decoding in the parse
/// loop; every other numeric native field becomes a `fit_field_<n>` channel.
const Set<int> _dedicatedRecordFields = {
  253, // timestamp
  0, 1, 2, 78, // position_lat, position_long, altitude, enhanced_altitude
  3, 4, 5, 6, 7, 13, // heart_rate, cadence, distance, speed, power, temp
  8, // compressed_speed_distance (decoded into speed + distance channels)
  9, 30, 120, // grade, left_right_balance, ebike_assist_level_percent
};

/// Session (global 18) field numbers mapped to dedicated [ActivitySummary]
/// properties; every other numeric native field is preserved raw in
/// [ActivitySummary.extraFitFields] so no session metric is silently dropped.
const Set<int> _dedicatedSessionFields = {
  253, 254, // timestamp
  5, 6, // sport, sub_sport
  7, 8, 9, 10, 11, // elapsed, timer, distance, cycles, calories
  14, 15, 16, 17, 18, 19, 20, 21, // avg/max speed, hr, cadence, power
  41, 43, 44, 47, // avg_stroke_count, swim_stroke, pool_length, active_lengths
};

/// Lap (global 19) field numbers mapped to dedicated [Lap] properties; every
/// other numeric native field is preserved raw in [Lap.extraFitFields].
const Set<int> _dedicatedLapFields = {
  253, 254, // timestamp
  0, 1, 2, // event, event_type, start_time
  7, 9, 11, // elapsed, distance, calories
  13, 14, 15, 16, 17, 18, 19, 20, // avg/max speed, hr, cadence, power
  38, 40, // swim_stroke, num_active_lengths
};

/// Collects unknown scalar numeric native fields (excluding developer fields
/// and arrays) into a raw field map keyed by FIT field number for lossless
/// round-tripping.
Map<int, double> _extraFitFields(Map<int, Object?> values, Set<int> dedicated) {
  final extras = <int, double>{};
  for (final entry in values.entries) {
    if (dedicated.contains(entry.key) || _isDeveloperFieldKey(entry.key)) {
      continue;
    }
    final numeric = _asNumber(entry.value);
    if (numeric != null) {
      extras[entry.key] = numeric.toDouble();
    }
  }
  return extras;
}

/// Collects unknown numeric *array* native fields (values decoded as a
/// `List<num>` by the reader) keyed by FIT field number, so multi-element
/// fields like time_in_hr_zone are preserved rather than dropped.
Map<int, List<double>> _extraFitArrays(
  Map<int, Object?> values,
  Set<int> dedicated,
) {
  final arrays = <int, List<double>>{};
  for (final entry in values.entries) {
    if (dedicated.contains(entry.key) || _isDeveloperFieldKey(entry.key)) {
      continue;
    }
    final value = entry.value;
    if (value is List<num>) {
      arrays[entry.key] = [for (final element in value) element.toDouble()];
    }
  }
  return arrays;
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
  if (value < previous) {
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

/// [SwimStroke] declares its values in FIT swim_stroke wire order (0–6),
/// so the enum index is the FIT value.
SwimStroke? _decodeSwimStroke(int? value) =>
    value != null && value >= 0 && value < SwimStroke.values.length
    ? SwimStroke.values[value]
    : null;

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
  return fitEpoch.add(Duration(seconds: seconds));
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

/// Drops small clusters of points temporally isolated (>24h gap) from the
/// rest of the track, and flags (without dropping) a start/end point that's
/// spatially far from its only neighbor.
List<GeoPoint> _filterContiguousPoints(
  List<GeoPoint> points,
  List<ParseDiagnostic> diagnostics,
) {
  if (points.length <= 10) {
    // Skip filtering for small datasets (likely test data or very short activities)
    return points;
  }

  // Stable sort: points sharing a timestamp (common when many records
  // clamp to the same value, e.g. a pre-FIT-epoch source) must keep their
  // original relative order, not get shuffled by an unstable sort.
  final sorted = [...points];
  mergeSort(sorted, compare: (a, b) => a.time.compareTo(b.time));

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

  // Keep every group with more than 10 points (this function's own
  // threshold, above, for "worth analyzing" at all); only drop small
  // clusters of stray corrupted records, not a legitimate separate
  // recording session that ended up in the same file (e.g. several
  // tracks flattened together for a single-track target format).
  final keptGroups = groups.length == 1
      ? groups
      : groups.where((g) => g.length > 10).toList();
  final survivors = keptGroups.isEmpty
      ? [groups.reduce((a, b) => a.length > b.length ? a : b)]
      : keptGroups;
  currentGroup = [for (final group in survivors) ...group];

  final totalRemoved = points.length - currentGroup.length;
  if (totalRemoved > 0) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.warning,
        code: 'fit.points.filtered_outliers',
        message:
            'Removed $totalRemoved outlier point(s) with invalid timestamps.',
        node: const ParseNodeReference(path: 'fit.points'),
      ),
    );
  }

  // A point at the very start/end of the surviving group that's >100km from
  // its only neighbor can be genuine device corruption (a bad GPS fix before
  // lock, or lost lock at the end) -- but with only one neighbor to compare
  // against, it's equally consistent with the real boundary of a second,
  // geographically-unrelated recording that got flattened into this one and
  // happens to share a near-identical timestamp with the first (see
  // `lossy.multi_track_flattened` on the encoder side). There's no way to
  // tell those two cases apart from here, so the point is kept and flagged
  // rather than silently dropped.
  var flaggedEdgeAnomalies = 0;
  if (currentGroup.length >= 3) {
    if (haversineMeters(currentGroup[0], currentGroup[1]) > 100000) {
      flaggedEdgeAnomalies++;
    }
    final last = currentGroup.length - 1;
    if (haversineMeters(currentGroup[last], currentGroup[last - 1]) > 100000) {
      flaggedEdgeAnomalies++;
    }
  }
  if (flaggedEdgeAnomalies > 0) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.info,
        code: 'fit.points.spatial_edge_anomaly',
        message:
            '$flaggedEdgeAnomalies point(s) at the start/end of the track '
            'are more than 100 km from their nearest neighbor; kept, since '
            'this can be a real second recording sharing timestamps with '
            'the first, not just device GPS corruption.',
        node: const ParseNodeReference(path: 'fit.points'),
      ),
    );
  }

  return currentGroup;
}

double? _decodeAltitude(Object? raw) {
  if (raw is! num) {
    return null;
  }
  final value = raw.toInt();
  // 0xFFFF is the uint16 sentinel (field 2); 0xFFFFFFFF is the uint32
  // sentinel (field 78). A uint16 value can never equal the larger one, so
  // checking both is safe for either field.
  if (value == 0xFFFF || value == 0xFFFFFFFF) {
    return null;
  }
  return (value / 5.0) - 500.0;
}

Duration? _decodeFitDuration(Object? raw) {
  final value = _asNumber(raw)?.toDouble();
  if (value == null) return null;
  // FIT total_elapsed_time / total_timer_time / duration fields are uint32
  // with scale 1000, i.e. the raw value is in milliseconds.
  return Duration(milliseconds: value.round());
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

num? _asNumber(Object? raw) => raw is num ? raw : null;

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
      // fieldCount is a uint8 (0–255). Real Garmin session/lap definitions
      // routinely exceed 100 fields, so this must not cap below 255 — an
      // over-tight limit rejected the definition, orphaned its data messages,
      // and derailed the whole stream via resync (a 1.4 MB ride collapsed to a
      // handful of points). Only a genuinely impossible count is rejected.
      final fieldCount = reader.readUint8();
      if (fieldCount > 255) {
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
    Map<int, int> developerBaseTypes = const {},
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
        final key = _developerFieldKey(
          developerField.developerIndex,
          developerField.fieldNumber,
        );
        // Decode with the base type declared in the field_description
        // message when available; the size-based fallback reads every value
        // as an unsigned integer, which corrupts signed and float fields.
        final baseType = developerBaseTypes[key];
        final value = baseType != null
            ? reader.readBaseType(
                baseType,
                developerField.size,
                endian: isLittleEndian ? Endian.little : Endian.big,
              )
            : reader.readDeveloperValue(
                developerField.size,
                endian: isLittleEndian ? Endian.little : Endian.big,
              );
        if (value != null) {
          values[key] = value;
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
    Object? value;
    switch (baseType & 0x1F) {
      case 0x00: // enum (scalar or array)
      case 0x02: // uint8 (scalar or array)
      case 0x0A: // uint8z (scalar or array)
        value = _readNumeric(
          size,
          1,
          signed: false,
          invalid: 0xFF,
          endian: endian,
        );
        break;
      case 0x01: // sint8 (scalar or array)
        value = _readNumeric(
          size,
          1,
          signed: true,
          invalid: 0x7F,
          endian: endian,
        );
        break;
      case 0x03: // sint16 (scalar or array)
        value = _readNumeric(
          size,
          2,
          signed: true,
          invalid: 0x7FFF,
          endian: endian,
        );
        break;
      case 0x04: // uint16
      case 0x0B: // uint16z
        value = _readNumeric(
          size,
          2,
          signed: false,
          invalid: 0xFFFF,
          endian: endian,
        );
        break;
      case 0x05: // sint32
        value = _readNumeric(
          size,
          4,
          signed: true,
          invalid: 0x7FFFFFFF,
          endian: endian,
        );
        break;
      case 0x06: // uint32
      case 0x0C: // uint32z
        value = _readNumeric(
          size,
          4,
          signed: false,
          invalid: 0xFFFFFFFF,
          endian: endian,
        );
        break;
      case 0x07: // string
        final rawBytes = readBytes(size);
        final nul = rawBytes.indexOf(0);
        final slice = nul >= 0 ? rawBytes.sublist(0, nul) : rawBytes;
        value = utf8.decode(slice, allowMalformed: true);
        break;
      case 0x08: // float32
        value = _readFloat(size, 4, endian: endian);
        break;
      case 0x09: // float64
        value = _readFloat(size, 8, endian: endian);
        break;
      case 0x0E: // sint64
      case 0x0F: // uint64
      case 0x10: // uint64z
        value = _readInt64(
          size,
          signed: (baseType & 0x1F) == 0x0E,
          endian: endian,
        );
        break;
      default:
        final rawBytes = readBytes(size);
        value = rawBytes;
        break;
    }
    return value;
  }

  /// Reads an 8/16/32-bit numeric field, consuming the full [size] so array
  /// fields (size larger than [width]) no longer misalign the stream. Each
  /// element is checked against [invalid] individually and dropped rather
  /// than kept: a fixed-width array field commonly pads unused trailing
  /// slots with the same invalid sentinel a narrower scalar field would use,
  /// and surfacing that padding as real sample values downstream would be
  /// wrong. Returns a scalar `num` when exactly one element survives, a
  /// `List<num>` (indexed by position among the *surviving* elements, not
  /// their original slot) when more than one does, or null when none do.
  /// [width] is the element byte width.
  Object? _readNumeric(
    int size,
    int width, {
    required bool signed,
    required int invalid,
    required Endian endian,
  }) {
    if (size <= 0 || position >= bytes.length) {
      position = bytes.length;
      return null;
    }
    final available = bytes.length - position;
    final safe = size > available ? available : size;
    final count = safe ~/ width;
    if (count <= 0) {
      position += safe;
      return null;
    }
    final data = bytes.buffer.asByteData();
    final values = <num>[];
    for (var i = 0; i < count; i++) {
      final offset = position + i * width;
      final raw = switch (width) {
        1 => signed ? data.getInt8(offset) : bytes[offset],
        2 =>
          signed
              ? data.getInt16(offset, endian)
              : data.getUint16(offset, endian),
        _ =>
          signed
              ? data.getInt32(offset, endian)
              : data.getUint32(offset, endian),
      };
      if (raw != invalid) values.add(raw);
    }
    position += safe; // Consume the whole field, including any odd remainder.
    if (values.isEmpty) return null;
    if (values.length == 1) return values.first;
    return values;
  }

  /// Reads a float32/float64 field ([width] 4 or 8), consuming the full
  /// [size]. The FIT invalid sentinel is the all-ones bit pattern (a NaN
  /// encoding), detected on the raw bits before conversion and checked per
  /// element so padding within an array field is dropped rather than kept
  /// (see [_readNumeric]). Returns a scalar `num` when exactly one element
  /// survives, a `List<num>` when more than one does, or null when none do.
  Object? _readFloat(int size, int width, {required Endian endian}) {
    if (size <= 0 || position >= bytes.length) {
      position = bytes.length;
      return null;
    }
    final available = bytes.length - position;
    final safe = size > available ? available : size;
    final count = safe ~/ width;
    if (count <= 0) {
      position += safe;
      return null;
    }
    final data = bytes.buffer.asByteData();
    final values = <num>[];
    for (var i = 0; i < count; i++) {
      final offset = position + i * width;
      final bool invalid;
      final double raw;
      if (width == 4) {
        invalid = data.getUint32(offset, endian) == 0xFFFFFFFF;
        raw = data.getFloat32(offset, endian);
      } else {
        invalid =
            data.getUint32(offset, endian) == 0xFFFFFFFF &&
            data.getUint32(offset + 4, endian) == 0xFFFFFFFF;
        raw = data.getFloat64(offset, endian);
      }
      if (!invalid) values.add(raw);
    }
    position += safe;
    if (values.isEmpty) return null;
    if (values.length == 1) return values.first;
    return values;
  }

  /// Reads a 64-bit integer field, consuming the full [size]. Values are
  /// combined from two 32-bit halves in double arithmetic (web-safe; exact up
  /// to 2^53, beyond which sensor data does not occur in practice). Each
  /// element is checked against the invalid sentinel (sint64 0x7FFF…, uint64
  /// 0xFFFF…) individually and dropped rather than kept (see [_readNumeric]).
  /// Returns a scalar `num` when exactly one element survives, a `List<num>`
  /// when more than one does, or null when none do.
  Object? _readInt64(int size, {required bool signed, required Endian endian}) {
    if (size <= 0 || position >= bytes.length) {
      position = bytes.length;
      return null;
    }
    final available = bytes.length - position;
    final safe = size > available ? available : size;
    final count = safe ~/ 8;
    if (count <= 0) {
      position += safe;
      return null;
    }
    final data = bytes.buffer.asByteData();
    final values = <num>[];
    for (var i = 0; i < count; i++) {
      final offset = position + i * 8;
      final first = data.getUint32(offset, endian);
      final second = data.getUint32(offset + 4, endian);
      final lo = endian == Endian.little ? first : second;
      final hi = endian == Endian.little ? second : first;
      final invalid = signed
          ? hi == 0x7FFFFFFF && lo == 0xFFFFFFFF
          : hi == 0xFFFFFFFF && lo == 0xFFFFFFFF;
      if (invalid) continue;
      final unsignedValue = hi.toDouble() * 4294967296.0 + lo.toDouble();
      values.add(
        signed && (hi & 0x80000000) != 0
            ? unsignedValue - 18446744073709551616.0
            : unsignedValue,
      );
    }
    position += safe;
    if (values.isEmpty) return null;
    if (values.length == 1) return values.first;
    return values;
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
