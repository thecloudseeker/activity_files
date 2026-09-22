part of '../activity_files_facade.dart';

Future<_ResolvedSource> _resolveSource(
  Object source, {
  required bool allowFilePaths,
}) async {
  if (source is _ResolvedSource) {
    return source;
  }
  if (source is Stream<List<int>>) {
    const sniffLimit = 64 * 1024;
    final queue = StreamQueue(source);
    final consumedChunks = <List<int>>[];
    final sniffBuffer = BytesBuilder(copy: false);
    var sniffedBytes = 0;
    while (sniffedBytes < sniffLimit && await queue.hasNext) {
      final chunk = await queue.next;
      consumedChunks.add(chunk);
      if (chunk.isEmpty) {
        continue;
      }
      final remaining = sniffLimit - sniffedBytes;
      if (remaining <= 0) {
        continue;
      }
      if (chunk.length <= remaining) {
        sniffBuffer.add(chunk);
        sniffedBytes += chunk.length;
      } else {
        sniffBuffer.add(chunk.sublist(0, remaining));
        sniffedBytes += remaining;
      }
    }
    Stream<List<int>> replay() async* {
      for (final chunk in consumedChunks) {
        if (chunk.isNotEmpty) {
          yield chunk;
        }
      }
      yield* queue.rest;
    }

    final sniffBytes = sniffedBytes == 0 ? null : sniffBuffer.takeBytes();
    return _ResolvedSource(
      payload: _ReplayableStreamPayload(
        replay(),
        bufferLimit: _defaultStreamBufferLimitBytes,
      ),
      description: 'stream',
      detectionBytes: sniffBytes,
    );
  }
  if (source is List<int>) {
    return _ResolvedSource(
      payload: Uint8List.fromList(source),
      description: 'bytes',
    );
  }
  final fileRead = await file_system.readPlatformFile(source);
  if (fileRead != null) {
    return _ResolvedSource(
      payload: fileRead.bytes,
      description: fileRead.path,
      fileExtension: _extensionForPath(fileRead.path),
    );
  }
  if (source is String) {
    if (allowFilePaths && file_system.platformPathExists(source)) {
      final bytes = await file_system.readPlatformPath(source);
      return _ResolvedSource(
        payload: bytes,
        description: source,
        fileExtension: _extensionForPath(source),
      );
    }
    return _ResolvedSource(payload: source, description: 'inline');
  }
  throw ArgumentError(
    'Unsupported source type: ${source.runtimeType}.\n'
    '\n'
    'Supported input types:\n'
    '  • String: inline text content or filesystem path (with allowFilePaths: true)\n'
    '  • File: dart:io File instance\n'
    '  • List<int> or Uint8List: raw binary data\n'
    '  • Stream<List<int>>: chunked/streaming data\n'
    '\n'
    'For filesystem paths passed as String, enable: import(source, allowFilePaths: true)\n'
    '\n'
    'Received: ${source.runtimeType}',
  );
}

ActivityFileFormat? _detectFormat(
  _ResolvedSource resolved, {
  required Encoding encoding,
  int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
}) {
  if (maxPayloadBytes != null) {
    _enforcePayloadLimit(
      resolved.detectionBytes ?? resolved.payload,
      encoding: encoding,
      limit: maxPayloadBytes,
    );
  }
  final detectedFromExt = _detectFromExtension(resolved.fileExtension);
  if (detectedFromExt != null) {
    return detectedFromExt;
  }
  final candidate = resolved.detectionBytes ?? resolved.payload;
  if (candidate is Stream<List<int>>) {
    // Cannot inspect an unbuffered stream without consuming it.
    return null;
  }
  return _detectFromPayload(candidate, encoding: encoding);
}

ActivityParseResult _parseSync(
  Object payload,
  ActivityFileFormat format,
  Encoding encoding,
) {
  return switch (payload) {
    String text => ActivityParser.parse(text, format),
    Uint8List bytes => _parseBytesWithBom(bytes, format, encoding),
    List<int> bytes => ActivityParser.parseBytes(
      bytes,
      format,
      encoding: encoding,
    ),
    _ => throw ArgumentError(
      'Unsupported payload type in parser: ${payload.runtimeType}.\n'
      '\n'
      'Expected: String or List<int> (bytes)\n'
      '\n'
      'If using a Stream, parse with parseStream() instead:\n'
      '  ActivityParser.parseStream(stream, format)\n'
      '\n'
      'Received type: ${payload.runtimeType}',
    ),
  };
}

Future<ActivityParseResult> _parseResolved(
  Object payload,
  ActivityFileFormat format, {
  bool useIsolate = true,
  Encoding encoding = utf8,
  int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
}) async {
  if (payload is _ReplayableStreamPayload) {
    final bytes = await payload.materialize(maxBytes: maxPayloadBytes);
    return _parseBytesIsolated(bytes, format, encoding, useIsolate);
  }
  if (payload is Stream<List<int>>) {
    return ActivityParser.parseStream(
      payload,
      format,
      useIsolate: useIsolate,
      encoding: encoding,
      maxBytes: maxPayloadBytes,
    );
  }
  if (maxPayloadBytes != null) {
    _enforcePayloadLimit(payload, encoding: encoding, limit: maxPayloadBytes);
  }
  return isolate_runner.runWithIsolation(
    () => _parseSync(payload, format, encoding),
    useIsolate: useIsolate,
  );
}

/// Runs [_parseBytesWithBom] with optional isolate offloading.
///
/// Kept as a standalone function, not inlined at the call site:
/// `Isolate.run` rejects a closure whose enclosing scope holds any
/// non-sendable value, even one the closure body never references, so
/// inlining this would put the non-sendable `_ReplayableStreamPayload`
/// local in scope and crash.
Future<ActivityParseResult> _parseBytesIsolated(
  Uint8List bytes,
  ActivityFileFormat format,
  Encoding encoding,
  bool useIsolate,
) {
  return isolate_runner.runWithIsolation(
    () => _parseBytesWithBom(bytes, format, encoding),
    useIsolate: useIsolate,
  );
}

ActivityParseResult _failedParseResult({
  required ActivityFileFormat format,
  required FormatException error,
}) {
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

Future<({Object payload, bool unavailable})> _materializePayload(
  Object payload, {
  int? maxBytes,
}) async {
  if (payload is _ReplayableStreamPayload) {
    try {
      return (
        payload: await payload.materialize(maxBytes: maxBytes),
        unavailable: false,
      );
    } catch (_) {
      return (payload: Uint8List(0), unavailable: true);
    }
  }
  return (payload: payload, unavailable: false);
}

ActivityFileFormat? _detectFormatSync(
  Object source, {
  required Encoding encoding,
  required bool allowFilePaths,
  int? maxPayloadBytes = _defaultStreamBufferLimitBytes,
}) {
  if (source is _ResolvedSource) {
    if (maxPayloadBytes != null) {
      _enforcePayloadLimit(
        source.detectionBytes ?? source.payload,
        encoding: encoding,
        limit: maxPayloadBytes,
      );
    }
    return _detectFormat(
      source,
      encoding: encoding,
      maxPayloadBytes: maxPayloadBytes,
    );
  }
  if (maxPayloadBytes != null) {
    _enforcePayloadLimit(source, encoding: encoding, limit: maxPayloadBytes);
  }
  final filePath = file_system.platformFilePath(source);
  if (filePath != null) {
    return _detectFromExtension(_extensionForPath(filePath));
  }
  if (source is String) {
    if (allowFilePaths && file_system.platformPathExists(source)) {
      return _detectFromExtension(_extensionForPath(source));
    }
    return _detectFromPayload(source, encoding: encoding);
  }
  if (source is List<int> || source is Uint8List) {
    return _detectFromPayload(source, encoding: encoding);
  }
  if (source is Stream<List<int>>) {
    // Cannot inspect streams without consuming; return null.
    return null;
  }
  return null;
}

const Map<String, ActivityFileFormat> _formatByExtension = {
  '.gpx': ActivityFileFormat.gpx,
  '.tcx': ActivityFileFormat.tcx,
  '.fit': ActivityFileFormat.fit,
  '.csv': ActivityFileFormat.csv,
  '.geojson': ActivityFileFormat.geojson,
  '.json': ActivityFileFormat.geojson,
};

ActivityFileFormat? _detectFromExtension(String? ext) =>
    _formatByExtension[ext];

ActivityFileFormat? _detectFromPayload(
  Object payload, {
  required Encoding encoding,
}) {
  if (payload is String) {
    final sniffed = _sniffTextForDetection(payload);
    return _detectFromText(sniffed.text, allowPartial: sniffed.truncated);
  }
  final sniffed = _sniffBytesForDetection(payload);
  final bytes = sniffed.bytes;
  final bomDecoder = _decoderForBom(bytes);
  if (bomDecoder != null) {
    final decoded = bomDecoder(bytes);
    final detectedFromBom = _detectFromText(
      decoded,
      allowPartial: sniffed.truncated,
    );
    if (detectedFromBom != null) {
      return detectedFromBom;
    }
  }
  if (_looksBinary(bytes)) {
    return ActivityFileFormat.fit;
  }
  try {
    return _detectFromText(
      encoding.decode(bytes),
      allowPartial: sniffed.truncated,
    );
  } on FormatException {
    final fallback = utf8.decode(bytes, allowMalformed: true);
    return _detectFromText(fallback, allowPartial: sniffed.truncated);
  }
}

String? _extensionForPath(String path) {
  final normalized = path.trim();
  final dot = normalized.lastIndexOf('.');
  if (dot < 0 || dot == normalized.length - 1) {
    return null;
  }
  return normalized.substring(dot).toLowerCase();
}

bool _looksBinary(Uint8List bytes) {
  var controlCount = 0;
  for (final byte in bytes) {
    if (byte == 0) {
      return true;
    }
    if (byte < 9 && byte != 0) {
      controlCount++;
    }
    if (controlCount > 4) {
      return true;
    }
  }
  return false;
}

bool _looksBase64(String text, {bool allowPartial = false}) {
  final trimmed = text.replaceAll(RegExp(r'\s+'), '');
  if (trimmed.isEmpty) {
    return false;
  }
  if (!allowPartial && trimmed.length % 4 != 0) {
    return false;
  }
  final matchesAlphabet = RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(trimmed);
  if (!matchesAlphabet) {
    return false;
  }
  if (allowPartial) {
    return trimmed.length >= 8;
  }
  return true;
}

ActivityFileFormat? _detectFromText(String text, {bool allowPartial = false}) {
  final trimmed = text.trimLeft();
  if (trimmed.isEmpty) {
    return null;
  }
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    final lower = trimmed.toLowerCase();
    if (lower.contains('"type"') &&
        (lower.contains('"featurecollection"') ||
            lower.contains('"feature"') ||
            lower.contains('"linestring"') ||
            lower.contains('"point"') ||
            lower.contains('"multilinestring"'))) {
      return ActivityFileFormat.geojson;
    }
  }
  if (trimmed.startsWith('<')) {
    final lower = trimmed.toLowerCase();
    if (lower.contains('<gpx')) {
      return ActivityFileFormat.gpx;
    }
    if (lower.contains('trainingcenterdatabase') || lower.contains('<tcx')) {
      return ActivityFileFormat.tcx;
    }
  }
  if (_looksCsv(trimmed, allowPartial: allowPartial)) {
    return ActivityFileFormat.csv;
  }
  if (_looksBase64(trimmed, allowPartial: allowPartial)) {
    return ActivityFileFormat.fit;
  }
  return null;
}

bool _looksCsv(String text, {bool allowPartial = false}) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .take(3)
      .toList(growable: false);
  if (lines.isEmpty) {
    return false;
  }
  final header = lines.first.toLowerCase();
  if (!(header.contains('timestamp') &&
      header.contains('latitude') &&
      header.contains('longitude'))) {
    return false;
  }
  if (allowPartial) {
    return header.contains(',');
  }
  if (lines.length < 2) {
    return false;
  }
  return lines.first.contains(',') && lines[1].contains(',');
}

({String text, bool truncated}) _sniffTextForDetection(
  String text, {
  int maxChars = _maxFormatDetectBytes,
}) {
  if (text.length <= maxChars) {
    return (text: text, truncated: false);
  }
  return (text: text.substring(0, maxChars), truncated: true);
}

({Uint8List bytes, bool truncated}) _sniffBytesForDetection(
  Object payload, {
  int maxBytes = _maxFormatDetectBytes,
}) {
  if (payload is Uint8List) {
    if (payload.length <= maxBytes) {
      return (bytes: payload, truncated: false);
    }
    return (
      bytes: Uint8List.sublistView(payload, 0, maxBytes),
      truncated: true,
    );
  }
  final list = payload as List<int>;
  if (list.length <= maxBytes) {
    return (bytes: Uint8List.fromList(list), truncated: false);
  }
  return (
    bytes: Uint8List.fromList(list.take(maxBytes).toList()),
    truncated: true,
  );
}

String Function(Uint8List bytes)? _decoderForBom(Uint8List bytes) {
  if (bytes.length >= 2) {
    final first = bytes[0];
    final second = bytes[1];
    if (first == 0xFF && second == 0xFE) {
      return (data) => _decodeUtf16(data, Endian.little);
    }
    if (first == 0xFE && second == 0xFF) {
      return (data) => _decodeUtf16(data, Endian.big);
    }
  }
  if (bytes.length >= 4) {
    final b0 = bytes[0];
    final b1 = bytes[1];
    final b2 = bytes[2];
    final b3 = bytes[3];
    if (b0 == 0x00 && b1 == 0x00 && b2 == 0xFE && b3 == 0xFF) {
      return (data) => _decodeUtf32(data, Endian.big);
    }
    if (b0 == 0xFF && b1 == 0xFE && b2 == 0x00 && b3 == 0x00) {
      return (data) => _decodeUtf32(data, Endian.little);
    }
  }
  return null;
}

String _decodeUtf32(Uint8List bytes, Endian endian) {
  if (bytes.length < 4) {
    return '';
  }
  final buffer = StringBuffer();
  final view = bytes.buffer.asByteData();
  final usableLength = bytes.length - (bytes.length % 4);
  for (var offset = 4; offset < usableLength; offset += 4) {
    final codePoint = view.getUint32(offset, endian);
    if (codePoint == 0) {
      continue;
    }
    buffer.writeCharCode(codePoint);
  }
  return buffer.toString();
}

String _decodeUtf16(Uint8List bytes, Endian endian) {
  if (bytes.length < 2) {
    return '';
  }
  final view = bytes.buffer.asByteData();
  final usableLength = bytes.length - (bytes.length % 2);
  final codeUnits = <int>[];
  for (var offset = 2; offset < usableLength; offset += 2) {
    final value = view.getUint16(offset, endian);
    if (value == 0) {
      continue;
    }
    codeUnits.add(value);
  }
  final buffer = StringBuffer();
  for (var i = 0; i < codeUnits.length; i++) {
    final unit = codeUnits[i];
    if (_isHighSurrogate(unit) && i + 1 < codeUnits.length) {
      final next = codeUnits[i + 1];
      if (_isLowSurrogate(next)) {
        final composed = 0x10000 + ((unit - 0xD800) << 10) + (next - 0xDC00);
        buffer.writeCharCode(composed);
        i++;
        continue;
      }
    }
    buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

bool _isHighSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;
bool _isLowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;

ActivityParseResult _parseBytesWithBom(
  Uint8List bytes,
  ActivityFileFormat format,
  Encoding encoding,
) {
  if (format != ActivityFileFormat.fit) {
    final bomDecoder = _decoderForBom(bytes);
    if (bomDecoder != null) {
      final decoded = bomDecoder(bytes);
      return ActivityParser.parse(decoded, format);
    }
  }
  return ActivityParser.parseBytes(bytes, format, encoding: encoding);
}

bool _shouldFailFitIntegrity(
  ActivityFileFormat format,
  Iterable<ParseDiagnostic> diagnostics,
  bool strict,
) =>
    strict &&
    format == ActivityFileFormat.fit &&
    diagnostics.any(
      (d) =>
          d.severity == ParseSeverity.error &&
          (d.code.startsWith('fit.header') || d.code.startsWith('fit.trailer')),
    );

bool _resolveStrictFitHandling({
  required bool strictFitIntegrity,
  required FitCorruptionHandling fitCorruptionHandling,
}) =>
    strictFitIntegrity || fitCorruptionHandling == FitCorruptionHandling.strict;

FormatException _fitIntegrityFailure(Iterable<ParseDiagnostic> diagnostics) {
  final diagnosticInfo = diagnostics.isEmpty
      ? ''
      : '\nDiagnostics: ${diagnostics.map((d) => "${d.code} (${d.severity.name})").join(", ")}\n';
  return FormatException(
    'FIT integrity check failed. The file may be corrupted or incomplete.$diagnosticInfo'
    '\n'
    'Troubleshooting steps:\n'
    '  1. Verify the file is complete (not truncated during transfer)\n'
    '  2. Check that header/trailer CRCs are valid using FIT tools\n'
    '  3. Try loading with strictFitIntegrity: false to recover partial data\n'
    '  4. If the file was downloaded/transferred, retry the transfer\n'
    '\n'
    'If you need to proceed despite errors, use strictFitIntegrity: false.',
  );
}

class _ResolvedSource {
  _ResolvedSource({
    required this.payload,
    required this.description,
    this.fileExtension,
    this.detectionBytes,
  });

  final Object payload;
  final String description;
  final String? fileExtension;
  final Uint8List? detectionBytes;
}

class _ReplayableStreamPayload extends Stream<List<int>> {
  _ReplayableStreamPayload(Stream<List<int>> source, {this.bufferLimit})
    : _source = source;

  final Stream<List<int>> _source;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final Completer<void> _completed = Completer<void>();
  final int? bufferLimit;
  Uint8List? _bytes;
  int _bufferedBytes = 0;
  bool _listened = false;
  Object? _error;
  StackTrace? _errorStack;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listened) {
      throw StateError('Stream payloads can only be listened to once.');
    }
    _listened = true;
    return _source.listen(
      (chunk) {
        if (_completed.isCompleted) {
          return;
        }
        try {
          if (chunk.isNotEmpty) {
            _addChunk(chunk, limit: bufferLimit);
          }
          onData?.call(chunk);
        } catch (error, stackTrace) {
          _finalize(error: error, stackTrace: stackTrace);
          if (onError == null) {
            Zone.current.handleUncaughtError(error, stackTrace);
          } else if (onError is void Function(Object, StackTrace)) {
            onError(error, stackTrace);
          } else {
            (onError as void Function(Object))(error);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _finalize(error: error, stackTrace: stackTrace);
        if (onError == null) {
          Zone.current.handleUncaughtError(error, stackTrace);
        } else if (onError is void Function(Object, StackTrace)) {
          onError(error, stackTrace);
        } else {
          (onError as void Function(Object))(error);
        }
      },
      onDone: () {
        _finalize();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
  }

  Future<Uint8List> materialize({int? maxBytes}) async {
    if (!_listened) {
      _listened = true;
      try {
        await for (final chunk in _source) {
          _addChunk(chunk, limit: maxBytes);
        }
        _finalize();
      } catch (error, stackTrace) {
        _finalize(error: error, stackTrace: stackTrace);
        Error.throwWithStackTrace(error, stackTrace);
      }
    } else if (!_completed.isCompleted) {
      await _completed.future;
    }
    if (_error != null) {
      Error.throwWithStackTrace(_error!, _errorStack ?? StackTrace.current);
    }
    final bytes = _bytes ?? _buffer.takeBytes();
    if (maxBytes != null && bytes.length > maxBytes) {
      throw FormatException(
        'Stream payload exceeds $maxBytes bytes. Hint: prefer streamed workflows (`ActivityParser.parseStream`, `convertStream`) or raise `maxPayloadBytes` for `import`/`convert`/`export`.',
      );
    }
    return bytes;
  }

  void _addChunk(List<int> chunk, {int? limit}) {
    final threshold = limit ?? bufferLimit;
    if (threshold != null && _bufferedBytes + chunk.length > threshold) {
      throw FormatException(
        'Stream payload exceeds $threshold bytes. Hint: increase buffer limit via `maxPayloadBytes` or switch to processing pipelines that don’t require full buffering.',
      );
    }
    _buffer.add(chunk);
    _bufferedBytes += chunk.length;
  }

  void _finalize({Object? error, StackTrace? stackTrace}) {
    if (_completed.isCompleted) {
      return;
    }
    _bytes ??= _buffer.takeBytes();
    if (error != null) {
      _error = error;
      _errorStack = stackTrace;
      _completed.completeError(error, stackTrace);
    } else {
      _completed.complete();
    }
  }
}

void _enforcePayloadLimit(
  Object payload, {
  required Encoding encoding,
  required int limit,
}) {
  int sizeBytes;
  if (payload is Uint8List) {
    sizeBytes = payload.length;
  } else if (payload is List<int>) {
    sizeBytes = payload.length;
  } else if (payload is String) {
    sizeBytes = encoding.encode(payload).length;
  } else {
    return;
  }
  if (sizeBytes > limit) {
    throw FormatException(
      'Payload exceeds $limit bytes. Hint: use streaming APIs (`ActivityParser.parseStream`, `convertStream`) or increase `maxPayloadBytes` on `import`/`convert`/`export`. Pass `null` to disable the limit if you fully trust the input size.',
    );
  }
}
