// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';
import 'activity_parser.dart';
import 'csv_reader.dart';
import 'number_utils.dart';
import 'parse_result.dart';
import 'timestamp_utils.dart';

/// Parser for CSV format activity files
/// Supports CSV exports from various tracking platforms
class CsvParser implements ActivityFormatParser {
  const CsvParser();

  @override
  ActivityParseResult parse(String input) {
    final diagnostics = <ParseDiagnostic>[];

    try {
      // Empty lines stay rows, so the row numbers in the diagnostics below
      // follow the file; blank rows are skipped in the loop instead.
      final read = readCsv(input);
      final csvData = read.rows;
      if (read.delimiter != ',') {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.info,
            code: 'csv.header.delimiter',
            message:
                'Columns are separated by '
                '${read.delimiter == '\t' ? 'tabs' : '"${read.delimiter}"'}, '
                'found in the header line.',
          ),
        );
      }

      if (csvData.isEmpty) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.error,
            code: 'csv.empty',
            message: 'CSV file is empty',
          ),
        );
        return ActivityParseResult(
          activity: RawActivity(),
          diagnostics: diagnostics,
        );
      }

      final headers = csvData.first.map((value) => value.toString()).toList();
      final headerMap = _createHeaderMap(headers, diagnostics);

      final points = <GeoPoint>[];
      final channelMap = <Channel, List<Sample>>{};
      Sport sport = Sport.unknown;

      for (int i = 1; i < csvData.length; i++) {
        final row = csvData[i].map((value) => value.toString()).toList();
        if (row.isEmpty || row.every((v) => v.isEmpty)) continue;

        final timestamp = _parseDateTime(row, headerMap, 'timestamp');
        if (timestamp == null) {
          diagnostics.add(
            ParseDiagnostic(
              severity: ParseSeverity.warning,
              code: 'csv.row.invalid_timestamp',
              message:
                  'Row ${i + 1} has a missing or unparseable "timestamp" '
                  'column; row skipped.',
            ),
          );
          continue;
        }

        final latitude = _parseDouble(row, headerMap, 'latitude');
        final longitude = _parseDouble(row, headerMap, 'longitude');

        if (latitude == null || longitude == null) {
          diagnostics.add(
            ParseDiagnostic(
              severity: ParseSeverity.warning,
              code: 'csv.row.invalid_coordinates',
              message:
                  'Row ${i + 1} has a missing or unparseable "latitude"/'
                  '"longitude" column; row skipped.',
            ),
          );
          continue;
        }

        double? optional(String column) =>
            _parseOptionalDouble(row, headerMap, column, i + 1, diagnostics);

        final point = GeoPoint(
          latitude: latitude,
          longitude: longitude,
          elevation: optional('elevation'),
          time: timestamp,
        );
        points.add(point);

        // Capture sport if available
        final sportValue = _getString(row, headerMap, 'sport');
        if (sportValue != null && sport == Sport.unknown) {
          sport = _parseSport(sportValue);
        }

        // Parse optional channel samples
        _addChannelSample(
          channelMap,
          Channel.heartRate,
          optional('heart_rate'),
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.cadence,
          optional('cadence'),
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.speed,
          optional('speed'),
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.power,
          optional('power'),
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.temperature,
          optional('temperature'),
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.distance,
          optional('distance'),
          timestamp,
        );
        // Unknown numeric columns are preserved as custom channels so our
        // own format is lossless (Channel.custom normalizes the name, so a
        // column matching a built-in channel id maps onto that channel).
        for (final entry in headerMap.entries) {
          if (_knownColumns.contains(entry.key)) continue;
          final index = entry.value;
          if (index >= row.length) continue;
          final text = row[index].trim();
          // Non-numeric text in an unknown column is free text and stays
          // out of the channels on purpose; a number that is not finite is
          // reported, since it was meant as a value.
          if (isNonFiniteNumber(text)) {
            _addInvalidValue(diagnostics, i + 1, entry.key, text);
            continue;
          }
          final value = double.tryParse(text);
          if (value == null) continue;
          channelMap
              .putIfAbsent(Channel.custom(entry.key), () => [])
              .add(Sample(time: timestamp, value: value));
        }
      }

      if (points.isEmpty) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.error,
            code: 'csv.no_points',
            message: 'No valid trackpoints found in CSV',
          ),
        );
        return ActivityParseResult(
          activity: RawActivity(),
          diagnostics: diagnostics,
        );
      }

      final activity = RawActivity(
        points: points,
        channels: channelMap.isEmpty ? null : channelMap,
        sport: sport,
      );

      return ActivityParseResult(activity: activity, diagnostics: diagnostics);
    } catch (e) {
      diagnostics.add(
        ParseDiagnostic(
          severity: ParseSeverity.error,
          code: 'csv.parse_error',
          message: 'Failed to parse CSV: $e',
        ),
      );
      return ActivityParseResult(
        activity: RawActivity(),
        diagnostics: diagnostics,
      );
    }
  }

  /// Columns with dedicated parsing; all other columns become custom channels.
  static const Set<String> _knownColumns = {
    'timestamp',
    'latitude',
    'longitude',
    'elevation',
    'heart_rate',
    'cadence',
    'power',
    'temperature',
    'distance',
    'speed',
    'sport',
  };

  /// Recognized abbreviations/variants for a handful of the known columns,
  /// mapped to their canonical name. Case-insensitive, matched the same way
  /// the canonical names already are.
  static const Map<String, String> _headerSynonyms = {
    'lat': 'latitude',
    'lng': 'longitude',
    'lon': 'longitude',
    'long': 'longitude',
    'ele': 'elevation',
    'alt': 'elevation',
    'altitude': 'elevation',
    'hr': 'heart_rate',
    'heartrate': 'heart_rate',
  };

  /// Create mapping of header names to column indices. A repeated header
  /// name (including a synonym resolving to an already-seen canonical name)
  /// is reported: the last occurrence wins (matching a spreadsheet's own
  /// left-to-right column precedence), silently shadowing every earlier
  /// column of the same name otherwise.
  static Map<String, int> _createHeaderMap(
    List<String> headers,
    List<ParseDiagnostic> diagnostics,
  ) {
    final map = <String, int>{};
    for (int i = 0; i < headers.length; i++) {
      final raw = headers[i].toLowerCase().trim();
      if (raw.isEmpty) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.warning,
            code: 'csv.header.empty',
            message:
                'Column ${i + 1} has no header, so its values are not read.',
          ),
        );
        continue;
      }
      final normalized = _headerSynonyms[raw] ?? raw;
      if (map.containsKey(normalized)) {
        diagnostics.add(
          ParseDiagnostic(
            severity: ParseSeverity.warning,
            code: 'csv.header.duplicate',
            message:
                'Duplicate CSV header "$raw" at column ${i + 1} (resolves '
                'to "$normalized"); the rightmost column wins, earlier '
                'one(s) are ignored.',
          ),
        );
      }
      map[normalized] = i;
    }
    return map;
  }

  /// Get string value from row
  static String? _getString(
    List<String> row,
    Map<String, int> headerMap,
    String headerName,
  ) {
    final index = headerMap[headerName.toLowerCase()];
    if (index != null && index < row.length) {
      final value = row[index].toString().trim();
      return value.isEmpty ? null : value;
    }
    return null;
  }

  /// Parse double value from row
  static double? _parseDouble(
    List<String> row,
    Map<String, int> headerMap,
    String headerName,
  ) {
    return parseFiniteDouble(_getString(row, headerMap, headerName));
  }

  /// Reads an optional numeric column; a cell that holds text but no finite
  /// number is left out with a warning.
  static double? _parseOptionalDouble(
    List<String> row,
    Map<String, int> headerMap,
    String headerName,
    int rowNumber,
    List<ParseDiagnostic> diagnostics,
  ) {
    final text = _getString(row, headerMap, headerName);
    if (text == null) return null;
    final value = parseFiniteDouble(text);
    if (value == null) {
      _addInvalidValue(diagnostics, rowNumber, headerName, text);
    }
    return value;
  }

  static void _addInvalidValue(
    List<ParseDiagnostic> diagnostics,
    int rowNumber,
    String column,
    String text,
  ) {
    diagnostics.add(
      ParseDiagnostic(
        severity: ParseSeverity.warning,
        code: 'csv.row.invalid_value',
        message:
            'Row $rowNumber has an unreadable "$column" value "$text"; '
            'value left out.',
      ),
    );
  }

  /// Parse DateTime from row
  static DateTime? _parseDateTime(
    List<String> row,
    Map<String, int> headerMap,
    String headerName,
  ) {
    final value = _getString(row, headerMap, headerName);
    if (value != null) {
      try {
        return parseTimestampAssumeUtc(value);
      } catch (_) {}
    }
    return null;
  }

  /// Add a channel sample if the value is present
  static void _addChannelSample(
    Map<Channel, List<Sample>> channelMap,
    Channel channel,
    double? value,
    DateTime timestamp,
  ) {
    if (value != null) {
      channelMap
          .putIfAbsent(channel, () => [])
          .add(Sample(time: timestamp, value: value));
    }
  }

  /// Parse sport from string
  static Sport _parseSport(String value) {
    final sportStr = value.toLowerCase();
    return Sport.values.firstWhere(
      (sport) => sport.name.toLowerCase() == sportStr,
      orElse: () => Sport.unknown,
    );
  }
}
