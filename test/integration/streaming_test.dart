// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for stream-based parsing.
library;

import 'dart:convert';

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/builders.dart';
import '../fixtures/sample_data.dart';

void main() {
  const encoderOptions = EncoderOptions(
    defaultMaxDelta: Duration(seconds: 3),
    precisionLatLon: 6,
    precisionEle: 2,
  );

  group('Async parsing', () {
    test('parseAsync mirrors synchronous GPX parser', () async {
      final sync = ActivityParser.parse(sampleGpx, ActivityFileFormat.gpx);
      final asyncResult = await ActivityParser.parseAsync(
        sampleGpx,
        ActivityFileFormat.gpx,
        useIsolate: false,
      );
      expect(asyncResult.activity.points.length, sync.activity.points.length);
      expect(asyncResult.diagnostics, isEmpty);
    });

    test('parseBytesAsync offloads FIT parsing', () async {
      final activity = buildSampleActivity();
      final fitPayload = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      final bytes = base64Decode(fitPayload);
      final result = await ActivityParser.parseBytesAsync(
        bytes,
        ActivityFileFormat.fit,
      );
      expect(result.activity.points.length, activity.points.length);
      expect(result.diagnostics, isEmpty);
    });

    test('parseStream parses chunked FIT binary', () async {
      final activity = buildSampleActivity();
      final fitPayload = ActivityEncoder.encode(
        activity,
        ActivityFileFormat.fit,
        options: encoderOptions,
      );
      final bytes = base64Decode(fitPayload);
      final stream = Stream<List<int>>.fromIterable([
        bytes.sublist(0, bytes.length ~/ 2),
        bytes.sublist(bytes.length ~/ 2),
      ]);
      final result = await ActivityParser.parseStream(
        stream,
        ActivityFileFormat.fit,
        useIsolate: false,
      );
      expect(result.activity.points.length, activity.points.length);
      expect(result.diagnostics, isEmpty);
    });
  });
}
