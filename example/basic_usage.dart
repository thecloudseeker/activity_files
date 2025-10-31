import 'package:activity_files/activity_files.dart';

Future<void> main() async {
  // Construct a minimal activity and round-trip through GPX encoding.
  final activity = RawActivity(
    points: [
      GeoPoint(
        latitude: 40.0,
        longitude: -105.0,
        elevation: 1601,
        time: DateTime.utc(2024, 1, 1, 12),
      ),
      GeoPoint(
        latitude: 40.0005,
        longitude: -105.0005,
        elevation: 1604,
        time: DateTime.utc(2024, 1, 1, 12, 0, 5),
      ),
    ],
    channels: {
      Channel.heartRate: [
        Sample(time: DateTime.utc(2024, 1, 1, 12), value: 140),
        Sample(time: DateTime.utc(2024, 1, 1, 12, 0, 5), value: 143),
      ],
    },
    sport: Sport.running,
  );

  final gpx = ActivityEncoder.encode(
    activity,
    ActivityFileFormat.gpx,
    options: const EncoderOptions(),
  );

  final parsed = ActivityParser.parse(gpx, ActivityFileFormat.gpx);

  print('Warnings: ${parsed.warnings.length}');
  print('Points after round-trip: ${parsed.activity.points.length}');
}
