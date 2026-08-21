import '../models.dart';
import 'encoder_options.dart';
import 'encoder_utils.dart';

/// Encodes activity data to CSV format
/// Supports export of trackpoints with channel metrics
class CsvEncoder {
  static const String _header =
      'timestamp,latitude,longitude,elevation,heart_rate,cadence,power,temperature,distance,speed,sport';

  /// Channel columns in header order.
  static const List<Channel> _channelColumns = [
    Channel.heartRate,
    Channel.cadence,
    Channel.power,
    Channel.temperature,
    Channel.distance,
    Channel.speed,
  ];

  /// Every fixed column id, not just the channel-shaped ones: a custom
  /// channel named `elevation`/`latitude`/`longitude`/`timestamp`/`sport`
  /// must not become an "extra" column either, or it collides with (and on
  /// re-parse silently overwrites) the real point field of the same name.
  static const Set<String> _reservedColumnIds = {
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

  /// Encode single RawActivity to CSV format
  ///
  /// Returns CSV string with headers and trackpoint data
  static String encode(
    RawActivity activity, {
    EncoderOptions options = const EncoderOptions(),
  }) {
    // CSV rows are a single flat stream; merge multi-track input.
    final flat = activity.flattened();
    final extras = _extraChannels([flat]);
    final buffer = StringBuffer()..writeln(_headerWith(extras));
    _writeRows(buffer, flat, extras, options);
    return buffer.toString();
  }

  /// Encode multiple RawActivity objects to CSV
  ///
  /// Returns CSV string with headers and data from all activities
  static String encodeMultiple(
    List<RawActivity> activities, {
    EncoderOptions options = const EncoderOptions(),
  }) {
    if (activities.isEmpty) {
      return '';
    }
    final flats = [for (final activity in activities) activity.flattened()];
    final extras = _extraChannels(flats);
    final buffer = StringBuffer()..writeln(_headerWith(extras));
    for (final flat in flats) {
      _writeRows(buffer, flat, extras, options);
    }
    return buffer.toString();
  }

  /// Channels beyond the fixed columns, written as additional columns so no
  /// channel data is lost. Sorted by id for deterministic output.
  static List<Channel> _extraChannels(List<RawActivity> activities) => {
    for (final activity in activities)
      for (final channel in activity.channels.keys)
        if (!_reservedColumnIds.contains(channel.id)) channel,
  }.toList()..sort((a, b) => a.id.compareTo(b.id));

  static String _headerWith(List<Channel> extras) => extras.isEmpty
      ? _header
      : '$_header,${extras.map((c) => _formatCsvField(c.id)).join(',')}';

  /// Write one CSV row per point, joining channel values by timestamp.
  static void _writeRows(
    StringBuffer buffer,
    RawActivity activity,
    List<Channel> extras,
    EncoderOptions options,
  ) {
    final channelsByTime = channelValuesByTime(activity.channels);
    for (final point in activity.points) {
      final values = channelsByTime[point.time] ?? const {};
      final fields = [
        point.time.toIso8601String(),
        point.latitude.toStringAsFixed(options.precisionLatLon),
        point.longitude.toStringAsFixed(options.precisionLatLon),
        point.elevation?.toStringAsFixed(options.precisionEle) ?? '',
        for (final channel in _channelColumns)
          values[channel]?.toString() ?? '',
        activity.sport.name,
        for (final channel in extras) values[channel]?.toString() ?? '',
      ].map(_formatCsvField);
      buffer.writeln(fields.join(','));
    }
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
