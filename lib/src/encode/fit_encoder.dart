// SPDX-License-Identifier: BSD-3-Clause
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import '../channel_mapper.dart';
import '../fit/fit_crc.dart';
import '../fit/fit_sport.dart';
import '../models.dart';
import 'activity_encoder.dart';
import 'encoder_options.dart';

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
        '  3. Or load data from a file: await ActivityFiles.load(File("activity.gpx"))\n'
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
    final baseTime = DateTime.utc(1989, 12, 31);
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

/// Encodes a software version string ("9.75") as the scale-100 uint16 used
/// by device_info/file_creator, or null when it is not numeric.
int? _encodeFitSoftwareVersion(String? version) {
  if (version == null) {
    return null;
  }
  final value = double.tryParse(version.trim());
  if (value == null || value <= 0) {
    return null;
  }
  return (value * 100).round();
}

/// UTF-8 bytes for a FIT string field, truncated to 63 bytes on a character
/// boundary; null for absent or empty values.
List<int>? _utf8Field(String? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  var bytes = utf8.encode(trimmed);
  if (bytes.length > 63) {
    var end = 63;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    bytes = bytes.sublist(0, end);
  }
  return bytes;
}

/// Channels re-emitted as FIT developer fields: everything that is neither a
/// native record channel nor a captured `fit_field_<n>` native field, sorted
/// by id for deterministic field numbering. Capped at 255 (the field number
/// is a single byte); more custom channels than that do not occur in
/// practice.
List<Channel> _developerChannels(RawActivity activity) {
  final nativeChannels = {
    for (final spec in _knownRecordChannels) spec.channel,
  };
  final channels = <Channel>[
    for (final entry in activity.channels.entries)
      if (entry.value.isNotEmpty &&
          !nativeChannels.contains(entry.key) &&
          _fitFieldNumber(entry.key) == null)
        entry.key,
  ]..sort((a, b) => a.id.compareTo(b.id));
  return channels.length > 255 ? channels.sublist(0, 255) : channels;
}

class _FitMessageEncoder {
  void writeDefinition(
    BytesBuilder destination, {
    required int localId,
    required int globalId,
    required List<_FitField> fields,
    List<_FitDeveloperFieldSpec> developerFields = const [],
  }) {
    // Bit 0x20 marks a definition that carries developer field references.
    final headerBits = developerFields.isEmpty ? 0x40 : 0x60;
    destination.addByte(headerBits | (localId & 0x0F));
    destination.addByte(0); // reserved
    destination.addByte(0); // little-endian architecture
    final bd = ByteData(2)..setUint16(0, globalId, Endian.little);
    destination.add(bd.buffer.asUint8List());
    destination.addByte(fields.length);
    for (final field in fields) {
      destination.add(field.encode());
    }
    if (developerFields.isNotEmpty) {
      destination.addByte(developerFields.length);
      for (final field in developerFields) {
        destination.addByte(field.fieldNumber);
        destination.addByte(field.size);
        destination.addByte(field.developerIndex);
      }
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

  /// Writes a device_info (23) data message: manufacturer, serial number,
  /// product, software version (scale 100), and optional product_name.
  /// Absent values encode as invalid sentinels and parse back as null.
  void writeDeviceInfo(
    BytesBuilder destination, {
    required int localId,
    required int? manufacturer,
    required int? serialNumber,
    required int? product,
    required int? softwareVersion,
    required List<int>? productNameBytes,
  }) {
    destination.addByte(localId);
    _writeUint16(destination, manufacturer);
    _writeUint32(destination, serialNumber);
    _writeUint16(destination, product);
    _writeUint16(destination, softwareVersion);
    if (productNameBytes != null) {
      writeString(destination, productNameBytes);
    }
  }

  /// Writes a file_creator (49) data message carrying the software version
  /// (scale 100, matching device_info and the parser's decoding).
  void writeFileCreator(
    BytesBuilder destination, {
    required int localId,
    required int softwareVersion,
  }) {
    destination.addByte(localId);
    _writeUint16(destination, softwareVersion);
  }

  static final DateTime _fitEpoch = DateTime.utc(1989, 12, 31);

  static int _fitSeconds(DateTime time) =>
      time.toUtc().difference(_fitEpoch).inSeconds;

  /// Scales a value for FIT encoding; null stays null (invalid sentinel).
  static int? _scaled(double? value, int scale) =>
      value == null ? null : (value * scale).round();

  /// Writes a uint8/enum byte; null becomes the FIT invalid value 0xFF.
  /// Valid values are clamped to 0xFE so they never collide with invalid.
  void _writeByte(BytesBuilder destination, int? value) =>
      destination.addByte(value == null ? 0xFF : value.clamp(0, 0xFE));

  void _writeUint16(BytesBuilder destination, int? value) {
    final bd = ByteData(2)
      ..setUint16(
        0,
        value == null ? 0xFFFF : value.clamp(0, 0xFFFE),
        Endian.little,
      );
    destination.add(bd.buffer.asUint8List());
  }

  void _writeUint32(BytesBuilder destination, int? value) {
    final bd = ByteData(4)
      ..setUint32(
        0,
        value == null ? 0xFFFFFFFF : value.clamp(0, 0xFFFFFFFE),
        Endian.little,
      );
    destination.add(bd.buffer.asUint8List());
  }

  /// Writes a raw 4-byte extra field; null becomes the FIT invalid sentinel.
  void _writeRawInt32(
    BytesBuilder destination,
    double? value, {
    required bool signed,
  }) {
    final bd = ByteData(4);
    if (value == null) {
      bd.setUint32(0, signed ? 0x7FFFFFFF : 0xFFFFFFFF, Endian.little);
    } else if (signed) {
      bd.setInt32(
        0,
        value.round().clamp(-2147483648, 2147483647),
        Endian.little,
      );
    } else {
      bd.setUint32(0, _clampUint32(value.round()), Endian.little);
    }
    destination.add(bd.buffer.asUint8List());
  }

  /// Writes the shared extra-field layout for a session/lap message, pulling
  /// each field's value from [values] (invalid sentinel when absent).
  void _writeExtraFields(
    BytesBuilder destination,
    List<_ExtraFitField> fields,
    Map<int, double> values,
  ) {
    for (final field in fields) {
      _writeRawInt32(destination, values[field.number], signed: field.signed);
    }
  }

  /// Writes the shared array-field layout for a session/lap message: each
  /// field's elements padded to the definition's element count with invalid
  /// sentinels (a whole missing field is all-invalid).
  void _writeExtraArrays(
    BytesBuilder destination,
    List<_ExtraArrayField> fields,
    Map<int, List<double>> values,
  ) {
    for (final field in fields) {
      final array = values[field.number];
      for (var i = 0; i < field.count; i++) {
        final value = array != null && i < array.length ? array[i] : null;
        _writeRawInt32(destination, value, signed: field.signed);
      }
    }
  }

  /// Field order must match the session definition in [FitEncoder.encode].
  void writeSession(
    BytesBuilder destination, {
    required int localId,
    required DateTime timestamp,
    required Sport sport,
    ActivitySummary? summary,
    List<_ExtraFitField> extraFields = const [],
    List<_ExtraArrayField> extraArrays = const [],
  }) {
    destination.addByte(localId);
    _writeUint32(destination, _fitSeconds(timestamp));
    destination.addByte(fitIdFromSport(sport));
    _writeByte(destination, summary?.subSport);
    _writeUint32(destination, summary?.elapsedTime?.inMilliseconds);
    _writeUint32(destination, summary?.timerTime?.inMilliseconds);
    _writeUint32(destination, _scaled(summary?.totalDistanceMeters, 100));
    _writeUint32(destination, summary?.totalCycles);
    _writeUint16(destination, summary?.calories?.round());
    _writeUint16(destination, _scaled(summary?.avgSpeed, 1000));
    _writeUint16(destination, _scaled(summary?.maxSpeed, 1000));
    _writeByte(destination, summary?.avgHeartRate?.round());
    _writeByte(destination, summary?.maxHeartRate?.round());
    _writeByte(destination, summary?.avgCadence?.round());
    _writeByte(destination, summary?.maxCadence?.round());
    _writeUint16(destination, summary?.avgPower?.round());
    _writeUint16(destination, summary?.maxPower?.round());
    _writeUint16(destination, _scaled(summary?.avgStrokeCount, 10));
    _writeByte(destination, summary?.swimStroke?.index);
    _writeUint16(destination, _scaled(summary?.poolLengthMeters, 100));
    _writeUint16(destination, summary?.numActiveLengths);
    _writeExtraFields(
      destination,
      extraFields,
      summary?.extraFitFields ?? const {},
    );
    _writeExtraArrays(
      destination,
      extraArrays,
      summary?.extraFitArrays ?? const {},
    );
  }

  /// Field order must match the lap definition in [FitEncoder.encode].
  void writeLap(
    BytesBuilder destination, {
    required int localId,
    required Lap lap,
    List<_ExtraFitField> extraFields = const [],
    List<_ExtraArrayField> extraArrays = const [],
  }) {
    destination.addByte(localId);
    _writeUint32(destination, _fitSeconds(lap.endTime));
    _writeUint32(destination, _fitSeconds(lap.startTime));
    _writeUint32(destination, lap.elapsed.inMilliseconds);
    _writeUint32(destination, _scaled(lap.distanceMeters, 100));
    _writeByte(destination, lap.event);
    _writeByte(destination, lap.eventType);
    _writeUint16(destination, lap.calories?.round());
    _writeUint16(destination, _scaled(lap.avgSpeed, 1000));
    _writeUint16(destination, _scaled(lap.maxSpeed, 1000));
    _writeByte(destination, lap.avgHeartRate?.round());
    _writeByte(destination, lap.maxHeartRate?.round());
    _writeByte(destination, lap.avgCadence?.round());
    _writeByte(destination, lap.maxCadence?.round());
    _writeUint16(destination, lap.avgPower?.round());
    _writeUint16(destination, lap.maxPower?.round());
    _writeByte(destination, lap.swimStroke?.index);
    _writeUint16(destination, lap.numActiveLengths);
    _writeExtraFields(destination, extraFields, lap.extraFitFields);
    _writeExtraArrays(destination, extraArrays, lap.extraFitArrays);
  }

  /// Field order must match the event definition in [FitEncoder.encode].
  void writeEvent(
    BytesBuilder destination, {
    required int localId,
    required ActivityEvent event,
  }) {
    destination.addByte(localId);
    _writeUint32(destination, _fitSeconds(event.time));
    _writeByte(destination, event.event);
    _writeByte(destination, event.eventType);
    _writeUint32(destination, event.data);
  }

  /// Field order must match the length definition in [FitEncoder.encode].
  void writeLength(
    BytesBuilder destination, {
    required int localId,
    required SwimLength length,
  }) {
    destination.addByte(localId);
    _writeUint32(destination, _fitSeconds(length.endTime));
    _writeUint32(destination, _fitSeconds(length.startTime));
    _writeUint32(destination, length.elapsed.inMilliseconds);
    _writeUint16(destination, length.totalStrokes);
    _writeUint16(destination, _scaled(length.avgSpeed, 1000));
    _writeByte(destination, length.swimStroke?.index);
    _writeByte(destination, length.isActive ? 1 : 0);
  }

  /// Field order must match the set definition in [FitEncoder.encode].
  void writeSet(
    BytesBuilder destination, {
    required int localId,
    required WorkoutSet set,
  }) {
    destination.addByte(localId);
    _writeUint32(destination, _fitSeconds(set.endTime));
    _writeUint32(destination, _fitSeconds(set.startTime));
    _writeUint32(destination, set.elapsed.inMilliseconds);
    _writeByte(destination, set.isRest ? 0 : 1);
    _writeUint16(destination, set.repetitions);
    _writeUint16(destination, _scaled(set.weightKg, 16));
    _writeUint16(destination, set.exerciseCategoryId);
  }

  void writeRecord(
    BytesBuilder destination, {
    required int localId,
    required int timestampSeconds,
    required int latitude,
    required int longitude,
    required int altitudeRaw,
    required List<_OptionalRecordField> optionalFields,
    required List<double?> optionalValues,
    List<double?> developerValues = const [],
  }) {
    destination.addByte(localId);
    final bd = ByteData(12);
    bd.setUint32(0, timestampSeconds, Endian.little);
    bd.setInt32(4, latitude, Endian.little);
    bd.setInt32(8, longitude, Endian.little);
    destination.add(bd.buffer.asUint8List());
    final altData = ByteData(2)..setUint16(0, altitudeRaw, Endian.little);
    destination.add(altData.buffer.asUint8List());
    for (var i = 0; i < optionalFields.length; i++) {
      _writeOptionalField(destination, optionalFields[i], optionalValues[i]);
    }
    for (final value in developerValues) {
      writeFloat64(destination, value);
    }
  }

  /// Writes one optional record field, applying its scale and encoding a null
  /// as the base type's FIT invalid sentinel so it round-trips back to null.
  void _writeOptionalField(
    BytesBuilder destination,
    _OptionalRecordField field,
    double? value,
  ) {
    final scaled = value == null ? null : (value * field.scale).round();
    switch (field.type) {
      case _FitBaseType.enumType:
      case _FitBaseType.uint8:
      case _FitBaseType.uint32z:
        destination.addByte(scaled == null ? 0xFF : scaled.clamp(0, 0xFE));
        break;
      case _FitBaseType.sint8:
        final bd = ByteData(1)
          ..setInt8(0, scaled == null ? 0x7F : scaled.clamp(-128, 127));
        destination.add(bd.buffer.asUint8List());
        break;
      case _FitBaseType.sint16:
        final bd = ByteData(2)
          ..setInt16(
            0,
            scaled == null ? 0x7FFF : scaled.clamp(-32768, 32767),
            Endian.little,
          );
        destination.add(bd.buffer.asUint8List());
        break;
      case _FitBaseType.uint16:
        final bd = ByteData(2)
          ..setUint16(
            0,
            scaled == null ? 0xFFFF : _clampUint16(scaled),
            Endian.little,
          );
        destination.add(bd.buffer.asUint8List());
        break;
      case _FitBaseType.sint32:
        final bd = ByteData(4)
          ..setInt32(
            0,
            scaled == null ? 0x7FFFFFFF : scaled.clamp(-2147483648, 2147483647),
            Endian.little,
          );
        destination.add(bd.buffer.asUint8List());
        break;
      case _FitBaseType.uint32:
        final bd = ByteData(4)
          ..setUint32(
            0,
            scaled == null ? 0xFFFFFFFF : _clampUint32(scaled),
            Endian.little,
          );
        destination.add(bd.buffer.asUint8List());
        break;
      case _FitBaseType.float64:
        writeFloat64(destination, value);
        break;
      case _FitBaseType.string:
        // Strings are only used for standalone metadata fields
        // (product_name, field_name), never as record channels.
        throw StateError('String fields cannot carry channel samples.');
    }
  }

  /// Writes a float64 value; null becomes the FIT invalid sentinel (the
  /// all-ones bit pattern), which parses back as null.
  void writeFloat64(BytesBuilder destination, double? value) {
    if (value == null) {
      destination.add(_float64Invalid);
      return;
    }
    final bd = ByteData(8)..setFloat64(0, value, Endian.little);
    destination.add(bd.buffer.asUint8List());
  }

  static final Uint8List _float64Invalid = Uint8List.fromList(
    List.filled(8, 0xFF),
  );

  /// Writes a null-terminated UTF-8 string sized to match its definition
  /// entry (byte length of [utf8Bytes] plus the terminator).
  void writeString(BytesBuilder destination, List<int> utf8Bytes) {
    destination.add(utf8Bytes);
    destination.addByte(0);
  }
}

/// Describes a non-geo record field the encoder emits, mapping a [Channel]
/// back to its native FIT record field number, base type, and scale factor.
class _OptionalRecordField {
  const _OptionalRecordField({
    required this.channel,
    required this.number,
    required this.size,
    required this.type,
    required this.scale,
  });
  final Channel channel;
  final int number;
  final int size;
  final _FitBaseType type;
  final double scale;
}

/// Well-known channels with dedicated FIT record field numbers. `grade` and
/// `left_right_balance` mirror the names the parser assigns to record fields
/// 78 and 120 so those round-trip natively instead of via `fit_field_<n>`.
final List<_OptionalRecordField> _knownRecordChannels = [
  const _OptionalRecordField(
    channel: Channel.heartRate,
    number: 3,
    size: 1,
    type: _FitBaseType.uint8,
    scale: 1,
  ),
  const _OptionalRecordField(
    channel: Channel.cadence,
    number: 4,
    size: 1,
    type: _FitBaseType.uint8,
    scale: 1,
  ),
  const _OptionalRecordField(
    channel: Channel.distance,
    number: 5,
    size: 4,
    type: _FitBaseType.uint32,
    scale: 100,
  ),
  const _OptionalRecordField(
    channel: Channel.speed,
    number: 6,
    size: 2,
    type: _FitBaseType.uint16,
    scale: 1000,
  ),
  const _OptionalRecordField(
    channel: Channel.power,
    number: 7,
    size: 2,
    type: _FitBaseType.uint16,
    scale: 1,
  ),
  const _OptionalRecordField(
    channel: Channel.temperature,
    number: 13,
    size: 1,
    type: _FitBaseType.sint8,
    scale: 1,
  ),
  _OptionalRecordField(
    channel: Channel.custom('grade'),
    number: 78,
    size: 2,
    type: _FitBaseType.sint16,
    scale: 100,
  ),
  _OptionalRecordField(
    channel: Channel.custom('left_right_balance'),
    number: 120,
    size: 2,
    type: _FitBaseType.uint16,
    scale: 1,
  ),
];

/// Builds the ordered list of optional record fields for [activity]: the
/// present well-known channels first, then every generic `fit_field_<n>`
/// channel the parser captured, so no native record field is dropped.
List<_OptionalRecordField> _optionalRecordFields(RawActivity activity) {
  final fields = <_OptionalRecordField>[];
  final seen = <int>{253, 0, 1, 2};
  void add(_OptionalRecordField field) {
    if (seen.add(field.number)) fields.add(field);
  }

  for (final spec in _knownRecordChannels) {
    if (activity.channel(spec.channel).isNotEmpty) add(spec);
  }
  for (final entry in activity.channels.entries) {
    final number = _fitFieldNumber(entry.key);
    if (number == null || seen.contains(number)) continue;
    // A single record field carries one base type; pick a signed 32-bit
    // integer when any sample is negative, otherwise unsigned. Values were
    // captured raw (unscaled), so no scale is reapplied.
    final signed = entry.value.any((sample) => sample.value < 0);
    add(
      _OptionalRecordField(
        channel: entry.key,
        number: number,
        size: 4,
        type: signed ? _FitBaseType.sint32 : _FitBaseType.uint32,
        scale: 1,
      ),
    );
  }
  return fields;
}

/// Recovers the native FIT record field number from a `fit_field_<n>` channel
/// id, or null if the channel is not a generic captured record field.
int? _fitFieldNumber(Channel channel) {
  const prefix = 'fit_field_';
  if (!channel.id.startsWith(prefix)) return null;
  final number = int.tryParse(channel.id.substring(prefix.length));
  if (number == null || number < 0 || number > 255) return null;
  return number;
}

/// A raw FIT field (from [ActivitySummary.extraFitFields] or
/// [Lap.extraFitFields]) re-emitted as a 4-byte integer record field.
class _ExtraFitField {
  const _ExtraFitField({required this.number, required this.signed});
  final int number;
  final bool signed;
}

/// Builds one shared field layout for a set of session/lap extra-field maps:
/// the union of their field numbers (sorted for determinism), each signed when
/// any source value is negative. Sessions/laps lacking a field write the FIT
/// invalid sentinel so the shared definition still round-trips per message.
List<_ExtraFitField> _unionExtraFields(Iterable<Map<int, double>> maps) {
  final signed = <int, bool>{};
  for (final map in maps) {
    for (final entry in map.entries) {
      signed[entry.key] = (signed[entry.key] ?? false) || entry.value < 0;
    }
  }
  final numbers = signed.keys.toList()..sort();
  return [
    for (final number in numbers)
      _ExtraFitField(number: number, signed: signed[number]!),
  ];
}

/// A raw FIT *array* field re-emitted as [count] contiguous 4-byte integers.
class _ExtraArrayField {
  const _ExtraArrayField({
    required this.number,
    required this.signed,
    required this.count,
  });
  final int number;
  final bool signed;
  final int count;
}

/// Shared array-field layout for a set of session/lap extra-array maps: the
/// union of field numbers, each sized to the longest array seen (shorter
/// messages pad with invalid sentinels). For real files every message carries
/// the same array length, so this round-trips exactly.
List<_ExtraArrayField> _unionExtraArrays(
  Iterable<Map<int, List<double>>> maps,
) {
  final signed = <int, bool>{};
  final count = <int, int>{};
  for (final map in maps) {
    for (final entry in map.entries) {
      signed[entry.key] =
          (signed[entry.key] ?? false) || entry.value.any((v) => v < 0);
      if (entry.value.length > (count[entry.key] ?? 0)) {
        count[entry.key] = entry.value.length;
      }
    }
  }
  final numbers = count.keys.toList()..sort();
  return [
    for (final number in numbers)
      _ExtraArrayField(
        number: number,
        signed: signed[number]!,
        count: count[number]!,
      ),
  ];
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
  string(0x07),
  sint16(0x83),
  uint16(0x84),
  sint32(0x85),
  uint32(0x86),
  float64(0x89),
  uint32z(0x8C);

  const _FitBaseType(this.code);
  final int code;
}

/// A developer field reference in a definition message: (field number, byte
/// size, developer data index), matching the on-wire triplet layout.
class _FitDeveloperFieldSpec {
  const _FitDeveloperFieldSpec({
    required this.fieldNumber,
    required this.size,
    required this.developerIndex,
  });
  final int fieldNumber;
  final int size;
  final int developerIndex;
}

int _clampUint16(int value) =>
    value < 0 ? 0 : (value > 0xFFFF ? 0xFFFF : value);
int _clampUint32(int value) =>
    value < 0 ? 0 : (value > 0xFFFFFFFF ? 0xFFFFFFFF : value);
