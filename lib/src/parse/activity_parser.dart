// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models.dart';
import '../platform/isolate_runner.dart' as isolate_runner;
import 'fit_parser.dart';
import 'gpx_parser.dart';
import 'parse_result.dart';
import 'tcx_parser.dart';

const int _defaultStreamParseLimitBytes = 64 * 1024 * 1024;

/// Common interface for format-specific parsers.
abstract class ActivityFormatParser {
  ActivityParseResult parse(String input);
}

/// Dynamically selects the parser for the requested format.
class ActivityParser {
  const ActivityParser._();

  /// Parses [input] according to [format].
  ///
  /// For FIT content the [input] should be a base64-encoded payload representing
  /// the binary FIT stream. Use [parseBytes] when working with raw FIT binaries.
  static ActivityParseResult parse(String input, ActivityFileFormat format) {
    final parser = switch (format) {
      ActivityFileFormat.gpx => const GpxParser(),
      ActivityFileFormat.tcx => const TcxParser(),
      ActivityFileFormat.fit => const FitParser(),
    };
    return parser.parse(input);
  }

  /// Convenience helper returning only the parsed activity.
  static RawActivity parseActivity(String input, ActivityFileFormat format) =>
      parse(input, format).activity;

  /// Parses [bytes] according to [format]. Use this for binary FIT payloads.
  static ActivityParseResult parseBytes(
    List<int> bytes,
    ActivityFileFormat format, {
    Encoding encoding = utf8,
  }) {
    final parser = switch (format) {
      ActivityFileFormat.gpx => const GpxParser(),
      ActivityFileFormat.tcx => const TcxParser(),
      ActivityFileFormat.fit => const FitParser(),
    };
    return switch (parser) {
      FitParser fit => fit.parseBytes(Uint8List.fromList(bytes)),
      _ => parser.parse(encoding.decode(bytes)),
    };
  }

  /// Offloads [input] parsing to a separate isolate when desired.
  static Future<ActivityParseResult> parseAsync(
    String input,
    ActivityFileFormat format, {
    bool useIsolate = true,
  }) {
    return _parseWithIsolation(input, format, useIsolate);
  }

  /// Asynchronous variant of [parseBytes] with optional isolate offloading.
  static Future<ActivityParseResult> parseBytesAsync(
    List<int> bytes,
    ActivityFileFormat format, {
    bool useIsolate = true,
    Encoding encoding = utf8,
  }) {
    return _parseWithIsolation(bytes, format, useIsolate, encoding: encoding);
  }

  /// Collects the [source] stream before parsing. Useful for file and network IO.
  static Future<ActivityParseResult> parseStream(
    Stream<List<int>> source,
    ActivityFileFormat format, {
    bool useIsolate = true,
    Encoding encoding = utf8,
    int? maxBytes = _defaultStreamParseLimitBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    var totalBytes = 0;
    try {
      await for (final chunk in source) {
        if (chunk.isNotEmpty) {
          totalBytes += chunk.length;
          if (maxBytes != null && totalBytes > maxBytes) {
            throw FormatException('Stream payload exceeds $maxBytes bytes.');
          }
          builder.add(chunk);
        }
      }
      final bytes = builder.takeBytes();
      if (format == ActivityFileFormat.fit) {
        return parseBytesAsync(
          bytes,
          format,
          useIsolate: useIsolate,
          encoding: encoding,
        );
      }
      final text = encoding.decode(bytes);
      return parseAsync(text, format, useIsolate: useIsolate);
    } on FormatException catch (error) {
      return _formatExceptionResult(format, error);
    }
  }

  static Future<ActivityParseResult> _parseWithIsolation(
    Object payload,
    ActivityFileFormat format,
    bool useIsolate, {
    Encoding encoding = utf8,
  }) {
    if (!useIsolate) {
      return Future.value(_parseDynamic(payload, format, encoding: encoding));
    }
    final transferable = _clonePayload(payload);
    return isolate_runner.runWithIsolation(
      () => _parseDynamic(transferable, format, encoding: encoding),
      useIsolate: useIsolate,
    );
  }

  static ActivityParseResult _parseDynamic(
    Object payload,
    ActivityFileFormat format, {
    Encoding encoding = utf8,
  }) {
    return switch (payload) {
      String text => parse(text, format),
      Uint8List bytes => parseBytes(bytes, format, encoding: encoding),
      List<int> bytes => parseBytes(bytes, format, encoding: encoding),
      _ => throw ArgumentError(
        'Unsupported payload type ${payload.runtimeType}; expected String or List<int>.',
      ),
    };
  }

  static Object _clonePayload(Object payload) => switch (payload) {
    String text => text,
    Uint8List bytes => Uint8List.fromList(bytes),
    List<int> bytes => Uint8List.fromList(bytes),
    _ => payload,
  };

  static ActivityParseResult _formatExceptionResult(
    ActivityFileFormat format,
    FormatException error,
  ) {
    final formatName = format.name.toUpperCase();
    final trimmed = error.message.trim();
    final message = trimmed.isEmpty ? error.toString() : trimmed;
    return ActivityParseResult(
      activity: RawActivity(),
      diagnostics: <ParseDiagnostic>[
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'parser.format_exception',
          message: 'Failed to parse $formatName payload: $message',
          node: ParseNodeReference(path: '${format.name}.document'),
        ),
      ],
    );
  }
}
