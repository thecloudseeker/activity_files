// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';
import 'csv_encoder.dart';
import 'encoder_options.dart';
import 'finite_guard.dart';
import 'fit_encoder.dart';
import 'geojson_encoder.dart';
import 'gpx_encoder.dart';
import 'tcx_encoder.dart';

/// Common interface for writing activity formats.
abstract class ActivityFormatEncoder {
  String encode(RawActivity activity, EncoderOptions options);
}

/// Delegates encoding to the relevant format implementation.
class ActivityEncoder {
  const ActivityEncoder._();

  /// Encodes [activity] using the requested [format].
  ///
  /// `NaN` and infinite values are left out of the output;
  /// `ActivityFiles.export` reports them.
  static String encode(
    RawActivity input,
    ActivityFileFormat format, {
    EncoderOptions options = const EncoderOptions(),
  }) {
    final activity = dropNonFinite(input, NonFiniteReport());
    return switch (format) {
      ActivityFileFormat.gpx => const GpxEncoder().encode(activity, options),
      ActivityFileFormat.tcx => const TcxEncoder().encode(activity, options),
      ActivityFileFormat.fit => const FitEncoder().encode(activity, options),
      ActivityFileFormat.csv => CsvEncoder.encode(activity, options: options),
      ActivityFileFormat.geojson => switch (options.geojsonGeometry) {
        GeojsonGeometry.lineString => GeojsonEncoder.encode(
          activity,
          options: options,
        ),
        GeojsonGeometry.points =>
          options.geojsonIncludeChannels
              ? GeojsonEncoder.encodeAsPointsWithChannels(
                  activity,
                  options: options,
                )
              : GeojsonEncoder.encodeAsPoints(activity, options: options),
      },
    };
  }
}
