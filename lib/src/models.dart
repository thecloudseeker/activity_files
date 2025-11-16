// SPDX-License-Identifier: BSD-3-Clause
import 'dart:math' as math;

/// Supported file formats for activities.
enum ActivityFileFormat { gpx, tcx, fit }

/// Supported sports.
enum Sport { unknown, running, cycling, swimming, hiking, walking, other }

/// Location sample expressed as timestamp + geographic coordinates.
typedef LocationStreamSample = ({
  int timestamp,
  double latitude,
  double longitude,
  double? elevation,
});

/// Channel sample expressed as timestamp + numeric value.
typedef ChannelStreamSample = ({int timestamp, num value});

/// Converter that turns raw integer timestamps into UTC [DateTime] instances.
typedef StreamTimestampDecoder = DateTime Function(int timestamp);

/// Known FIT manufacturer identifiers.
/// Source: Garmin FIT SDK (FitSDKRelease_21.141.00, `c/fit_example.h`).
/// TODO(fit-manufacturers): Auto-generate the full set (223 entries) directly
/// from the SDK profile to avoid manual drift while keeping this map `const`
/// so lookups stay O(1) even with the larger vendor list.
const Map<int, String> fitManufacturerNames = {
  1: 'Garmin',
  2: 'Garmin FR405 ANTFS',
  3: 'Zephyr',
  9: 'Saris',
  12: 'Echowell',
  13: 'Dynastream OEM',
  15: 'Dynastream',
  20: 'Cardiosport',
  22: 'HMM',
  23: 'Suunto',
  25: 'GPulse',
  32: 'Wahoo Fitness',
  36: 'Citizen Systems',
  38: 'o-synce',
  53: 'Seiko Epson OEM',
  55: 'Maxwell Guider',
  63: 'Specialized',
  69: 'Stages Cycling',
  70: 'Sigma Sport',
  76: 'Moxy',
  79: 'Acorn Projects APS',
  89: 'Tacx',
  112: 'Bryton Sensors',
  144: 'Zwift Byte',
  255: 'Development',
  260: 'Zwift',
  267: 'Bryton',
  289: 'Hammerhead',
};

/// A strongly-typed channel identifier used for sensor samples.
class Channel {
  /// Creates a new channel with the provided [id].
  ///
  /// The [id] is normalized to lowercase to ensure deterministic equality.
  factory Channel.custom(String id) => Channel._(_normalize(id));
  const Channel._(this.id);

  /// Primary heart-rate channel.
  static const Channel heartRate = Channel._('heart_rate');

  /// Primary cadence channel.
  static const Channel cadence = Channel._('cadence');

  /// Primary power channel.
  static const Channel power = Channel._('power');

  /// Primary temperature channel.
  static const Channel temperature = Channel._('temperature');

  /// Derived speed channel (m/s).
  static const Channel speed = Channel._('speed');

  /// Derived distance channel (meters).
  static const Channel distance = Channel._('distance');

  /// Unique identifier for the channel.
  final String id;
  static String _normalize(String value) => value.trim().toLowerCase();
  @override
  bool operator ==(Object other) => other is Channel && other.id == id;
  @override
  int get hashCode => id.hashCode;
  @override
  String toString() => 'Channel($id)';
}

/// A single geographic sample with associated timestamp.
class GeoPoint {
  GeoPoint({
    required this.latitude,
    required this.longitude,
    this.elevation,
    required DateTime time,
  }) : time = time.toUtc();
  final double latitude;
  final double longitude;
  final double? elevation;
  final DateTime time;
  GeoPoint copyWith({
    double? latitude,
    double? longitude,
    double? elevation,
    DateTime? time,
  }) => GeoPoint(
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    elevation: elevation ?? this.elevation,
    time: (time ?? this.time).toUtc(),
  );
}

/// A generic sensor sample.
class Sample {
  Sample({required DateTime time, required this.value}) : time = time.toUtc();
  final DateTime time;
  final double value;
  Sample copyWith({DateTime? time, double? value}) =>
      Sample(time: (time ?? this.time).toUtc(), value: value ?? this.value);
}

/// Summary information for a lap or segment.
class Lap {
  Lap({
    required DateTime startTime,
    required DateTime endTime,
    this.distanceMeters,
    this.name,
  }) : startTime = startTime.toUtc(),
       endTime = endTime.toUtc();
  final DateTime startTime;
  final DateTime endTime;
  final double? distanceMeters;
  final String? name;
  Duration get elapsed => endTime.difference(startTime);
  Lap copyWith({
    DateTime? startTime,
    DateTime? endTime,
    double? distanceMeters,
    String? name,
  }) => Lap(
    startTime: (startTime ?? this.startTime).toUtc(),
    endTime: (endTime ?? this.endTime).toUtc(),
    distanceMeters: distanceMeters ?? this.distanceMeters,
    name: name ?? this.name,
  );
}

/// Metadata describing the recording device or software.
/// TODO(metadata): Track vendor-specific fields (e.g. Garmin `garmin_product`
/// / `device_index`, Coros `gear_id`) so exporters can round-trip manufacturer
/// quirks without lossy mapping.
class ActivityDeviceMetadata {
  const ActivityDeviceMetadata({
    this.manufacturer,
    this.model,
    this.product,
    this.serialNumber,
    this.softwareVersion,
    this.fitManufacturerId,
    this.fitProductId,
  });

  /// Manufacturer name (e.g. `Garmin`).
  final String? manufacturer;

  /// Device model (e.g. `Forerunner 965`).
  final String? model;

  /// Product identifier or slug.
  final String? product;

  /// Device serial number or unique identifier.
  final String? serialNumber;

  /// Firmware or software version.
  final String? softwareVersion;

  /// Optional explicit FIT manufacturer identifier override.
  final int? fitManufacturerId;

  /// Optional explicit FIT product identifier override.
  final int? fitProductId;

  /// Whether no fields were populated.
  bool get isEmpty =>
      _isBlank(manufacturer) &&
      _isBlank(model) &&
      _isBlank(product) &&
      _isBlank(serialNumber) &&
      _isBlank(softwareVersion) &&
      fitManufacturerId == null &&
      fitProductId == null;

  /// Whether any field is populated.
  bool get isNotEmpty => !isEmpty;

  ActivityDeviceMetadata copyWith({
    String? manufacturer,
    String? model,
    String? product,
    String? serialNumber,
    String? softwareVersion,
    int? fitManufacturerId,
    int? fitProductId,
  }) => ActivityDeviceMetadata(
    manufacturer: manufacturer ?? this.manufacturer,
    model: model ?? this.model,
    product: product ?? this.product,
    serialNumber: serialNumber ?? this.serialNumber,
    softwareVersion: softwareVersion ?? this.softwareVersion,
    fitManufacturerId: fitManufacturerId ?? this.fitManufacturerId,
    fitProductId: fitProductId ?? this.fitProductId,
  );

  static bool _isBlank(String? value) => value == null || value.trim().isEmpty;
}

/// Describes an arbitrary GPX extension node with namespace awareness.
class GpxExtensionNode {
  GpxExtensionNode({
    required this.name,
    this.namespacePrefix,
    this.namespaceUri,
    this.value,
    Map<String, String>? attributes,
    Iterable<GpxExtensionNode>? children,
  }) : attributes = Map.unmodifiable(
         Map<String, String>.from(attributes ?? const <String, String>{}),
       ),
       children = List<GpxExtensionNode>.unmodifiable(
         children ?? const <GpxExtensionNode>[],
       );

  /// Local element name (without prefix).
  final String name;

  /// Namespace prefix applied to the node (e.g. `gpxtpx`).
  final String? namespacePrefix;

  /// Namespace URI corresponding to [namespacePrefix].
  final String? namespaceUri;

  /// Text content to include within the node.
  final String? value;

  /// Attribute map applied to the node.
  final Map<String, String> attributes;

  /// Child elements nested within the node.
  final List<GpxExtensionNode> children;

  GpxExtensionNode copyWith({
    String? name,
    String? namespacePrefix,
    String? namespaceUri,
    String? value,
    Map<String, String>? attributes,
    Iterable<GpxExtensionNode>? children,
  }) => GpxExtensionNode(
    name: name ?? this.name,
    namespacePrefix: namespacePrefix ?? this.namespacePrefix,
    namespaceUri: namespaceUri ?? this.namespaceUri,
    value: value ?? this.value,
    attributes: attributes ?? this.attributes,
    children: children ?? this.children,
  );
}

/// Unified in-memory representation of an activity.
class RawActivity {
  RawActivity({
    Iterable<GeoPoint>? points,
    Map<Channel, Iterable<Sample>>? channels,
    Iterable<Lap>? laps,
    this.sport = Sport.unknown,
    this.creator,
    this.device,
    this.gpxMetadataName,
    this.gpxMetadataDescription,
    this.gpxIncludeCreatorMetadataDescription = true,
    this.gpxTrackName,
    this.gpxTrackDescription,
    this.gpxTrackType,
    Iterable<GpxExtensionNode>? gpxMetadataExtensions,
    Iterable<GpxExtensionNode>? gpxTrackExtensions,
  }) : points = List<GeoPoint>.unmodifiable(points ?? const <GeoPoint>[]),
       channels = Map.unmodifiable({
         for (final entry
             in (channels ?? const <Channel, Iterable<Sample>>{}).entries)
           entry.key: List<Sample>.unmodifiable(
             entry.value.map((sample) => sample.copyWith()),
           ),
       }),
       laps = List<Lap>.unmodifiable(laps ?? const <Lap>[]),
       gpxMetadataExtensions = List<GpxExtensionNode>.unmodifiable(
         gpxMetadataExtensions ?? const <GpxExtensionNode>[],
       ),
       gpxTrackExtensions = List<GpxExtensionNode>.unmodifiable(
         gpxTrackExtensions ?? const <GpxExtensionNode>[],
       );

  /// Sequence of geographic points.
  final List<GeoPoint> points;

  /// Time-aligned sensor channels.
  final Map<Channel, List<Sample>> channels;

  /// Declared laps or segments.
  final List<Lap> laps;

  /// Dominant sport classification.
  final Sport sport;

  /// Name of the originating software or device.
  final String? creator;

  /// Optional device metadata attached to the activity.
  final ActivityDeviceMetadata? device;

  /// Optional metadata title used for GPX encoders.
  final String? gpxMetadataName;

  /// Optional metadata description used for GPX encoders.
  final String? gpxMetadataDescription;

  /// Whether GPX encoders should fall back to [creator] for metadata desc.
  final bool gpxIncludeCreatorMetadataDescription;

  /// Optional track name exposed by GPX encoders.
  final String? gpxTrackName;

  /// Optional track description exposed by GPX encoders.
  final String? gpxTrackDescription;

  /// Optional track type override for GPX encoders.
  final String? gpxTrackType;

  /// GPX metadata-level extensions emitted during encoding.
  final List<GpxExtensionNode> gpxMetadataExtensions;

  /// GPX track-level extensions emitted during encoding.
  final List<GpxExtensionNode> gpxTrackExtensions;

  /// Returns the samples for a given [channel], if present.
  List<Sample> channel(Channel channel) =>
      channels[channel] ?? const <Sample>[];

  /// Creates a copy with overrides.
  RawActivity copyWith({
    Iterable<GeoPoint>? points,
    Map<Channel, Iterable<Sample>>? channels,
    Iterable<Lap>? laps,
    Sport? sport,
    String? creator,
    ActivityDeviceMetadata? device,
    String? gpxMetadataName,
    String? gpxMetadataDescription,
    bool? gpxIncludeCreatorMetadataDescription,
    String? gpxTrackName,
    String? gpxTrackDescription,
    String? gpxTrackType,
    Iterable<GpxExtensionNode>? gpxMetadataExtensions,
    Iterable<GpxExtensionNode>? gpxTrackExtensions,
  }) {
    return RawActivity(
      points: points ?? this.points,
      channels:
          channels ??
          // TODO(perf-copywith-channels): Investigate sharing existing immutable
          // channel/sample lists so a copyWith call that does not touch channels
          // does not incur a deep clone of every sample (currently O(n)).
          {
            for (final entry in this.channels.entries)
              entry.key: entry.value.map((sample) => sample.copyWith()),
          },
      laps: laps ?? this.laps,
      sport: sport ?? this.sport,
      creator: creator ?? this.creator,
      device: device ?? this.device,
      gpxMetadataName: gpxMetadataName ?? this.gpxMetadataName,
      gpxMetadataDescription:
          gpxMetadataDescription ?? this.gpxMetadataDescription,
      gpxIncludeCreatorMetadataDescription:
          gpxIncludeCreatorMetadataDescription ??
          this.gpxIncludeCreatorMetadataDescription,
      gpxTrackName: gpxTrackName ?? this.gpxTrackName,
      gpxTrackDescription: gpxTrackDescription ?? this.gpxTrackDescription,
      gpxTrackType: gpxTrackType ?? this.gpxTrackType,
      gpxMetadataExtensions:
          gpxMetadataExtensions ?? this.gpxMetadataExtensions,
      gpxTrackExtensions: gpxTrackExtensions ?? this.gpxTrackExtensions,
    );
  }

  /// Returns the timestamp of the first point, if any.
  DateTime? get startTime => points.isEmpty ? null : points.first.time;

  /// Returns the timestamp of the last point, if any.
  DateTime? get endTime => points.isEmpty ? null : points.last.time;

  /// Approximates the total distance in meters based on stored channels or
  /// planar projection of geographic points.
  double get approximateDistance {
    // TODO(perf-distance-cache): Cache this derived distance or keep a rolling
    // accumulator because repeated getter calls trigger an O(n) haversine scan
    // with expensive trig for every activity access.
    final distanceSamples = channels[Channel.distance];
    if (distanceSamples != null && distanceSamples.isNotEmpty) {
      return distanceSamples.last.value;
    }
    if (points.length < 2) {
      return 0;
    }
    double total = 0;
    for (var i = 1; i < points.length; i++) {
      total += _haversine(points[i - 1], points[i]);
    }
    return total;
  }

  static double _haversine(GeoPoint a, GeoPoint b) {
    const earthRadius = 6371000; // meters
    final dLat = _radians(b.latitude - a.latitude);
    final dLon = _radians(b.longitude - a.longitude);
    final lat1 = _radians(a.latitude);
    final lat2 = _radians(b.latitude);
    final sinDLat = math.sin(dLat / 2);
    final sinDLon = math.sin(dLon / 2);
    final h =
        sinDLat * sinDLat + math.cos(lat1) * math.cos(lat2) * sinDLon * sinDLon;
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return earthRadius * c;
  }

  static double _radians(double deg) => deg * math.pi / 180.0;
}
