// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';
import 'encoder_options.dart';
import 'fit_encoder.dart';
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
    final encoder = switch (format) {
      ActivityFileFormat.gpx => const GpxEncoder(),
      ActivityFileFormat.tcx => const TcxEncoder(),
      ActivityFileFormat.fit => const FitEncoder(),
    };
    return encoder.encode(activity, options);
  }
}
