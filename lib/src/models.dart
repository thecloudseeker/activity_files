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
/// Source: Garmin FIT SDK via mrihtar/Garmin-FIT Perl module (auto-generated).
/// Expanded from 28 to 179 entries for comprehensive manufacturer coverage.
const Map<int, String> fitManufacturerNames = {
  1: 'Garmin',
  2: 'Garmin FR405 ANTFS',
  3: 'Zephyr',
  4: 'Dayton',
  5: 'IDT',
  6: 'SRM',
  7: 'Quarq',
  8: 'iBike',
  9: 'Saris',
  10: 'Spark HK',
  11: 'Tanita',
  12: 'Echowell',
  13: 'Dynastream OEM',
  14: 'Nautilus',
  15: 'Dynastream',
  16: 'Timex',
  17: 'Metrigear',
  18: 'Xelic',
  19: 'Beurer',
  20: 'Cardiosport',
  21: 'A&D',
  22: 'HMM',
  23: 'Suunto',
  24: 'Thita Elektronik',
  25: 'GPulse',
  26: 'Clean Mobile',
  27: 'Pedal Brain',
  28: 'Peaksware',
  29: 'Saxonar',
  30: 'LeMond Fitness',
  31: 'Dexcom',
  32: 'Wahoo Fitness',
  33: 'Octane Fitness',
  34: 'Archinoetics',
  35: 'The Hurt Box',
  36: 'Citizen Systems',
  37: 'Magellan',
  38: 'Osynce',
  39: 'Holux',
  40: 'Concept2',
  42: 'One Giant Leap',
  43: 'Ace Sensor',
  44: 'Brim Brothers',
  45: 'Xplova',
  46: 'Perception Digital',
  47: 'BF1systems',
  48: 'Pioneer',
  49: 'Spantec',
  50: 'Metalogics',
  51: '4iiiis',
  52: 'Seiko Epson',
  53: 'Seiko Epson OEM',
  54: 'Ifor Powell',
  55: 'Maxwell Guider',
  56: 'Star Trac',
  57: 'Breakaway',
  58: 'Alatech Technology Ltd',
  59: 'MIO Technology Europe',
  60: 'Rotor',
  61: 'Geonaute',
  62: 'ID Bike',
  63: 'Specialized',
  64: 'Wtek',
  65: 'Physical Enterprises',
  66: 'North Pole Engineering',
  67: 'Bkool',
  68: 'Cateye',
  69: 'Stages Cycling',
  70: 'Sigmasport',
  71: 'TomTom',
  72: 'Peripedal',
  73: 'Wattbike',
  76: 'Moxy',
  77: 'Ciclosport',
  78: 'Powerbahn',
  79: 'Acorn Projects APS',
  80: 'Lifebeam',
  81: 'Bontrager',
  82: 'Wellgo',
  83: 'Scosche',
  84: 'Magura',
  85: 'Woodway',
  86: 'Elite',
  87: 'Nielsen Kellerman',
  88: 'DK City',
  89: 'Tacx',
  90: 'Direction Technology',
  91: 'Magtonic',
  92: '1partCarbon',
  93: 'Inside Ride Technologies',
  94: 'Sound Of Motion',
  95: 'Stryd',
  96: 'ICG',
  97: 'MiPulse',
  98: 'BSX Athletics',
  99: 'Look',
  100: 'Campagnolo SRL',
  101: 'Body Bike Smart',
  102: 'Praxisworks',
  103: 'Limits Technology',
  104: 'Topaction Technology',
  105: 'Cosinuss',
  106: 'Fitcare',
  107: 'Magene',
  108: 'Giant Manufacturing Co',
  109: 'Tigrasport',
  110: 'Salutron',
  111: 'Technogym',
  112: 'Bryton Sensors',
  113: 'Latitude Limited',
  114: 'Soaring Technology',
  115: 'Igpsport',
  116: 'Thinkrider',
  117: 'Gopher Sport',
  118: 'Waterrower',
  119: 'Orangetheory',
  120: 'Inpeak',
  121: 'Kinetic',
  122: 'Johnson Health Tech',
  123: 'Polar Electro',
  124: 'Seesense',
  125: 'NCI Technology',
  126: 'iQsquare',
  127: 'Leomo',
  128: 'iFit.com',
  129: 'Coros Byte',
  130: 'Versa Design',
  131: 'Chileaf',
  132: 'Cycplus',
  255: 'Development',
  257: 'Healthandlife',
  258: 'Lezyne',
  259: 'Scribe Labs',
  260: 'Zwift',
  261: 'Watteam',
  262: 'Recon',
  263: 'Favero Electronics',
  264: 'Dynovelo',
  265: 'Strava',
  266: 'Precor',
  267: 'Bryton',
  268: 'SRAM',
  269: 'Navman',
  270: 'Cobi',
  271: 'Spivi',
  272: 'MIO Magellan',
  273: 'Evesports',
  274: 'Sensitivus Gauge',
  275: 'Podoon',
  276: 'Life Time Fitness',
  277: 'Falco e-Motors',
  278: 'Minoura',
  279: 'Cycliq',
  280: 'Luxottica',
  281: 'TrainerRoad',
  282: 'The Sufferfest',
  283: 'Fullspeedahead',
  284: 'Virtualtraining',
  285: 'Feedbacksports',
  286: 'Omata',
  287: 'VDO',
  288: 'Magneticdays',
  289: 'Hammerhead',
  290: 'Kinetic by Kurt',
  291: 'Shapelog',
  292: 'Dabuziduo',
  293: 'Jetblack',
  294: 'Coros',
  295: 'Virtugo',
  296: 'Velosense',
  297: 'Cycligentinc',
  298: 'Trailforks',
  299: 'Mahle Ebikemotion',
  300: 'Nurvv',
  301: 'Microprogram',
  302: 'Zone5cloud',
  303: 'Greenteg',
  304: 'Yamaha Motors',
  5759: 'Actigraphcorp',
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

  /// Primary temperature channel (air temperature in Celsius).
  static const Channel temperature = Channel._('temperature');

  /// Water temperature channel (Celsius).
  static const Channel waterTemperature = Channel._('water_temperature');

  /// Depth channel (meters).
  static const Channel depth = Channel._('depth');

  /// Derived speed channel (m/s).
  static const Channel speed = Channel._('speed');

  /// Course/heading channel (degrees true, 0-360).
  static const Channel course = Channel._('course');

  /// Bearing channel (degrees true, 0-360).
  static const Channel bearing = Channel._('bearing');

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
///
/// For multi-sport activities (e.g., triathlons), each lap can have its own
/// sport. If not specified, the lap inherits the activity's overall sport.
class Lap {
  Lap({
    required DateTime startTime,
    required DateTime endTime,
    this.distanceMeters,
    this.name,
    this.sport,
    this.calories,
    this.avgSpeed,
    this.maxSpeed,
    this.avgHeartRate,
    this.maxHeartRate,
    this.avgCadence,
    this.maxCadence,
    this.avgPower,
    this.maxPower,
    this.event,
    this.eventType,
  }) : startTime = startTime.toUtc(),
       endTime = endTime.toUtc();

  /// Start timestamp (UTC).
  final DateTime startTime;

  /// End timestamp (UTC).
  final DateTime endTime;

  /// Total distance covered in this lap (meters).
  final double? distanceMeters;

  /// Optional lap name or label.
  final String? name;

  /// Sport for this specific lap (null inherits from activity-level sport).
  ///
  /// Used for multi-sport activities like triathlons where each segment
  /// (swim, bike, run) has a different sport type.
  final Sport? sport;

  /// Total calories burned during this lap (kcal).
  final double? calories;

  /// Average speed for the lap (m/s).
  final double? avgSpeed;

  /// Maximum speed for the lap (m/s).
  final double? maxSpeed;

  /// Average heart rate for the lap (bpm).
  final double? avgHeartRate;

  /// Maximum heart rate for the lap (bpm).
  final double? maxHeartRate;

  /// Average cadence for the lap (rpm).
  final double? avgCadence;

  /// Maximum cadence for the lap (rpm).
  final double? maxCadence;

  /// Average power for the lap (watts).
  final double? avgPower;

  /// Maximum power for the lap (watts).
  final double? maxPower;

  /// FIT event identifier for the lap (raw FIT field 0).
  final int? event;

  /// FIT event type for the lap (raw FIT field 1).
  final int? eventType;

  /// Duration of this lap.
  Duration get elapsed => endTime.difference(startTime);

  Lap copyWith({
    DateTime? startTime,
    DateTime? endTime,
    double? distanceMeters,
    String? name,
    Sport? sport,
    double? calories,
    double? avgSpeed,
    double? maxSpeed,
    double? avgHeartRate,
    double? maxHeartRate,
    double? avgCadence,
    double? maxCadence,
    double? avgPower,
    double? maxPower,
    int? event,
    int? eventType,
  }) => Lap(
    startTime: (startTime ?? this.startTime).toUtc(),
    endTime: (endTime ?? this.endTime).toUtc(),
    distanceMeters: distanceMeters ?? this.distanceMeters,
    name: name ?? this.name,
    sport: sport ?? this.sport,
    calories: calories ?? this.calories,
    avgSpeed: avgSpeed ?? this.avgSpeed,
    maxSpeed: maxSpeed ?? this.maxSpeed,
    avgHeartRate: avgHeartRate ?? this.avgHeartRate,
    maxHeartRate: maxHeartRate ?? this.maxHeartRate,
    avgCadence: avgCadence ?? this.avgCadence,
    maxCadence: maxCadence ?? this.maxCadence,
    avgPower: avgPower ?? this.avgPower,
    maxPower: maxPower ?? this.maxPower,
    event: event ?? this.event,
    eventType: eventType ?? this.eventType,
  );
}

/// Summary information for an activity/session.
class ActivitySummary {
  const ActivitySummary({
    this.elapsedTime,
    this.timerTime,
    this.totalDistanceMeters,
    this.avgSpeed,
    this.maxSpeed,
    this.avgHeartRate,
    this.maxHeartRate,
    this.avgCadence,
    this.maxCadence,
    this.avgPower,
    this.maxPower,
    this.calories,
  });

  /// Total elapsed time for the activity.
  final Duration? elapsedTime;

  /// Total timer time for the activity.
  final Duration? timerTime;

  /// Total distance covered in meters.
  final double? totalDistanceMeters;

  /// Average speed across the activity (m/s).
  final double? avgSpeed;

  /// Maximum speed across the activity (m/s).
  final double? maxSpeed;

  /// Average heart rate across the activity (bpm).
  final double? avgHeartRate;

  /// Maximum heart rate across the activity (bpm).
  final double? maxHeartRate;

  /// Average cadence across the activity (rpm).
  final double? avgCadence;

  /// Maximum cadence across the activity (rpm).
  final double? maxCadence;

  /// Average power across the activity (watts).
  final double? avgPower;

  /// Maximum power across the activity (watts).
  final double? maxPower;

  /// Total calories burned (kcal).
  final double? calories;

  ActivitySummary copyWith({
    Duration? elapsedTime,
    Duration? timerTime,
    double? totalDistanceMeters,
    double? avgSpeed,
    double? maxSpeed,
    double? avgHeartRate,
    double? maxHeartRate,
    double? avgCadence,
    double? maxCadence,
    double? avgPower,
    double? maxPower,
    double? calories,
  }) => ActivitySummary(
    elapsedTime: elapsedTime ?? this.elapsedTime,
    timerTime: timerTime ?? this.timerTime,
    totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
    avgSpeed: avgSpeed ?? this.avgSpeed,
    maxSpeed: maxSpeed ?? this.maxSpeed,
    avgHeartRate: avgHeartRate ?? this.avgHeartRate,
    maxHeartRate: maxHeartRate ?? this.maxHeartRate,
    avgCadence: avgCadence ?? this.avgCadence,
    maxCadence: maxCadence ?? this.maxCadence,
    avgPower: avgPower ?? this.avgPower,
    maxPower: maxPower ?? this.maxPower,
    calories: calories ?? this.calories,
  );
}

/// Metadata describing the recording device or software.
/// TODO(0.6.0): Validate device metadata and handle edge cases in channel mappings.
class ActivityDeviceMetadata {
  /// Creates metadata describing the originating device or software.
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

  /// Returns a copy with selective field overrides.
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
  factory RawActivity({
    Iterable<GeoPoint>? points,
    Map<Channel, Iterable<Sample>>? channels,
    Iterable<Lap>? laps,
    Sport sport = Sport.unknown,
    String? creator,
    ActivityDeviceMetadata? device,
    ActivitySummary? summary,
    String? gpxMetadataName,
    String? gpxMetadataDescription,
    bool gpxIncludeCreatorMetadataDescription = true,
    String? gpxTrackName,
    String? gpxTrackDescription,
    String? gpxTrackType,
    Iterable<GpxExtensionNode>? gpxMetadataExtensions,
    Iterable<GpxExtensionNode>? gpxTrackExtensions,
  }) => RawActivity._canonical(
    points: points,
    channels: channels,
    laps: laps,
    sport: sport,
    creator: creator,
    device: device,
    summary: summary,
    gpxMetadataName: gpxMetadataName,
    gpxMetadataDescription: gpxMetadataDescription,
    gpxIncludeCreatorMetadataDescription: gpxIncludeCreatorMetadataDescription,
    gpxTrackName: gpxTrackName,
    gpxTrackDescription: gpxTrackDescription,
    gpxTrackType: gpxTrackType,
    gpxMetadataExtensions: gpxMetadataExtensions,
    gpxTrackExtensions: gpxTrackExtensions,
    assumeCanonical: false,
  );

  RawActivity._canonical({
    Iterable<GeoPoint>? points,
    Map<Channel, Iterable<Sample>>? channels,
    Iterable<Lap>? laps,
    required this.sport,
    required this.creator,
    required this.device,
    required this.summary,
    required this.gpxMetadataName,
    required this.gpxMetadataDescription,
    required this.gpxIncludeCreatorMetadataDescription,
    required this.gpxTrackName,
    required this.gpxTrackDescription,
    required this.gpxTrackType,
    Iterable<GpxExtensionNode>? gpxMetadataExtensions,
    Iterable<GpxExtensionNode>? gpxTrackExtensions,
    required bool assumeCanonical,
  }) : assert(!assumeCanonical || points == null || points is List<GeoPoint>),
       assert(
         !assumeCanonical ||
             channels == null ||
             channels is Map<Channel, List<Sample>>,
       ),
       assert(!assumeCanonical || laps == null || laps is List<Lap>),
       assert(
         !assumeCanonical ||
             gpxMetadataExtensions == null ||
             gpxMetadataExtensions is List<GpxExtensionNode>,
       ),
       assert(
         !assumeCanonical ||
             gpxTrackExtensions == null ||
             gpxTrackExtensions is List<GpxExtensionNode>,
       ),
       points = assumeCanonical
           ? (points as List<GeoPoint>? ?? const <GeoPoint>[])
           : List<GeoPoint>.unmodifiable(points ?? const <GeoPoint>[]),
       channels = assumeCanonical
           ? (channels as Map<Channel, List<Sample>>? ??
                 const <Channel, List<Sample>>{})
           : Map.unmodifiable({
               for (final entry
                   in (channels ?? const <Channel, Iterable<Sample>>{}).entries)
                 entry.key: List<Sample>.unmodifiable(entry.value),
             }),
       laps = assumeCanonical
           ? (laps as List<Lap>? ?? const <Lap>[])
           : List<Lap>.unmodifiable(laps ?? const <Lap>[]),
       gpxMetadataExtensions = assumeCanonical
           ? (gpxMetadataExtensions as List<GpxExtensionNode>? ??
                 const <GpxExtensionNode>[])
           : List<GpxExtensionNode>.unmodifiable(
               gpxMetadataExtensions ?? const <GpxExtensionNode>[],
             ),
       gpxTrackExtensions = assumeCanonical
           ? (gpxTrackExtensions as List<GpxExtensionNode>? ??
                 const <GpxExtensionNode>[])
           : List<GpxExtensionNode>.unmodifiable(
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

  /// Summary stats captured from source metadata when available.
  final ActivitySummary? summary;

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

  double? _approximateDistanceCache;

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
    ActivitySummary? summary,
    String? gpxMetadataName,
    String? gpxMetadataDescription,
    bool? gpxIncludeCreatorMetadataDescription,
    String? gpxTrackName,
    String? gpxTrackDescription,
    String? gpxTrackType,
    Iterable<GpxExtensionNode>? gpxMetadataExtensions,
    Iterable<GpxExtensionNode>? gpxTrackExtensions,
  }) {
    final resolvedPoints = points ?? this.points;
    final resolvedChannels = channels ?? this.channels;
    final resolvedLaps = laps ?? this.laps;
    final resolvedMetadataExtensions =
        gpxMetadataExtensions ?? this.gpxMetadataExtensions;
    final resolvedTrackExtensions =
        gpxTrackExtensions ?? this.gpxTrackExtensions;
    final canAssumeCanonical =
        identical(resolvedPoints, this.points) &&
        identical(resolvedChannels, this.channels) &&
        identical(resolvedLaps, this.laps) &&
        identical(resolvedMetadataExtensions, this.gpxMetadataExtensions) &&
        identical(resolvedTrackExtensions, this.gpxTrackExtensions);
    final copy = RawActivity._canonical(
      points: resolvedPoints,
      channels: resolvedChannels,
      laps: resolvedLaps,
      sport: sport ?? this.sport,
      creator: creator ?? this.creator,
      device: device ?? this.device,
      summary: summary ?? this.summary,
      gpxMetadataName: gpxMetadataName ?? this.gpxMetadataName,
      gpxMetadataDescription:
          gpxMetadataDescription ?? this.gpxMetadataDescription,
      gpxIncludeCreatorMetadataDescription:
          gpxIncludeCreatorMetadataDescription ??
          this.gpxIncludeCreatorMetadataDescription,
      gpxTrackName: gpxTrackName ?? this.gpxTrackName,
      gpxTrackDescription: gpxTrackDescription ?? this.gpxTrackDescription,
      gpxTrackType: gpxTrackType ?? this.gpxTrackType,
      gpxMetadataExtensions: resolvedMetadataExtensions,
      gpxTrackExtensions: resolvedTrackExtensions,
      assumeCanonical: canAssumeCanonical,
    );
    if (canAssumeCanonical &&
        identical(resolvedPoints, this.points) &&
        identical(resolvedChannels, this.channels) &&
        identical(resolvedLaps, this.laps)) {
      copy._approximateDistanceCache = _approximateDistanceCache;
    }
    return copy;
  }

  /// Returns the timestamp of the first point, if any.
  DateTime? get startTime => points.isEmpty ? null : points.first.time;

  /// Returns the timestamp of the last point, if any.
  DateTime? get endTime => points.isEmpty ? null : points.last.time;

  /// Approximates the total distance in meters based on stored channels or
  /// planar projection of geographic points.
  double get approximateDistance =>
      _approximateDistanceCache ??= _computeApproximateDistance();

  double _computeApproximateDistance() {
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
