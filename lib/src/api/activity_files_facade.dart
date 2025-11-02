// SPDX-License-Identifier: BSD-3-Clause
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../encode/activity_encoder.dart';
import '../encode/encoder_options.dart';
import '../models.dart';
import '../parse/activity_parser.dart';
import '../parse/parse_result.dart';
import '../transforms.dart';

/// Top-level facade exposing ergonomic helpers for app integrations.
class ActivityFiles {
  const ActivityFiles._();

  /// Loads [source] into a [RawActivity], attempting to infer the file format.
  ///
  /// Supported source types:
  /// * `String` containing either inline text content or a path to a file.
  /// * `File`
  /// * `List<int>`/`Uint8List` with raw bytes (FIT binaries or already-encoded
  ///   text).
  /// * `Stream<List<int>>` representing chunked payloads.
  ///
  /// When [format] is omitted the loader will attempt to detect it from file
  /// extensions or by inspecting the payload. Specify [format] when the input
  /// is ambiguous (e.g. a FIT payload provided as a base64 string).
  static Future<ActivityLoadResult> load(
    Object source, {
    ActivityFileFormat? format,
    bool useIsolate = true,
    Encoding encoding = utf8,
  }) async {
    final resolved = await _resolveSource(source);
    final detected = format ?? _detectFormat(resolved, encoding: encoding);
    if (detected == null) {
      throw ArgumentError(
        'Unable to infer activity format. Provide format explicitly.',
      );
    }
    final parseResult = await _parseResolved(
      resolved.payload,
      detected,
      useIsolate: useIsolate,
    );
    return ActivityLoadResult._(
      activity: parseResult.activity,
      diagnostics: List.unmodifiable(parseResult.diagnostics),
      format: detected,
      sourceDescription: resolved.description,
      payload: resolved.payload,
    );
  }

  /// Converts [source] to [to], optionally inferring the source format.
  ///
  /// The returned [ActivityConversionResult] exposes the normalized activity,
  /// encoder output, and parser diagnostics gathered while loading the source.
  /// When [normalize] is `true` (default) the converter applies
  /// `RawEditor.sortAndDedup()` and `RawEditor.trimInvalid()` prior to encoding.
  static Future<ActivityConversionResult> convert({
    required Object source,
    required ActivityFileFormat to,
    ActivityFileFormat? from,
    EncoderOptions options = const EncoderOptions(),
    bool normalize = true,
    bool useIsolate = true,
    Encoding encoding = utf8,
  }) async {
    final loadResult = await load(
      source,
      format: from,
      useIsolate: useIsolate,
      encoding: encoding,
    );
    var activity = loadResult.activity;
    if (normalize) {
      activity = RawEditor(activity).sortAndDedup().trimInvalid().activity;
    }
    final encoded = ActivityEncoder.encode(activity, to, options: options);
    final binary = to == ActivityFileFormat.fit
        ? Uint8List.fromList(base64Decode(encoded))
        : null;
    return ActivityConversionResult._(
      activity: activity,
      sourceFormat: loadResult.format,
      targetFormat: to,
      diagnostics: List.unmodifiable(loadResult.diagnostics),
      encoderOptions: options,
      encoded: encoded,
      binary: binary,
    );
  }

  /// Starts a builder for assembling a [RawActivity] incrementally.
  ///
  /// Use [seed] to pre-populate the builder from an existing activity.
  static RawActivityBuilder builder([RawActivity? seed]) =>
      RawActivityBuilder(seed: seed);

  /// Returns a [RawEditor] for fluent editing pipelines.
  static RawEditor edit(RawActivity activity) => RawEditor(activity);

  /// Attempts to detect the activity format without parsing.
  ///
  /// This helper is useful when you want to branch your own logic based on
  /// format before calling [load] or [convert].
  static ActivityFileFormat? detectFormat(
    Object source, {
    Encoding encoding = utf8,
  }) => _detectFormatSync(source, encoding: encoding);

  static Future<_ResolvedSource> _resolveSource(Object source) async {
    if (source is _ResolvedSource) {
      return source;
    }
    if (source is Stream<List<int>>) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in source) {
        if (chunk.isNotEmpty) {
          builder.add(chunk);
        }
      }
      return _ResolvedSource(
        payload: builder.takeBytes(),
        description: 'stream',
      );
    }
    if (source is Uint8List) {
      return _ResolvedSource(
        payload: Uint8List.fromList(source),
        description: 'bytes',
      );
    }
    if (source is List<int>) {
      return _ResolvedSource(
        payload: Uint8List.fromList(source),
        description: 'bytes',
      );
    }
    if (source is File) {
      final bytes = await source.readAsBytes();
      return _ResolvedSource(
        payload: bytes,
        description: source.path,
        fileExtension: _extensionForPath(source.path),
      );
    }
    if (source is String) {
      final file = File(source);
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        return _ResolvedSource(
          payload: bytes,
          description: file.path,
          fileExtension: _extensionForPath(file.path),
        );
      }
      return _ResolvedSource(payload: source, description: 'inline');
    }
    throw ArgumentError('Unsupported source type ${source.runtimeType}.');
  }

  static ActivityFileFormat? _detectFormat(
    _ResolvedSource resolved, {
    required Encoding encoding,
  }) {
    final detectedFromExt = _detectFromExtension(resolved.fileExtension);
    if (detectedFromExt != null) {
      return detectedFromExt;
    }
    return _detectFromPayload(resolved.payload, encoding: encoding);
  }

  static ActivityParseResult _parseSync(
    Object payload,
    ActivityFileFormat format,
  ) {
    return switch (payload) {
      String text => ActivityParser.parse(text, format),
      Uint8List bytes => ActivityParser.parseBytes(bytes, format),
      List<int> bytes => ActivityParser.parseBytes(bytes, format),
      _ => throw ArgumentError(
        'Unsupported payload type ${payload.runtimeType}; expected String or List<int>.',
      ),
    };
  }

  static Future<ActivityParseResult> _parseResolved(
    Object payload,
    ActivityFileFormat format, {
    bool useIsolate = true,
  }) {
    if (!useIsolate) {
      return Future.value(_parseSync(payload, format));
    }
    return Isolate.run(() => _parseSync(payload, format));
  }

  static ActivityFileFormat? _detectFormatSync(
    Object source, {
    required Encoding encoding,
  }) {
    if (source is _ResolvedSource) {
      return _detectFormat(source, encoding: encoding);
    }
    if (source is String) {
      final file = File(source);
      if (file.existsSync()) {
        return _detectFromExtension(_extensionForPath(file.path));
      }
      return _detectFromPayload(source, encoding: encoding);
    }
    if (source is File) {
      return _detectFromExtension(_extensionForPath(source.path));
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

  static ActivityFileFormat? _detectFromExtension(String? ext) {
    switch (ext) {
      case '.gpx':
        return ActivityFileFormat.gpx;
      case '.tcx':
        return ActivityFileFormat.tcx;
      case '.fit':
        return ActivityFileFormat.fit;
      default:
        return null;
    }
  }

  static ActivityFileFormat? _detectFromPayload(
    Object payload, {
    required Encoding encoding,
  }) {
    if (payload is String) {
      final trimmed = payload.trimLeft();
      if (trimmed.startsWith('<')) {
        final lower = trimmed.toLowerCase();
        if (lower.contains('<gpx')) {
          return ActivityFileFormat.gpx;
        }
        if (lower.contains('trainingcenterdatabase') ||
            lower.contains('<tcx')) {
          return ActivityFileFormat.tcx;
        }
      }
      if (_looksBase64(trimmed)) {
        return ActivityFileFormat.fit;
      }
      return null;
    }
    final bytes = payload is Uint8List
        ? payload
        : Uint8List.fromList(payload as List<int>);
    if (_looksBinary(bytes)) {
      return ActivityFileFormat.fit;
    }
    final asText = utf8.decode(bytes, allowMalformed: true).trimLeft();
    if (asText.startsWith('<')) {
      final lower = asText.toLowerCase();
      if (lower.contains('<gpx')) {
        return ActivityFileFormat.gpx;
      }
      if (lower.contains('trainingcenterdatabase') || lower.contains('<tcx')) {
        return ActivityFileFormat.tcx;
      }
    }
    if (_looksBase64(asText)) {
      return ActivityFileFormat.fit;
    }
    return null;
  }

  static String? _extensionForPath(String path) {
    final normalized = path.trim();
    final dot = normalized.lastIndexOf('.');
    if (dot < 0 || dot == normalized.length - 1) {
      return null;
    }
    return normalized.substring(dot).toLowerCase();
  }

  static bool _looksBinary(Uint8List bytes) {
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

  static bool _looksBase64(String text) {
    final trimmed = text.replaceAll(RegExp(r'\s+'), '');
    if (trimmed.isEmpty || trimmed.length % 4 != 0) {
      return false;
    }
    return RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(trimmed);
  }
}

/// Result of [ActivityFiles.load].
class ActivityLoadResult {
  ActivityLoadResult._({
    required this.activity,
    required this.diagnostics,
    required this.format,
    required this.sourceDescription,
    required this.payload,
  });

  /// Parsed activity.
  final RawActivity activity;

  /// Diagnostics emitted while parsing.
  final List<ParseDiagnostic> diagnostics;

  /// Detected format of the payload.
  final ActivityFileFormat format;

  /// Human-readable description of the source (e.g. file path).
  final String sourceDescription;

  /// Raw payload used during parsing (String or Uint8List).
  final Object payload;

  /// Returns the raw payload as bytes when available.
  Uint8List? get bytesPayload =>
      payload is Uint8List ? payload as Uint8List : null;

  /// Returns the raw payload as text when available.
  String? get stringPayload => payload is String ? payload as String : null;
}

/// Result of [ActivityFiles.convert].
class ActivityConversionResult {
  ActivityConversionResult._({
    required this.activity,
    required this.sourceFormat,
    required this.targetFormat,
    required this.diagnostics,
    required this.encoderOptions,
    required this.encoded,
    Uint8List? binary,
  }) : _binary = binary;

  /// Normalized activity that was encoded.
  final RawActivity activity;

  /// Detected format of the source payload.
  final ActivityFileFormat sourceFormat;

  /// Format used for the encoded payload.
  final ActivityFileFormat targetFormat;

  /// Parser diagnostics encountered while loading the source.
  final List<ParseDiagnostic> diagnostics;

  /// Encoder options used for the conversion.
  final EncoderOptions encoderOptions;

  /// Encoder output as a string. FIT payloads are base64 strings.
  final String encoded;

  final Uint8List? _binary;

  /// Whether the payload is binary (FIT).
  bool get isBinary => targetFormat == ActivityFileFormat.fit;

  /// Returns the payload Bytes.
  Uint8List asBytes({Encoding encoding = utf8}) {
    if (isBinary) {
      return Uint8List.fromList(_binary ?? base64Decode(encoded));
    }
    return Uint8List.fromList(encoding.encode(encoded));
  }

  /// Returns the payload as a string, decoding binary payloads to base64.
  String asString() => encoded;
}

/// Fluent builder for assembling [RawActivity] instances.
class RawActivityBuilder {
  RawActivityBuilder({RawActivity? seed})
    : sport = seed?.sport ?? Sport.unknown,
      creator = seed?.creator {
    if (seed != null) {
      addPoints(seed.points);
      seed.channels.forEach(addChannel);
      addLaps(seed.laps);
    }
  }

  /// Dominant sport classification.
  Sport sport;

  /// Originating device or software label.
  String? creator;

  final List<GeoPoint> _points = <GeoPoint>[];
  final Map<Channel, List<Sample>> _channels = <Channel, List<Sample>>{};
  final List<Lap> _laps = <Lap>[];

  /// Adds a geographic point.
  RawActivityBuilder addPoint({
    required double latitude,
    required double longitude,
    double? elevation,
    required DateTime time,
  }) {
    _points.add(
      GeoPoint(
        latitude: latitude,
        longitude: longitude,
        elevation: elevation,
        time: time,
      ),
    );
    return this;
  }

  /// Adds multiple points.
  RawActivityBuilder addPoints(Iterable<GeoPoint> points) {
    _points.addAll(points.map((point) => point.copyWith()));
    return this;
  }

  /// Adds or replaces a channel with the provided samples.
  RawActivityBuilder addChannel(Channel channel, Iterable<Sample> samples) {
    _channels[channel] = samples.map((sample) => sample.copyWith()).toList();
    return this;
  }

  /// Adds a single sample to [channel].
  RawActivityBuilder addSample({
    required Channel channel,
    required DateTime time,
    required double value,
  }) {
    final list = _channels.putIfAbsent(channel, () => <Sample>[]);
    list.add(Sample(time: time, value: value));
    return this;
  }

  /// Appends laps.
  RawActivityBuilder addLaps(Iterable<Lap> laps) {
    _laps.addAll(laps.map((lap) => lap.copyWith()));
    return this;
  }

  /// Adds a single lap.
  RawActivityBuilder addLap({
    required DateTime startTime,
    required DateTime endTime,
    double? distanceMeters,
    String? name,
  }) {
    _laps.add(
      Lap(
        startTime: startTime,
        endTime: endTime,
        distanceMeters: distanceMeters,
        name: name,
      ),
    );
    return this;
  }

  /// Builds the immutable [RawActivity].
  ///
  /// When [normalize] is `true` (default) the builder applies sorting and
  /// trimming to match encoder expectations.
  RawActivity build({bool normalize = true}) {
    final activity = RawActivity(
      points: _points.map((point) => point.copyWith()).toList(),
      channels: {
        for (final entry in _channels.entries)
          entry.key: entry.value.map((sample) => sample.copyWith()),
      },
      laps: _laps.map((lap) => lap.copyWith()).toList(),
      sport: sport,
      creator: creator,
    );
    if (!normalize) {
      return activity;
    }
    return RawEditor(activity).sortAndDedup().trimInvalid().activity;
  }

  /// Resets the builder state.
  void clear() {
    _points.clear();
    _channels.clear();
    _laps.clear();
    sport = Sport.unknown;
    creator = null;
  }
}

class _ResolvedSource {
  _ResolvedSource({
    required this.payload,
    required this.description,
    this.fileExtension,
  });

  final Object payload;
  final String description;
  final String? fileExtension;
}
