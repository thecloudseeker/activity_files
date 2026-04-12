import 'package:csv/csv.dart';

import '../models.dart';
import 'activity_parser.dart';
import 'parse_result.dart';

/// Parser for CSV format activity files
/// Supports CSV exports from various tracking platforms
class CsvParser implements ActivityFormatParser {
  const CsvParser();

  @override
  ActivityParseResult parse(String input) {
    final diagnostics = <ParseDiagnostic>[];

    try {
      // CSV 8.0.0: Use new Csv API with skipEmptyLines enabled
      final csvData = Csv(skipEmptyLines: true).decode(input);

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
      final headerMap = _createHeaderMap(headers);

      final points = <GeoPoint>[];
      final channelMap = <Channel, List<Sample>>{};
      Sport sport = Sport.unknown;

      for (int i = 1; i < csvData.length; i++) {
        final row = csvData[i].map((value) => value.toString()).toList();
        if (row.isEmpty || row.every((v) => v.isEmpty)) continue;

        final timestamp = _parseDateTime(row, headerMap, 'timestamp');
        if (timestamp == null) continue;

        final latitude = _parseDouble(row, headerMap, 'latitude');
        final longitude = _parseDouble(row, headerMap, 'longitude');

        if (latitude == null || longitude == null) continue;

        final point = GeoPoint(
          latitude: latitude,
          longitude: longitude,
          elevation: _parseDouble(row, headerMap, 'elevation'),
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
          row,
          headerMap,
          'heart_rate',
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.cadence,
          row,
          headerMap,
          'cadence',
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.speed,
          row,
          headerMap,
          'speed',
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.power,
          row,
          headerMap,
          'power',
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.temperature,
          row,
          headerMap,
          'temperature',
          timestamp,
        );
        _addChannelSample(
          channelMap,
          Channel.distance,
          row,
          headerMap,
          'distance',
          timestamp,
        );
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

  /// Create mapping of header names to column indices
  static Map<String, int> _createHeaderMap(List<String> headers) {
    final map = <String, int>{};
    for (int i = 0; i < headers.length; i++) {
      final normalized = headers[i].toLowerCase().trim();
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
    final value = _getString(row, headerMap, headerName);
    if (value != null) {
      try {
        return double.parse(value);
      } catch (_) {}
    }
    return null;
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
        return DateTime.parse(value);
      } catch (_) {}
    }
    return null;
  }

  /// Add a channel sample if the value is present
  static void _addChannelSample(
    Map<Channel, List<Sample>> channelMap,
    Channel channel,
    List<String> row,
    Map<String, int> headerMap,
    String headerName,
    DateTime timestamp,
  ) {
    final value = _parseDouble(row, headerMap, headerName);
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
