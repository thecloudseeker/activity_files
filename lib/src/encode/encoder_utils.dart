// SPDX-License-Identifier: BSD-3-Clause
import 'package:xml/xml.dart';

import '../library_namespace.dart';
import '../models.dart';

/// Namespace declared for the extension elements this library writes when the
/// caller supplies none.
const String defaultExtensionNamespace = libraryNamespace;

/// The default extension namespace this library wrote before
/// [defaultExtensionNamespace] replaced it.
const String legacyExtensionNamespace = legacyLibraryNamespace;

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

/// Writes [device] as a `device` element in the library namespace, declared
/// on the element itself so it cannot clash with a prefix the file already
/// uses. GPX and TCX both read it back from their extension areas.
void writeLibraryDevice(XmlBuilder builder, ActivityDeviceMetadata device) {
  if (device.isEmpty) return;
  builder.element(
    'device',
    attributes: const {'xmlns': libraryNamespace},
    nest: () {
      void field(String name, Object? value) {
        final text = value?.toString().trim();
        if (text == null || text.isEmpty) return;
        builder.element(name, nest: text);
      }

      field('manufacturer', device.manufacturer);
      field('model', device.model);
      field('product', device.product);
      field('serialNumber', device.serialNumber);
      field('softwareVersion', device.softwareVersion);
      field('fitManufacturerId', device.fitManufacturerId);
      field('fitProductId', device.fitProductId);
    },
  );
}
