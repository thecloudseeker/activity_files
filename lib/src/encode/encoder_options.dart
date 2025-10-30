// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';
/// Controls encoder behaviour such as matching tolerance and numeric precision.
class EncoderOptions {
  const EncoderOptions({
    this.defaultMaxDelta = const Duration(seconds: 5),
    this.maxDeltaPerChannel = const {},
    this.precisionLatLon = 6,
    this.precisionEle = 2,
  })  : assert(precisionLatLon >= 0),
        assert(precisionEle >= 0);
  /// Default tolerance when mapping channel samples to timestamps.
  final Duration defaultMaxDelta;
  /// Overrides per channel for matching tolerance.
  final Map<Channel, Duration> maxDeltaPerChannel;
  /// Number of fractional digits for latitude and longitude.
  final int precisionLatLon;
  /// Number of fractional digits for elevation values.
  final int precisionEle;
  /// Returns the tolerance for [channel].
  Duration maxDeltaFor(Channel channel) =>
      maxDeltaPerChannel[channel] ?? defaultMaxDelta;
  EncoderOptions copyWith({
    Duration? defaultMaxDelta,
    Map<Channel, Duration>? maxDeltaPerChannel,
    int? precisionLatLon,
    int? precisionEle,
  }) {
    return EncoderOptions(
      defaultMaxDelta: defaultMaxDelta ?? this.defaultMaxDelta,
      maxDeltaPerChannel: maxDeltaPerChannel ??
          Map<Channel, Duration>.from(this.maxDeltaPerChannel),
      precisionLatLon: precisionLatLon ?? this.precisionLatLon,
      precisionEle: precisionEle ?? this.precisionEle,
    );
  }
}
