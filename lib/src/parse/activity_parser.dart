// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models.dart';
import '../platform/isolate_runner.dart' as isolate_runner;
import 'csv_parser.dart';
import 'fit_parser.dart';
import 'geojson_parser.dart';
import 'gpx_parser.dart';
import 'parse_result.dart';
import 'tcx_parser.dart';

const int _defaultStreamParseLimitBytes = 64 * 1024 * 1024;

/// Common interface for format-specific parsers.
abstract class ActivityFormatParser {
  ActivityParseResult parse(String input);
}

/// Reads a payload of a known format. Deprecated in favour of
/// `ActivityFiles.import`, which also detects the format and reads files and
/// streams; removed in 0.11.0.
@Deprecated('Use ActivityFiles.import. Will be removed in 0.11.0.')
class ActivityParser {
  const ActivityParser._();

  /// Parses [input] according to [format]. See [ParserRouter.parse].
  static ActivityParseResult parse(String input, ActivityFileFormat format) =>
      ParserRouter.parse(input, format);

  /// Convenience helper returning only the parsed activity.
  static RawActivity parseActivity(String input, ActivityFileFormat format) =>
      ParserRouter.parse(input, format).activity;

  /// Parses [bytes] according to [format]. See [ParserRouter.parseBytes].
  static ActivityParseResult parseBytes(
    List<int> bytes,
    ActivityFileFormat format, {
    Encoding encoding = utf8,
  }) => ParserRouter.parseBytes(bytes, format, encoding: encoding);

  /// Offloads [input] parsing to a separate isolate when desired.
  static Future<ActivityParseResult> parseAsync(
    String input,
    ActivityFileFormat format, {
    bool useIsolate = true,
  }) => ParserRouter.parseAsync(input, format, useIsolate: useIsolate);

  /// Asynchronous variant of [parseBytes] with optional isolate offloading.
  static Future<ActivityParseResult> parseBytesAsync(
    List<int> bytes,
    ActivityFileFormat format, {
    bool useIsolate = true,
    Encoding encoding = utf8,
  }) => ParserRouter.parseBytesAsync(
    bytes,
    format,
    useIsolate: useIsolate,
    encoding: encoding,
  );

  /// Collects the [source] stream before parsing. Useful for file and network IO.
  static Future<ActivityParseResult> parseStream(
    Stream<List<int>> source,
    ActivityFileFormat format, {
    bool useIsolate = true,
    Encoding encoding = utf8,
    int? maxBytes = _defaultStreamParseLimitBytes,
  }) => ParserRouter.parseStream(
    source,
    format,
    useIsolate: useIsolate,
    encoding: encoding,
    maxBytes: maxBytes,
  );
}

/// Selects the parser for a format. Internal: the library and its parser
/// tests read payloads through it; callers use `ActivityFiles.import`.
class ParserRouter {
  const ParserRouter._();

  /// Parses [input] according to [format].
  ///
  /// For FIT content the [input] should be a base64-encoded payload representing
  /// the binary FIT stream. Use [parseBytes] when working with raw FIT binaries.
  ///
  /// Never throws because of [input]: unreadable content comes back as an
  /// empty activity with an error diagnostic.
  static ActivityParseResult parse(String input, ActivityFileFormat format) {
    final parser = switch (format) {
      ActivityFileFormat.gpx => const GpxParser(),
      ActivityFileFormat.tcx => const TcxParser(),
      ActivityFileFormat.fit => const FitParser(),
      ActivityFileFormat.csv => const CsvParser(),
      ActivityFileFormat.geojson => const GeojsonParser(),
    };
    try {
      return parser.parse(input);
    } on FormatException catch (error) {
      return formatExceptionResult(format, error);
    }
  }

  /// Convenience helper returning only the parsed activity.
  static RawActivity parseActivity(String input, ActivityFileFormat format) =>
      parse(input, format).activity;

  /// Parses [bytes] according to [format]. Use this for binary FIT payloads.
  ///
  /// Never throws because of [bytes]: text that does not decode with
  /// [encoding] or a damaged FIT header comes back as an empty activity with
  /// an error diagnostic.
  static ActivityParseResult parseBytes(
    List<int> bytes,
    ActivityFileFormat format, {
    Encoding encoding = utf8,
  }) {
    final parser = switch (format) {
      ActivityFileFormat.gpx => const GpxParser(),
      ActivityFileFormat.tcx => const TcxParser(),
      ActivityFileFormat.fit => const FitParser(),
      ActivityFileFormat.csv => const CsvParser(),
      ActivityFileFormat.geojson => const GeojsonParser(),
    };
    try {
      return switch (parser) {
        FitParser fit => fit.parseBytes(Uint8List.fromList(bytes)),
        _ => parser.parse(encoding.decode(bytes)),
      };
    } on FormatException catch (error) {
      return formatExceptionResult(format, error);
    }
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
            throw FormatException(
              'Stream payload exceeds $maxBytes bytes. Hint: raise `maxBytes`, or pass `null` to disable the limit.',
            );
          }
          builder.add(chunk);
        }
      }
      final bytes = builder.takeBytes();
      if (format == ActivityFileFormat.fit) {
        return await parseBytesAsync(
          bytes,
          format,
          useIsolate: useIsolate,
          encoding: encoding,
        );
      }
      final text = encoding.decode(bytes);
      return await parseAsync(text, format, useIsolate: useIsolate);
    } on FormatException catch (error) {
      return formatExceptionResult(format, error);
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
    Uint8List bytes => bytes, // Already immutable view, no copy needed
    List<int> bytes => Uint8List.fromList(bytes),
    _ => payload,
  };
}

/// The result for a payload a parser cannot read at all: an empty activity
/// with one `parser.format_exception` error.
ActivityParseResult formatExceptionResult(
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
        message:
            'Failed to parse $formatName payload: $message. Hint: For GPX/TCX/CSV/GeoJSON, ensure the text encoding matches the file (`encoding` parameter). For FIT, pass raw bytes via `parseBytes`/`import(File)` instead of base64 text and check integrity. If the input is ambiguous, provide `format` explicitly.',
        node: ParseNodeReference(path: '${format.name}.document'),
      ),
    ],
  );
}
