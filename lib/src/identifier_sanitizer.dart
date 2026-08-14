// SPDX-License-Identifier: BSD-3-Clause

/// Sanitizes a free-form channel/field name into a valid XML NCName-ish
/// identifier: lowercase, non-alphanumeric runs collapsed to `_`, leading/
/// trailing `_` trimmed. Returns null when nothing usable remains (empty,
/// or starts with a digit), so callers can fall back to a generated name.
///
/// Shared by the GPX encoder (`gpxtpx:` extension tag names) and the FIT
/// parser (developer field channel names), which both need this exact rule.
String? sanitizeIdentifier(String name) {
  final id = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return id.isEmpty || RegExp(r'^[0-9]').hasMatch(id) ? null : id;
}
