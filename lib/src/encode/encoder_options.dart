// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';

/// GPX spec versions supported by the encoder.
enum GpxVersion { v1_1, v1_0 }

/// TCX schema versions supported by the encoder.
enum TcxVersion { v2, v1 }

/// GeoJSON geometry shape to emit when encoding to GeoJSON.
enum GeojsonGeometry {
  /// A single `LineString` feature tracing the route (the default).
  lineString,

  /// One `Point` feature per sample.
  points,
}

/// Controls encoder behaviour such as matching tolerance and numeric precision.
class EncoderOptions {
  const EncoderOptions({
    this.defaultMaxDelta = const Duration(seconds: 5),
    this.maxDeltaPerChannel = const {},
    this.precisionLatLon = 6,
    this.precisionEle = 2,
    this.gpxVersion = GpxVersion.v1_1,
    this.tcxVersion = TcxVersion.v2,
    this.geojsonGeometry = GeojsonGeometry.lineString,
    this.geojsonIncludeChannels = false,
  }) : assert(precisionLatLon >= 0),
       assert(precisionEle >= 0);

  /// Default tolerance when mapping channel samples to timestamps.
  final Duration defaultMaxDelta;

  /// Overrides per channel for matching tolerance.
  final Map<Channel, Duration> maxDeltaPerChannel;

  /// Number of fractional digits for latitude and longitude.
  final int precisionLatLon;

  /// Number of fractional digits for elevation values.
  final int precisionEle;

  /// GPX spec version to emit when encoding GPX.
  final GpxVersion gpxVersion;

  /// TCX schema version to emit when encoding TCX.
  final TcxVersion tcxVersion;

  /// GeoJSON geometry shape to emit when encoding to GeoJSON.
  final GeojsonGeometry geojsonGeometry;

  /// Whether to attach channel-sample properties to each point feature.
  /// Only meaningful when [geojsonGeometry] is [GeojsonGeometry.points].
  final bool geojsonIncludeChannels;

  /// Returns the tolerance for [channel].
  Duration maxDeltaFor(Channel channel) =>
      maxDeltaPerChannel[channel] ?? defaultMaxDelta;
  EncoderOptions copyWith({
    Duration? defaultMaxDelta,
    Map<Channel, Duration>? maxDeltaPerChannel,
    int? precisionLatLon,
    int? precisionEle,
    GpxVersion? gpxVersion,
    TcxVersion? tcxVersion,
    GeojsonGeometry? geojsonGeometry,
    bool? geojsonIncludeChannels,
  }) {
    return EncoderOptions(
      defaultMaxDelta: defaultMaxDelta ?? this.defaultMaxDelta,
      maxDeltaPerChannel:
          maxDeltaPerChannel ??
          Map<Channel, Duration>.from(this.maxDeltaPerChannel),
      precisionLatLon: precisionLatLon ?? this.precisionLatLon,
      precisionEle: precisionEle ?? this.precisionEle,
      gpxVersion: gpxVersion ?? this.gpxVersion,
      tcxVersion: tcxVersion ?? this.tcxVersion,
      geojsonGeometry: geojsonGeometry ?? this.geojsonGeometry,
      geojsonIncludeChannels:
          geojsonIncludeChannels ?? this.geojsonIncludeChannels,
    );
  }
}
