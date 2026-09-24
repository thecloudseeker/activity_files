// SPDX-License-Identifier: BSD-3-Clause
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import '../channel_mapper.dart';
import '../fit/fit_crc.dart';
import '../fit/fit_epoch.dart';
import '../fit/fit_record_fields.dart';
import '../fit/fit_sport.dart';
import '../models.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';

part 'fit_encoder_internals.dart';

/// Encoder for FIT payloads (limited profile support).
///
/// The emitted binary stream contains the following message sequence:
/// * file_id (global 0)
/// * session (global 18) with sport and the full activity summary
///   (including swim metrics, sub-sport, and total cycles)
/// * zero or more lap messages (global 19) with per-lap metrics
/// * zero or more set messages (global 225) for strength-training sets
/// * record messages (global 20) for each geographic sample
///
/// Absent optional values are encoded as FIT invalid sentinels so they
/// round-trip as null.
///
/// The resulting binary is returned as base64 so that callers can safely handle
/// it using existing string-oriented APIs.
class FitEncoder implements ActivityFormatEncoder {
  const FitEncoder();
  @override
  String encode(RawActivity activity, EncoderOptions options) {
    // FIT output is a single flat record stream; merge multi-track input.
    activity = activity.flattened();
    final recordSamples = _recordSamples(activity);
    if (recordSamples.isEmpty) {
      throw ArgumentError(
        'Cannot encode empty activity to FIT. Activity must contain at least geographic points or sensor samples.\n'
        '\n'
        'The activity has no data:\n'
        '  • GPS points: ${activity.points.length}\n'
        '  • Sensor channels: ${activity.channels.length}\n'
        '\n'
        'To fix this:\n'
        '  1. Add GPS trackpoints: builder.addPoint(lat, lon, elevation, time)\n'
        '  2. Or add sensor data: builder.addSample(Channel.heartRate, time, value)\n'
        '  3. Or import data from a file: await ActivityFiles.import(File("activity.gpx"))\n'
        '\n'
        'FIT requires at least one data point to be valid.',
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
    // device_info (23) and file_creator (49): the parser reads the device
    // block back from these, so manufacturer, serial, product, software
    // version, and model survive FIT export instead of being dropped.
    if (deviceMetadata != null) {
      const deviceInfoLocal = 9;
      final modelBytes = _utf8Field(deviceMetadata.model);
      encoder.writeDefinition(
        definitionSection,
        localId: deviceInfoLocal,
        globalId: 23,
        fields: [
          const _FitField(number: 2, size: 2, type: _FitBaseType.uint16),
          const _FitField(number: 3, size: 4, type: _FitBaseType.uint32z),
          const _FitField(number: 4, size: 2, type: _FitBaseType.uint16),
          const _FitField(number: 5, size: 2, type: _FitBaseType.uint16),
          if (modelBytes != null)
            _FitField(
              number: 27,
              size: modelBytes.length + 1,
              type: _FitBaseType.string,
            ),
        ],
      );
      final softwareVersionRaw = _encodeFitSoftwareVersion(
        deviceMetadata.softwareVersion,
      );
      encoder.writeDeviceInfo(
        dataSection,
        localId: deviceInfoLocal,
        manufacturer:
            deviceMetadata.fitManufacturerId ??
            _fitManufacturerId(deviceMetadata.manufacturer),
        serialNumber: _parseFitUint(deviceMetadata.serialNumber),
        product:
            deviceMetadata.fitProductId ??
            _parseFitUint(deviceMetadata.product),
        softwareVersion: softwareVersionRaw,
        productNameBytes: modelBytes,
      );
      if (softwareVersionRaw != null) {
        const fileCreatorLocal = 10;
        encoder.writeDefinition(
          definitionSection,
          localId: fileCreatorLocal,
          globalId: 49,
          fields: const [
            _FitField(number: 0, size: 2, type: _FitBaseType.uint16),
          ],
        );
        encoder.writeFileCreator(
          dataSection,
          localId: fileCreatorLocal,
          softwareVersion: softwareVersionRaw,
        );
      }
    }
    // Session message: sport plus the full activity summary (all fields the
    // FIT parser reads back; absent values are written as FIT invalid
    // sentinels so they round-trip as null).
    const sessionLocal = 1;
    // Shared layout for every session's unmodeled fields (primary + additional
    // sessions), so each keeps its raw metrics (total_ascent, normalized_power,
    // …) instead of dropping them on FIT -> FIT.
    final sessionExtras = _unionExtraFields([
      if (activity.summary != null) activity.summary!.extraFitFields,
      for (final session in activity.additionalSessions) session.extraFitFields,
    ]);
    final sessionArrays = _unionExtraArrays([
      if (activity.summary != null) activity.summary!.extraFitArrays,
      for (final session in activity.additionalSessions) session.extraFitArrays,
    ]);
    encoder.writeDefinition(
      definitionSection,
      localId: sessionLocal,
      globalId: 18,
      fields: [
        _FitField(number: 253, size: 4, type: _FitBaseType.uint32), // timestamp
        _FitField(number: 5, size: 1, type: _FitBaseType.enumType), // sport
        _FitField(number: 6, size: 1, type: _FitBaseType.enumType), // sub_sport
        // total_elapsed_time / total_timer_time (s, scale 1000)
        _FitField(number: 7, size: 4, type: _FitBaseType.uint32),
        _FitField(number: 8, size: 4, type: _FitBaseType.uint32),
        _FitField(
          number: 9,
          size: 4,
          type: _FitBaseType.uint32,
        ), // total_distance (m, scale 100)
        _FitField(
          number: 10,
          size: 4,
          type: _FitBaseType.uint32,
        ), // total_cycles
        _FitField(
          number: 11,
          size: 2,
          type: _FitBaseType.uint16,
        ), // total_calories
        // avg/max_speed (m/s, scale 1000)
        _FitField(number: 14, size: 2, type: _FitBaseType.uint16),
        _FitField(number: 15, size: 2, type: _FitBaseType.uint16),
        // avg/max_heart_rate, avg/max_cadence
        _FitField(number: 16, size: 1, type: _FitBaseType.uint8),
        _FitField(number: 17, size: 1, type: _FitBaseType.uint8),
        _FitField(number: 18, size: 1, type: _FitBaseType.uint8),
        _FitField(number: 19, size: 1, type: _FitBaseType.uint8),
        // avg/max_power
        _FitField(number: 20, size: 2, type: _FitBaseType.uint16),
        _FitField(number: 21, size: 2, type: _FitBaseType.uint16),
        _FitField(
          number: 41,
          size: 2,
          type: _FitBaseType.uint16,
        ), // avg_stroke_count (scale 10)
        _FitField(
          number: 43,
          size: 1,
          type: _FitBaseType.enumType,
        ), // swim_stroke
        _FitField(
          number: 44,
          size: 2,
          type: _FitBaseType.uint16,
        ), // pool_length (m, scale 100)
        _FitField(
          number: 47,
          size: 2,
          type: _FitBaseType.uint16,
        ), // num_active_lengths
        for (final field in sessionExtras)
          _FitField(
            number: field.number,
            size: 4,
            type: field.signed ? _FitBaseType.sint32 : _FitBaseType.uint32,
          ),
        for (final field in sessionArrays)
          _FitField(
            number: field.number,
            size: field.count * 4,
            type: field.signed ? _FitBaseType.sint32 : _FitBaseType.uint32,
          ),
      ],
    );
    encoder.writeSession(
      dataSection,
      localId: sessionLocal,
      timestamp: recordSamples.first.time,
      sport: activity.sport,
      summary: activity.summary,
      extraFields: sessionExtras,
      extraArrays: sessionArrays,
    );
    // Additional sessions from multi-session files (e.g. triathlon legs),
    // each with its own sport and statistics.
    for (final session in activity.additionalSessions) {
      encoder.writeSession(
        dataSection,
        localId: sessionLocal,
        timestamp: recordSamples.first.time,
        sport: session.sport ?? activity.sport,
        summary: session,
        extraFields: sessionExtras,
        extraArrays: sessionArrays,
      );
    }
    // Lap messages (optional), carrying the full per-lap metric set plus a
    // shared layout for any unmodeled lap fields so they round-trip.
    const lapLocal = 2;
    final lapExtras = _unionExtraFields([
      for (final lap in activity.laps) lap.extraFitFields,
    ]);
    final lapArrays = _unionExtraArrays([
      for (final lap in activity.laps) lap.extraFitArrays,
    ]);
    if (activity.laps.isNotEmpty) {
      encoder.writeDefinition(
        definitionSection,
        localId: lapLocal,
        globalId: 19,
        fields: [
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
          ), // total_elapsed_time (s, scale 1000)
          _FitField(
            number: 9,
            size: 4,
            type: _FitBaseType.uint32,
          ), // total_distance (m, scale 100)
          _FitField(number: 0, size: 1, type: _FitBaseType.enumType), // event
          _FitField(
            number: 1,
            size: 1,
            type: _FitBaseType.enumType,
          ), // event_type
          _FitField(
            number: 11,
            size: 2,
            type: _FitBaseType.uint16,
          ), // total_calories
          // avg/max_speed (m/s, scale 1000)
          _FitField(number: 13, size: 2, type: _FitBaseType.uint16),
          _FitField(number: 14, size: 2, type: _FitBaseType.uint16),
          // avg/max_heart_rate, avg/max_cadence
          _FitField(number: 15, size: 1, type: _FitBaseType.uint8),
          _FitField(number: 16, size: 1, type: _FitBaseType.uint8),
          _FitField(number: 17, size: 1, type: _FitBaseType.uint8),
          _FitField(number: 18, size: 1, type: _FitBaseType.uint8),
          // avg/max_power
          _FitField(number: 19, size: 2, type: _FitBaseType.uint16),
          _FitField(number: 20, size: 2, type: _FitBaseType.uint16),
          _FitField(
            number: 38,
            size: 1,
            type: _FitBaseType.enumType,
          ), // swim_stroke
          _FitField(
            number: 40,
            size: 2,
            type: _FitBaseType.uint16,
          ), // num_active_lengths
          for (final field in lapExtras)
            _FitField(
              number: field.number,
              size: 4,
              type: field.signed ? _FitBaseType.sint32 : _FitBaseType.uint32,
            ),
          for (final field in lapArrays)
            _FitField(
              number: field.number,
              size: field.count * 4,
              type: field.signed ? _FitBaseType.sint32 : _FitBaseType.uint32,
            ),
        ],
      );
      for (final lap in activity.laps) {
        encoder.writeLap(
          dataSection,
          localId: lapLocal,
          lap: lap,
          extraFields: lapExtras,
          extraArrays: lapArrays,
        );
      }
    }
    // Event messages (global 21): timer start/stop pairs carry the pause
    // structure of the activity.
    const eventLocal = 5;
    if (activity.events.isNotEmpty) {
      encoder.writeDefinition(
        definitionSection,
        localId: eventLocal,
        globalId: 21,
        fields: const [
          _FitField(
            number: 253,
            size: 4,
            type: _FitBaseType.uint32,
          ), // timestamp
          _FitField(number: 0, size: 1, type: _FitBaseType.enumType), // event
          _FitField(
            number: 1,
            size: 1,
            type: _FitBaseType.enumType,
          ), // event_type
          _FitField(number: 3, size: 4, type: _FitBaseType.uint32), // data
        ],
      );
      for (final event in activity.events) {
        encoder.writeEvent(dataSection, localId: eventLocal, event: event);
      }
    }
    // Length messages (global 101): per-length pool-swim data.
    const lengthLocal = 6;
    if (activity.lengths.isNotEmpty) {
      encoder.writeDefinition(
        definitionSection,
        localId: lengthLocal,
        globalId: 101,
        fields: const [
          _FitField(
            number: 253,
            size: 4,
            type: _FitBaseType.uint32,
          ), // timestamp (end)
          _FitField(
            number: 2,
            size: 4,
            type: _FitBaseType.uint32,
          ), // start_time
          _FitField(
            number: 3,
            size: 4,
            type: _FitBaseType.uint32,
          ), // total_elapsed_time (s, scale 1000)
          _FitField(
            number: 5,
            size: 2,
            type: _FitBaseType.uint16,
          ), // total_strokes
          _FitField(
            number: 6,
            size: 2,
            type: _FitBaseType.uint16,
          ), // avg_speed (m/s, scale 1000)
          _FitField(
            number: 7,
            size: 1,
            type: _FitBaseType.enumType,
          ), // swim_stroke
          _FitField(
            number: 12,
            size: 1,
            type: _FitBaseType.enumType,
          ), // length_type
        ],
      );
      for (final length in activity.lengths) {
        encoder.writeLength(dataSection, localId: lengthLocal, length: length);
      }
    }
    // Set messages (global 225) for strength-training sets.
    const setLocal = 4;
    if (activity.sets.isNotEmpty) {
      encoder.writeDefinition(
        definitionSection,
        localId: setLocal,
        globalId: 225,
        fields: const [
          _FitField(
            number: 254,
            size: 4,
            type: _FitBaseType.uint32,
          ), // timestamp (set end)
          _FitField(
            number: 6,
            size: 4,
            type: _FitBaseType.uint32,
          ), // start_time
          _FitField(
            number: 0,
            size: 4,
            type: _FitBaseType.uint32,
          ), // duration (s, scale 1000)
          _FitField(
            number: 5,
            size: 1,
            type: _FitBaseType.uint8,
          ), // set_type (0 rest, 1 active)
          _FitField(
            number: 3,
            size: 2,
            type: _FitBaseType.uint16,
          ), // repetitions
          _FitField(
            number: 4,
            size: 2,
            type: _FitBaseType.uint16,
          ), // weight (kg, scale 16)
          _FitField(number: 7, size: 2, type: _FitBaseType.uint16), // category
        ],
      );
      for (final set in activity.sets) {
        encoder.writeSet(dataSection, localId: setLocal, set: set);
      }
    }
    // Record definition: the fixed geo fields (timestamp/lat/long/altitude)
    // plus every sensor channel present. Beyond the six well-known channels we
    // re-emit the FIT-specific channels the parser captures — grade,
    // left_right_balance, and any generic `fit_field_<n>` field — so a
    // FIT -> RawActivity -> FIT round-trip preserves every native record field
    // rather than dropping the unknowns.
    const recordLocal = 3;
    final optionalFields = _optionalRecordFields(activity);
    // Developer-field write-back: every channel that is neither a native
    // record field nor a captured fit_field_<n> is re-emitted as a float64
    // FIT developer field, described by developer_data_id (207) and
    // field_description (206) messages — cross-format custom channels
    // (water_temperature, depth, …) and imported developer channels survive
    // FIT export instead of being dropped.
    final developerChannels = _developerChannels(activity);
    if (developerChannels.isNotEmpty) {
      const developerDataLocal = 7;
      const fieldDescriptionLocal = 8;
      // Definitions AND data messages go into the definition section:
      // decoders resolve developer types when they read the record
      // definition, so the descriptions must precede it in the byte stream.
      encoder.writeDefinition(
        definitionSection,
        localId: developerDataLocal,
        globalId: 207,
        fields: const [_FitField(number: 3, size: 1, type: _FitBaseType.uint8)],
      );
      definitionSection.addByte(developerDataLocal);
      definitionSection.addByte(0); // developer_data_index 0
      for (var i = 0; i < developerChannels.length; i++) {
        final nameBytes = _utf8Field(developerChannels[i].id)!;
        encoder.writeDefinition(
          definitionSection,
          localId: fieldDescriptionLocal,
          globalId: 206,
          fields: [
            const _FitField(number: 0, size: 1, type: _FitBaseType.uint8),
            const _FitField(number: 1, size: 1, type: _FitBaseType.uint8),
            const _FitField(number: 2, size: 1, type: _FitBaseType.uint8),
            _FitField(
              number: 3,
              size: nameBytes.length + 1,
              type: _FitBaseType.string,
            ),
          ],
        );
        definitionSection.addByte(fieldDescriptionLocal);
        definitionSection.addByte(0); // developer_data_index
        definitionSection.addByte(i); // field_definition_number
        definitionSection.addByte(_FitBaseType.float64.code);
        encoder.writeString(definitionSection, nameBytes);
      }
    }
    final recordFields = <_FitField>[
      const _FitField(number: 253, size: 4, type: _FitBaseType.uint32),
      const _FitField(number: 0, size: 4, type: _FitBaseType.sint32),
      const _FitField(number: 1, size: 4, type: _FitBaseType.sint32),
      const _FitField(number: 2, size: 2, type: _FitBaseType.uint16),
      for (final field in optionalFields)
        _FitField(number: field.number, size: field.size, type: field.type),
    ];
    encoder.writeDefinition(
      definitionSection,
      localId: recordLocal,
      globalId: 20,
      fields: recordFields,
      developerFields: [
        for (var i = 0; i < developerChannels.length; i++)
          _FitDeveloperFieldSpec(fieldNumber: i, size: 8, developerIndex: 0),
      ],
    );
    var searchDelta = options.defaultMaxDelta;
    for (final field in optionalFields) {
      final delta = options.maxDeltaFor(field.channel);
      if (delta > searchDelta) searchDelta = delta;
    }
    for (final channel in developerChannels) {
      final delta = options.maxDeltaFor(channel);
      if (delta > searchDelta) searchDelta = delta;
    }
    final channelCursor = ChannelMapper.cursor(
      activity.channels,
      maxDelta: searchDelta,
    );
    for (final sample in recordSamples) {
      final timestampSeconds = fitSecondsSinceEpoch(sample.time);
      final lat = sample.latitude != null
          ? (sample.latitude! * 2147483648.0 / 180.0).round()
          : _invalidSemicircle;
      final lon = sample.longitude != null
          ? (sample.longitude! * 2147483648.0 / 180.0).round()
          : _invalidSemicircle;
      final altitudeRaw = _encodeAltitude(sample.elevation);
      final snapshot = channelCursor.snapshot(sample.time);
      encoder.writeRecord(
        dataSection,
        localId: recordLocal,
        timestampSeconds: timestampSeconds,
        latitude: lat,
        longitude: lon,
        altitudeRaw: altitudeRaw,
        optionalFields: optionalFields,
        optionalValues: [
          for (final field in optionalFields)
            _valueWithinChannel(
              snapshot,
              field.channel,
              options.maxDeltaFor(field.channel),
            ),
        ],
        developerValues: [
          for (final channel in developerChannels)
            _valueWithinChannel(
              snapshot,
              channel,
              options.maxDeltaFor(channel),
            ),
        ],
      );
    }
    final dataBytes = dataSection.toBytes();
    final headerBytes = definitionSection.toBytes();
    builder.add(headerBytes);
    builder.add(dataBytes);
    final fullData = builder.toBytes();
    final header = _createHeader(fullData.length);
    // The trailer CRC covers header + data per the FIT spec. (With a valid
    // header CRC the data-only range happens to yield the same value — the
    // CRC state returns to zero after a block ending with its own CRC — but
    // the full range keeps this correct if the header ever changes.)
    final combined = BytesBuilder()
      ..add(header)
      ..add(fullData);
    final crc = computeFitCrc(combined.toBytes());
    combined
      ..addByte(crc & 0xFF)
      ..addByte((crc >> 8) & 0xFF);
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
