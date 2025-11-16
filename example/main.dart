import 'dart:io';

import 'package:activity_files/activity_files.dart';

/// Compile-time flag that mirrors the README guidance: override with
/// `dart run --define=supportsIsolates=false example/main.dart` when running on
/// platforms that cannot spin up isolates (e.g. Flutter web).
const supportsIsolates = bool.fromEnvironment(
  'supportsIsolates',
  defaultValue: true,
);

Future<void> main() async {
  final samplePath = File('example/assets/sample.gpx');
  final sampleBytes = await samplePath.readAsBytes();

  final loaded = await ActivityFiles.load(
    sampleBytes,
    format: ActivityFileFormat.gpx,
    useIsolate: supportsIsolates,
  );
  print(
    'Loaded ${loaded.format.name} with '
    '${loaded.activity.points.length} point(s) and '
    '${loaded.activity.channels.length} channel(s)',
  );

  if (loaded.hasWarnings) {
    print('Parser warnings:\n${loaded.diagnosticsSummary(includeNode: true)}');
  }

  final fitExport = await ActivityFiles.convertAndExport(
    source: sampleBytes,
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.fit,
    runValidation: true,
    useIsolate: supportsIsolates,
    exportInIsolate: supportsIsolates,
  );
  print('FIT payload: ${fitExport.asBytes().length} B');
  if (fitExport.hasDiagnostics) {
    print('Export diagnostics:\n${fitExport.diagnosticsSummary()}');
  }

  await _buildAndExportSyntheticActivity();

  final streamed = await ActivityFiles.convertAndExportStream(
    source: Stream<List<int>>.fromIterable(sampleBytes.map((b) => [b])),
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.tcx,
    runValidation: true,
    parseInIsolate: supportsIsolates,
    exportInIsolate: supportsIsolates,
  );
  print(
    'Streamed TCX size: ${streamed.asString().length} chars, '
    'warnings: ${streamed.warningCount}',
  );

  final asyncExport = await ActivityFiles.exportAsync(
    activity: streamed.activity,
    to: ActivityFileFormat.fit,
    runValidation: true,
    useIsolate: supportsIsolates,
  );
  print(
    'Async export validation errors: '
    '${asyncExport.validation?.errors.length ?? 0}',
  );

  await _exportFromRawStreams();

  final roundTrip = await ActivityFiles.load(
    fitExport.asBytes(),
    format: ActivityFileFormat.fit,
    useIsolate: supportsIsolates,
  );
  print('Round-trip points: ${roundTrip.activity.points.length}');
}

Future<void> _buildAndExportSyntheticActivity() async {
  final baseTime = DateTime.utc(2024, 1, 1, 12);

  final builder = ActivityFiles.builder()
    ..sport = Sport.running
    ..creator = 'Example Watch'
    ..setDeviceMetadata(
      const ActivityDeviceMetadata(
        manufacturer: 'Example Labs',
        product: '42',
        serialNumber: 'ABC123',
        softwareVersion: '1.0.0',
      ),
    )
    ..addPoint(
      latitude: 40.0,
      longitude: -105.0,
      elevation: 1601,
      time: baseTime,
    )
    ..addPoint(
      latitude: 40.0005,
      longitude: -105.0005,
      elevation: 1604,
      time: baseTime.add(const Duration(seconds: 5)),
    )
    ..addSample(channel: Channel.heartRate, time: baseTime, value: 140)
    ..addSample(
      channel: Channel.heartRate,
      time: baseTime.add(const Duration(seconds: 5)),
      value: 143,
    )
    ..addLap(
      startTime: baseTime,
      endTime: baseTime.add(const Duration(seconds: 5)),
      distanceMeters: 70,
    );

  final normalized = ActivityFiles.edit(
    builder.build(),
  ).sortAndDedup().trimInvalid().recomputeDistanceAndSpeed().activity;
  final prepared = ActivityFiles.smoothHeartRate(normalized, window: 3);

  final gpxExport = ActivityFiles.export(
    activity: prepared,
    to: ActivityFileFormat.gpx,
    runValidation: true,
  );
  print('Synthetic GPX points: ${gpxExport.activity.points.length}');
  if (gpxExport.hasDiagnostics) {
    print('Synthetic diagnostics:\n${gpxExport.diagnosticsSummary()}');
  }
}

Future<void> _exportFromRawStreams() async {
  final base = DateTime.utc(2024, 1, 2, 7);
  final ts0 = base.millisecondsSinceEpoch;
  final device = ActivityDeviceMetadata(
    manufacturer: 'ActivityFiles',
    model: 'CLI Device',
  );
  final export = await ActivityFiles.convertAndExport(
    location: [
      (timestamp: ts0, latitude: 40.0, longitude: -105.0, elevation: 1600),
      (
        timestamp: ts0 + 1000,
        latitude: 40.0003,
        longitude: -105.0003,
        elevation: 1602,
      ),
    ],
    channels: {
      Channel.heartRate: [
        (timestamp: ts0, value: 138),
        (timestamp: ts0 + 1000, value: 141),
      ],
    },
    label: 'Stream Demo',
    creator: 'example-main.dart',
    device: device,
    gpxMetadataDescription: 'Stream helper export',
    includeCreatorInGpxMetadataDescription: false,
    metadataExtensions: [ActivityFiles.gpxActivityLabelNode('Stream Demo')],
    trackExtensions: [ActivityFiles.gpxDeviceSummaryNode(device)],
    to: ActivityFileFormat.gpx,
    normalize: true,
    runValidation: false,
  );
  print('Stream helper points: ${export.activity.points.length}');
}
