// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';

/// Indexes channel samples by timestamp for point-by-point encoding.
///
/// Encoders use the returned map to join channel values onto GPS points that
/// share the exact same timestamp. When a channel has multiple samples at one
/// timestamp, the last sample wins.
Map<DateTime, Map<Channel, double>> channelValuesByTime(
  Map<Channel, List<Sample>> channels,
) {
  final byTime = <DateTime, Map<Channel, double>>{};
  for (final entry in channels.entries) {
    for (final sample in entry.value) {
      byTime.putIfAbsent(sample.time, () => {})[entry.key] = sample.value;
    }
  }
  return byTime;
}
