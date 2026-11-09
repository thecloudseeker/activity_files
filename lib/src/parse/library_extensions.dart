// SPDX-License-Identifier: BSD-3-Clause
import 'package:xml/xml.dart';

import '../library_namespace.dart';
import '../models.dart';

/// Whether [element] is the library's own `<[name]>`: in its namespace, in
/// the one it used before, or in [formatNamespaces], where an element
/// written without a namespace ends up by inheriting the file's default.
bool isLibraryElement(
  XmlElement element,
  String name, {
  Set<String> formatNamespaces = const {},
}) {
  if (element.name.local != name) return false;
  final uri = element.name.namespaceUri;
  return uri == null ||
      uri.isEmpty ||
      uri == libraryNamespace ||
      uri == legacyLibraryNamespace ||
      formatNamespaces.contains(uri);
}

/// Reads a `device` element the library wrote, or null when it holds
/// nothing.
ActivityDeviceMetadata? readLibraryDevice(XmlElement element) {
  String? text(String name) {
    for (final child in element.childElements) {
      if (child.name.local != name) continue;
      final value = child.innerText.trim();
      return value.isEmpty ? null : value;
    }
    return null;
  }

  final device = ActivityDeviceMetadata(
    manufacturer: text('manufacturer'),
    model: text('model'),
    product: text('product'),
    serialNumber: text('serialNumber'),
    softwareVersion: text('softwareVersion'),
    fitManufacturerId: int.tryParse(text('fitManufacturerId') ?? ''),
    fitProductId: int.tryParse(text('fitProductId') ?? ''),
  );
  return device.isEmpty ? null : device;
}
