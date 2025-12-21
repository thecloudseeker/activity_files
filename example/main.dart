import 'dart:io';
import 'dart:typed_data';

import 'package:activity_files/activity_files.dart';

/// Override with `dart run --define=supportsIsolates=false example/main.dart`
/// when running on platforms (e.g. Flutter web) that cannot spawn isolates.
const supportsIsolates = bool.fromEnvironment(
  'supportsIsolates',
  defaultValue: true,
);

Future<void> main() async {
  final sampleFile = File('example/assets/sample.gpx');
  final sampleBytes = await sampleFile.readAsBytes();

  await _demoLoadAndConvert(sampleBytes);
  await _buildAndExportSyntheticActivity();
  await _exportFromRawStreams();
}

Future<void> _demoLoadAndConvert(Uint8List sampleBytes) async {
  print('=== Load & convert sample.gpx ===');

  final loaded = await ActivityFiles.load(
    sampleBytes,
    format: ActivityFileFormat.gpx,
    useIsolate: supportsIsolates,
  );
  if (loaded.hasErrors) {
    print('Load failed:\n${loaded.diagnosticsSummary(includeNode: true)}');
    return;
  }
  print(
    'Loaded ${loaded.format.name}: '
    '${loaded.activity.points.length} points, '
    '${loaded.activity.channels.length} channel(s)',
  );
  if (loaded.hasWarnings) {
    print('Parser warnings:\n${loaded.diagnosticsSummary(includeNode: true)}');
  }

  final tcxConversion = await ActivityFiles.convert(
    source: sampleBytes,
    to: ActivityFileFormat.tcx,
    runValidation: true,
    useIsolate: supportsIsolates,
  );
  if (tcxConversion.hasErrors) {
    print('TCX conversion failed:\n${tcxConversion.diagnosticsSummary()}');
    return;
  }
  print(
    'TCX validation errors: ${tcxConversion.validation?.errors.length ?? 0}, '
    'diagnostics: ${tcxConversion.diagnostics.length}',
  );

  final fitExport = await ActivityFiles.convertAndExport(
    source: sampleBytes,
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.fit,
    runValidation: true,
    useIsolate: supportsIsolates,
    exportInIsolate: supportsIsolates,
  );
  if (fitExport.hasErrors) {
    print('FIT export failed:\n${fitExport.diagnosticsSummary()}');
    return;
  }
  print('FIT payload bytes: ${fitExport.asBytes().length}');

  final streamed = await ActivityFiles.convertAndExportStream(
    source: Stream<List<int>>.fromIterable([
      for (final chunk in sampleBytes.chunks(64)) chunk,
    ]),
    from: ActivityFileFormat.gpx,
    to: ActivityFileFormat.tcx,
    runValidation: true,
    parseInIsolate: supportsIsolates,
    exportInIsolate: supportsIsolates,
  );
  if (streamed.hasErrors) {
    print('Streamed export failed:\n${streamed.diagnosticsSummary()}');
    return;
  }
  print(
    'Streamed TCX chars: ${streamed.asString().length}; '
    'warnings: ${streamed.warningCount}',
  );

  final asyncExport = await ActivityFiles.exportAsync(
    activity: streamed.activity,
    to: ActivityFileFormat.fit,
    runValidation: true,
    useIsolate: supportsIsolates,
  );
  if (asyncExport.hasErrors) {
    print('Async export failed:\n${asyncExport.diagnosticsSummary()}');
    return;
  }
  print(
    'Async export validation errors: '
    '${asyncExport.validation?.errors.length ?? 0}',
  );

  final roundTrip = await ActivityFiles.load(
    fitExport.asBytes(),
    format: ActivityFileFormat.fit,
    useIsolate: supportsIsolates,
  );
  if (roundTrip.hasErrors) {
    print('Round-trip FIT parse failed:\n${roundTrip.diagnosticsSummary()}');
    return;
  }
  print('Round-trip points: ${roundTrip.activity.points.length}');
}

Future<void> _buildAndExportSyntheticActivity() async {
  print('=== Build + export synthetic activity ===');
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
  print('=== Convert from raw timestamp/value streams ===');
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
    sportSource: 'running',
    device: device,
    gpxMetadataDescription: 'Stream helper export',
    includeCreatorInGpxMetadataDescription: false,
    metadataExtensions: [ActivityFiles.gpxActivityLabelNode('Stream Demo')],
    trackExtensions: [ActivityFiles.gpxDeviceSummaryNode(device)],
    to: ActivityFileFormat.gpx,
    normalize: true,
    runValidation: true,
  );
  if (export.hasErrors) {
    print('Stream helper export failed:\n${export.diagnosticsSummary()}');
    return;
  }
  print('Stream helper points: ${export.activity.points.length}');
}

extension on List<int> {
  Iterable<List<int>> chunks(int size) sync* {
    for (var i = 0; i < length; i += size) {
      final end = (i + size) > length ? length : i + size;
      yield sublist(i, end);
    }
  }
}
