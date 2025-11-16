// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:convert';

import '../encode/encoder_options.dart';
import '../models.dart';
import '../parse/parse_result.dart';
import '../validation.dart';

/// Declarative description of an export pipeline for [ActivityFiles].
class ActivityExportRequest {
  ActivityExportRequest._({
    this.activity,
    this.source,
    this.stream,
    required this.to,
    this.from,
    required this.options,
    required this.normalize,
    required this.runValidation,
    required this.parseInIsolate,
    required this.exportInIsolate,
    required this.encoding,
    required Iterable<ParseDiagnostic> diagnostics,
    this.validation,
  }) : diagnostics = List<ParseDiagnostic>.unmodifiable(diagnostics);

  factory ActivityExportRequest.fromActivity({
    required RawActivity activity,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool runValidation = true,
    bool exportInIsolate = false,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
    ValidationResult? validation,
  }) => ActivityExportRequest._(
    activity: activity,
    to: to,
    options: options,
    normalize: normalize,
    runValidation: runValidation,
    parseInIsolate: false,
    exportInIsolate: exportInIsolate,
    encoding: utf8,
    diagnostics: diagnostics,
    validation: validation,
  );

  factory ActivityExportRequest.fromSource({
    required Object source,
    required ActivityFileFormat? from,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool runValidation = false,
    bool parseInIsolate = true,
    bool exportInIsolate = false,
    Encoding encoding = utf8,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
  }) => ActivityExportRequest._(
    source: source,
    from: from,
    to: to,
    options: options,
    normalize: normalize,
    runValidation: runValidation,
    parseInIsolate: parseInIsolate,
    exportInIsolate: exportInIsolate,
    encoding: encoding,
    diagnostics: diagnostics,
    validation: null,
  );

  factory ActivityExportRequest.fromStream({
    required Stream<List<int>> stream,
    required ActivityFileFormat from,
    required ActivityFileFormat to,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool runValidation = false,
    bool parseInIsolate = true,
    bool exportInIsolate = false,
    Encoding encoding = utf8,
    Iterable<ParseDiagnostic> diagnostics = const <ParseDiagnostic>[],
  }) => ActivityExportRequest._(
    stream: stream,
    from: from,
    to: to,
    options: options,
    normalize: normalize,
    runValidation: runValidation,
    parseInIsolate: parseInIsolate,
    exportInIsolate: exportInIsolate,
    encoding: encoding,
    diagnostics: diagnostics,
    validation: null,
  );

  /// Activity to export when already parsed.
  final RawActivity? activity;

  /// Arbitrary source object (path, bytes, etc.) for conversion flows.
  final Object? source;

  /// Stream-based source for large payloads.
  final Stream<List<int>>? stream;

  /// Source format when [source] or [stream] is provided.
  final ActivityFileFormat? from;

  /// Target format for export.
  final ActivityFileFormat to;

  /// Encoder options applied during export.
  final EncoderOptions options;

  /// Whether to run normalization steps before encoding.
  final bool normalize;

  /// Whether structural validation should run after encoding.
  final bool runValidation;

  /// Whether parsing stages should run inside an isolate when needed.
  final bool parseInIsolate;

  /// Whether export stages should run inside an isolate when possible.
  final bool exportInIsolate;

  /// Text encoding used when parsing textual payloads.
  final Encoding encoding;

  /// Diagnostics gathered prior to export.
  final List<ParseDiagnostic> diagnostics;

  /// Optional pre-computed validation result to reuse.
  final ValidationResult? validation;
}
