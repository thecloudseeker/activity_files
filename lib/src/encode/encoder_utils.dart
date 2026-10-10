// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';

/// Namespace declared for the extension elements this library writes when the
/// caller supplies none.
const String defaultExtensionNamespace =
    'https://schemas.eikedreier.com/activity_files/v1';

/// The default extension namespace this library wrote before
/// [defaultExtensionNamespace] replaced it.
const String legacyExtensionNamespace =
    'https://schemas.activityfiles.dev/extensions';

/// Returns the namespace to declare for an extension node carrying [uri]:
/// [legacyExtensionNamespace] is written as [defaultExtensionNamespace], and
/// every other namespace is written unchanged.
String extensionNamespaceForExport(String uri) =>
    uri == legacyExtensionNamespace ? defaultExtensionNamespace : uri;

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
