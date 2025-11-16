// SPDX-License-Identifier: BSD-3-Clause
import 'package:activity_files/src/channel_mapper.dart';
import 'package:activity_files/src/models.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelMapper.mapAt pace gating', () {
    test('computes pace when speed sample is fresh', () {
      final timestamp = DateTime.utc(2024, 1, 1, 6);
      final channels = {
        Channel.speed: [
          Sample(time: timestamp, value: 5.0), // 5 m/s -> 200 s/km.
        ],
      };

      final snapshot = ChannelMapper.mapAt(timestamp, channels);

      expect(snapshot.speed, closeTo(5.0, 1e-9));
      expect(snapshot.pace, closeTo(200.0, 1e-9));
      expect(snapshot.speedDelta, equals(Duration.zero));
    });

    test('omits pace when no speed sample falls within tolerance', () {
      final timestamp = DateTime.utc(2024, 1, 1, 6);
      final channels = {
        Channel.speed: [
          Sample(
            time: timestamp.subtract(const Duration(seconds: 10)),
            value: 4,
          ),
        ],
      };

      final snapshot = ChannelMapper.mapAt(
        timestamp,
        channels,
        maxDelta: const Duration(seconds: 2),
      );

      expect(snapshot.speed, isNull);
      expect(snapshot.pace, isNull);
    });
  });
}
