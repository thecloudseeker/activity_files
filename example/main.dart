import 'package:activity_files/activity_files.dart';

Future<void> main() async {
  final baseTime = DateTime.utc(2024, 1, 1, 12);

  final activity = ActivityFiles.builder()
    ..sport = Sport.running
    ..creator = 'Example Watch'
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

  final cleaned = ActivityFiles.edit(
    activity.build(),
  ).recomputeDistanceAndSpeed().activity;

  final gpx = ActivityEncoder.encode(cleaned, ActivityFileFormat.gpx);

  final conversion = await ActivityFiles.convert(
    source: gpx,
    to: ActivityFileFormat.fit,
    useIsolate: false,
  );

  final fitLoad = await ActivityFiles.load(
    conversion.asBytes(),
    format: ActivityFileFormat.fit,
    useIsolate: false,
  );

  print('GPX points: ${cleaned.points.length}');
  print('FIT bytes: ${conversion.asBytes().length}');
  print('Round-trip points: ${fitLoad.activity.points.length}');
}
