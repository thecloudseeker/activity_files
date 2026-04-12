import '../models.dart';

/// Encodes activity data to CSV format
/// Supports export of trackpoints with channel metrics
class CsvEncoder {
  /// Encode single RawActivity to CSV format
  ///
  /// Returns CSV string with headers and trackpoint data
  static String encode(RawActivity activity) {
    final buffer = StringBuffer();

    // Write CSV header
    buffer.writeln(
      'timestamp,latitude,longitude,elevation,heart_rate,cadence,power,temperature,distance,speed,sport',
    );

    // Build channel lookup by timestamp
    final channelsByTime = <DateTime, Map<Channel, double>>{};
    for (final entry in activity.channels.entries) {
      for (final sample in entry.value) {
        final values = channelsByTime.putIfAbsent(sample.time, () => {});
        values[entry.key] = sample.value;
      }
    }

    // Write each point with channel data
    for (final point in activity.points) {
      final values = channelsByTime[point.time] ?? {};
      final fields = [
        _formatCsvField(point.time.toIso8601String()),
        _formatCsvField(point.latitude.toString()),
        _formatCsvField(point.longitude.toString()),
        _formatCsvField(point.elevation?.toString() ?? ''),
        _formatCsvField(
          _getChannelValue(values, Channel.heartRate)?.toString() ?? '',
        ),
        _formatCsvField(
          _getChannelValue(values, Channel.cadence)?.toString() ?? '',
        ),
        _formatCsvField(
          _getChannelValue(values, Channel.power)?.toString() ?? '',
        ),
        _formatCsvField(
          _getChannelValue(values, Channel.temperature)?.toString() ?? '',
        ),
        _formatCsvField(
          _getChannelValue(values, Channel.distance)?.toString() ?? '',
        ),
        _formatCsvField(
          _getChannelValue(values, Channel.speed)?.toString() ?? '',
        ),
        _formatCsvField(activity.sport.name),
      ];
      buffer.writeln(fields.join(','));
    }

    return buffer.toString();
  }

  /// Encode multiple RawActivity objects to CSV
  ///
  /// Returns CSV string with headers and data from all activities
  static String encodeMultiple(List<RawActivity> activities) {
    if (activities.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();

    // Write header
    buffer.writeln(
      'timestamp,latitude,longitude,elevation,heart_rate,cadence,power,temperature,distance,speed,sport',
    );

    // Write data from all activities
    for (final activity in activities) {
      // Build channel lookup by timestamp
      final channelsByTime = <DateTime, Map<Channel, double>>{};
      for (final entry in activity.channels.entries) {
        for (final sample in entry.value) {
          final values = channelsByTime.putIfAbsent(sample.time, () => {});
          values[entry.key] = sample.value;
        }
      }

      // Write each point
      for (final point in activity.points) {
        final values = channelsByTime[point.time] ?? {};
        final fields = [
          _formatCsvField(point.time.toIso8601String()),
          _formatCsvField(point.latitude.toString()),
          _formatCsvField(point.longitude.toString()),
          _formatCsvField(point.elevation?.toString() ?? ''),
          _formatCsvField(
            _getChannelValue(values, Channel.heartRate)?.toString() ?? '',
          ),
          _formatCsvField(
            _getChannelValue(values, Channel.cadence)?.toString() ?? '',
          ),
          _formatCsvField(
            _getChannelValue(values, Channel.power)?.toString() ?? '',
          ),
          _formatCsvField(
            _getChannelValue(values, Channel.temperature)?.toString() ?? '',
          ),
          _formatCsvField(
            _getChannelValue(values, Channel.distance)?.toString() ?? '',
          ),
          _formatCsvField(
            _getChannelValue(values, Channel.speed)?.toString() ?? '',
          ),
          _formatCsvField(activity.sport.name),
        ];
        buffer.writeln(fields.join(','));
      }
    }

    return buffer.toString();
  }

  /// Get channel value from map, or null if not present
  static double? _getChannelValue(
    Map<Channel, double> values,
    Channel channel,
  ) {
    return values[channel];
  }

  /// Format field for CSV (escape quotes and wrap if needed)
  static String _formatCsvField(String? value) {
    if (value == null || value.isEmpty) {
      return '';
    }
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
