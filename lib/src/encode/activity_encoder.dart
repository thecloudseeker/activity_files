// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';
import 'csv_encoder.dart';
import 'encoder_options.dart';
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
  static String encode(
    RawActivity activity,
    ActivityFileFormat format, {
    EncoderOptions options = const EncoderOptions(),
  }) {
    return switch (format) {
      ActivityFileFormat.gpx => const GpxEncoder().encode(activity, options),
      ActivityFileFormat.tcx => const TcxEncoder().encode(activity, options),
      ActivityFileFormat.fit => const FitEncoder().encode(activity, options),
      ActivityFileFormat.csv => CsvEncoder.encode(activity),
      ActivityFileFormat.geojson => GeojsonEncoder.encode(activity),
    };
  }
}
