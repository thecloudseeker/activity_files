// SPDX-License-Identifier: BSD-3-Clause
/// Integration tests for export serialization.
library;

import 'package:activity_files/activity_files.dart';
import 'package:activity_files/src/api/export_serialization.dart';
import 'package:activity_files/src/api/export_stats.dart';
import 'package:test/test.dart';

void main() {
  group('Export serialization', () {
    test('roundtrips activities with metadata, channels, and extensions', () {
      final base = DateTime.utc(2024, 8, 1, 6);
      final device = ActivityDeviceMetadata(
        manufacturer: 'Withings',
        model: 'ScanWatch',
        product: 'watch',
        serialNumber: 'abc123',
        softwareVersion: '1.2.3',
        fitManufacturerId: 201,
        fitProductId: 42,
      );
      final metadataExtensions = <GpxExtensionNode>[
        GpxExtensionNode(
          name: 'meta',
          namespacePrefix: 'ext',
          namespaceUri: 'https://example.com/ext',
          value: 'payload',
          attributes: const {'id': 'meta-1'},
          children: [
            GpxExtensionNode(
              name: 'child',
              namespacePrefix: 'ext',
              namespaceUri: 'https://example.com/ext',
              value: 'child-value',
            ),
          ],
        ),
      ];
      final trackExtensions = <GpxExtensionNode>[
        GpxExtensionNode(
          name: 'track',
          namespaceUri: 'https://example.com/track',
          value: 'track-value',
        ),
      ];
      final activity = RawActivity(
        points: [
          GeoPoint(
            latitude: 40.0,
            longitude: -105.0,
            elevation: 1600,
            time: base,
          ),
          GeoPoint(
            latitude: 40.0002,
            longitude: -105.0003,
            elevation: 1605,
            time: base.add(const Duration(seconds: 30)),
          ),
        ],
        channels: {
          Channel.heartRate: [
            Sample(time: base, value: 140),
            Sample(time: base.add(const Duration(seconds: 30)), value: 145),
          ],
          Channel.custom('respiration'): [
            Sample(time: base.add(const Duration(seconds: 15)), value: 12),
          ],
        },
        laps: [
          Lap(
            startTime: base,
            endTime: base.add(const Duration(minutes: 1)),
            distanceMeters: 210,
            name: 'Lap 1',
          ),
        ],
        sport: Sport.running,
        creator: 'serializer-test',
        device: device,
        gpxMetadataName: 'Morning Run',
        gpxMetadataDescription: 'Neighborhood loop',
        gpxIncludeCreatorMetadataDescription: false,
        gpxTrackName: 'Morning Run',
        gpxTrackDescription: 'Neighborhood loop',
        gpxTrackType: 'Run',
        gpxMetadataExtensions: metadataExtensions,
        gpxTrackExtensions: trackExtensions,
      );

      final serialized = ExportSerialization.activityToJson(activity);
      final roundTrip = ExportSerialization.activityFromJson(
        serialized.cast<String, Object?>(),
      );

      expect(roundTrip.points.length, equals(activity.points.length));
      expect(roundTrip.points.first.latitude, closeTo(40.0, 1e-9));
      expect(
        roundTrip.points.last.time.toIso8601String(),
        equals(activity.points.last.time.toIso8601String()),
      );
      expect(roundTrip.channels.length, equals(activity.channels.length));
      expect(
        roundTrip.channels[Channel.heartRate]!.last.value,
        closeTo(145, 1e-9),
      );
      final respiration = roundTrip.channels[Channel.custom('respiration')];
      expect(respiration, isNotNull);
      expect(respiration!.single.value, closeTo(12, 1e-9));
      expect(roundTrip.laps.single.distanceMeters, closeTo(210, 1e-9));
      expect(roundTrip.device?.serialNumber, equals('abc123'));
      expect(roundTrip.creator, equals('serializer-test'));
      expect(roundTrip.gpxMetadataDescription, equals('Neighborhood loop'));
      expect(roundTrip.gpxIncludeCreatorMetadataDescription, isFalse);
      expect(roundTrip.gpxTrackExtensions.single.name, equals('track'));
      expect(
        roundTrip.gpxMetadataExtensions.single.children.single.name,
        equals('child'),
      );
    });

    test('serializes encoder options with per-channel overrides', () {
      final options = EncoderOptions(
        defaultMaxDelta: const Duration(seconds: 5),
        precisionLatLon: 7,
        precisionEle: 2,
        maxDeltaPerChannel: {
          Channel.heartRate: const Duration(seconds: 2),
          Channel.custom('respiration'): const Duration(milliseconds: 500),
        },
      );

      final json = ExportSerialization.encoderOptionsToJson(options);
      final restored = ExportSerialization.encoderOptionsFromJson(
        json.cast<String, Object?>(),
      );

      expect(restored.defaultMaxDelta, equals(const Duration(seconds: 5)));
      expect(restored.precisionLatLon, equals(7));
      expect(restored.precisionEle, equals(2));
      expect(
        restored.maxDeltaPerChannel[Channel.heartRate],
        equals(const Duration(seconds: 2)),
      );
      expect(
        restored.maxDeltaPerChannel[Channel.custom('respiration')],
        equals(const Duration(milliseconds: 500)),
      );
      expect(restored.gpxVersion, equals(GpxVersion.v1_1));
      expect(restored.tcxVersion, equals(TcxVersion.v2));
    });

    test('serializes diagnostics and validation payloads', () {
      final diagnostic = ParseDiagnostic(
        severity: ParseSeverity.warning,
        code: 'demo.code',
        message: 'Problem',
        node: const ParseNodeReference(
          path: '/gpx/trk[0]/trkseg[0]/trkpt[1]',
          index: 1,
          description: 'trkpt',
        ),
      );
      final diagnosticJson = ExportSerialization.diagnosticToJson(diagnostic);
      final decodedDiagnostic = ExportSerialization.diagnosticFromJson(
        diagnosticJson.cast<String, Object?>(),
      );
      expect(decodedDiagnostic.code, equals('demo.code'));
      expect(decodedDiagnostic.message, equals('Problem'));
      expect(decodedDiagnostic.node, isNotNull);
      expect(
        decodedDiagnostic.node!.path,
        equals('/gpx/trk[0]/trkseg[0]/trkpt[1]'),
      );

      final validation = ValidationResult(
        errors: const ['gap error'],
        warnings: const ['speed warning'],
      );
      final validationJson = ExportSerialization.validationToJson(validation);
      final decodedValidation = ExportSerialization.validationFromJson(
        validationJson.cast<String, Object?>(),
      );
      expect(decodedValidation.errors, contains('gap error'));
      expect(decodedValidation.warnings, contains('speed warning'));
    });

    test('serializes normalization and processing stats', () {
      const normalization = NormalizationStats(
        applied: true,
        pointsBefore: 10,
        pointsAfter: 8,
        totalSamplesBefore: 20,
        totalSamplesAfter: 15,
        duration: Duration(milliseconds: 12),
      );
      final normalizationJson = ExportSerialization.normalizationStatsToJson(
        normalization,
      );
      final restoredNormalization =
          ExportSerialization.normalizationStatsFromJson(
            normalizationJson.cast<String, Object?>(),
          );
      expect(restoredNormalization.applied, isTrue);
      expect(restoredNormalization.pointsDelta, equals(-2));
      expect(restoredNormalization.totalSamplesDelta, equals(-5));

      final processing = ActivityProcessingStats(
        normalization: normalization,
        validationDuration: const Duration(milliseconds: 25),
      );
      final processingJson = ExportSerialization.processingStatsToJson(
        processing,
      );
      final restoredProcessing = ExportSerialization.processingStatsFromJson(
        processingJson.cast<String, Object?>(),
      );
      expect(restoredProcessing.hasNormalization, isTrue);
      expect(restoredProcessing.normalization!.pointsAfter, equals(8));
      expect(restoredProcessing.hasValidationTiming, isTrue);
      expect(
        restoredProcessing.validationDuration,
        equals(const Duration(milliseconds: 25)),
      );

      final emptyProcessing = ExportSerialization.processingStatsFromJson(null);
      expect(emptyProcessing.hasNormalization, isFalse);
      expect(emptyProcessing.hasValidationTiming, isFalse);
    });

    test('handles nullable device metadata serialization helpers', () {
      expect(ExportSerialization.deviceToJson(null), isNull);
      expect(ExportSerialization.deviceFromJson(null), isNull);
    });
  });
}
