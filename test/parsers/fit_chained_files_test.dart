// SPDX-License-Identifier: BSD-3-Clause
import 'dart:convert';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

/// Coverage for chained FIT files: several complete FIT files (header, data,
/// CRC) written back to back in one file, as devices do when they append
/// data recorded by an accessory.
void main() {
  RawActivity segmentActivity(DateTime start, {String? creator}) => RawActivity(
    points: [
      for (var i = 0; i < 3; i++)
        GeoPoint(
          latitude: 47.0 + i * 0.001,
          longitude: 8.0,
          time: start.add(Duration(seconds: i * 10)),
        ),
    ],
    laps: [
      Lap(startTime: start, endTime: start.add(const Duration(seconds: 20))),
    ],
    sport: Sport.running,
    creator: creator,
    device: const ActivityDeviceMetadata(fitManufacturerId: 1, fitProductId: 7),
  );

  Uint8List fitBytes(RawActivity activity) =>
      base64Decode(ActivityEncoder.encode(activity, ActivityFileFormat.fit));

  final first = fitBytes(segmentActivity(DateTime.utc(2024, 5, 1, 8)));
  final second = fitBytes(segmentActivity(DateTime.utc(2024, 5, 1, 9)));

  ActivityParseResult parse(List<int> bytes) =>
      ActivityParser.parseBytes(bytes, ActivityFileFormat.fit);

  Iterable<String> codes(ActivityParseResult result) =>
      result.diagnostics.map((d) => d.code);

  test('a single FIT file reports no chaining', () {
    final result = parse(first);

    expect(result.activity.points, hasLength(3));
    expect(codes(result), isNot(contains('fit.file.chained_segments')));
    expect(codes(result), isNot(contains('fit.file.trailing_bytes')));
  });

  test('every segment of a chained FIT file is read into one activity', () {
    final result = parse([...first, ...second]);

    expect(result.activity.points, hasLength(6));
    expect(
      result.activity.points.last.time,
      DateTime.utc(2024, 5, 1, 9, 0, 20),
    );
    expect(result.activity.laps, hasLength(2));
    expect(
      result.diagnostics,
      contains(
        isA<ParseDiagnostic>()
            .having((d) => d.code, 'code', 'fit.file.chained_segments')
            .having((d) => d.severity, 'severity', ParseSeverity.info)
            .having((d) => d.message, 'message', contains('2 chained')),
      ),
    );
    expect(
      result.diagnostics.where((d) => d.severity == ParseSeverity.error),
      isEmpty,
    );
  });

  test('the first segment decides the device identity', () {
    final other = fitBytes(
      RawActivity(
        points: [
          GeoPoint(
            latitude: 47.5,
            longitude: 8.5,
            time: DateTime.utc(2024, 5, 1, 9),
          ),
        ],
        device: const ActivityDeviceMetadata(
          fitManufacturerId: 23,
          fitProductId: 99,
        ),
      ),
    );

    final result = parse([...first, ...other]);

    expect(result.activity.device!.fitManufacturerId, 1);
    expect(result.activity.device!.fitProductId, 7);
  });

  test('bytes after the data that are not a FIT header are reported and '
      'ignored', () {
    final result = parse([...first, 1, 2, 3, 4, 5]);

    expect(result.activity.points, hasLength(3));
    expect(
      result.diagnostics,
      contains(
        isA<ParseDiagnostic>()
            .having((d) => d.code, 'code', 'fit.file.trailing_bytes')
            .having((d) => d.severity, 'severity', ParseSeverity.warning)
            .having((d) => d.message, 'message', contains('5 byte(s)')),
      ),
    );
    expect(codes(result), isNot(contains('fit.file.chained_segments')));
  });

  test('a truncated later segment is reported and the earlier data kept', () {
    final result = parse([...first, ...second.sublist(0, second.length - 12)]);

    expect(result.activity.points.length, greaterThanOrEqualTo(3));
    expect(
      result.activity.points.take(3).map((p) => p.time.hour),
      everyElement(8),
    );
    expect(
      result.diagnostics,
      contains(
        isA<ParseDiagnostic>()
            .having((d) => d.severity, 'severity', ParseSeverity.error)
            .having(
              (d) => d.code,
              'code',
              anyOf('fit.header.size_mismatch', 'fit.trailer.truncated'),
            )
            .having((d) => d.message, 'message', contains('segment 2')),
      ),
    );
  });

  test('a CRC mismatch in a later segment names that segment', () {
    final corrupted = Uint8List.fromList(second);
    corrupted[corrupted.length - 1] ^= 0xFF;

    final result = parse([...first, ...corrupted]);

    expect(result.activity.points, hasLength(6));
    expect(
      result.diagnostics,
      contains(
        isA<ParseDiagnostic>()
            .having((d) => d.code, 'code', 'fit.trailer.crc_mismatch')
            .having((d) => d.message, 'message', contains('segment 2')),
      ),
    );
  });
}
