// MIT License
//
// Copyright (c) 2024 activity_files
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

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
