// SPDX-License-Identifier: BSD-3-Clause
import 'geo_math.dart';

/// Supported file formats for activities.
enum ActivityFileFormat { gpx, tcx, fit, csv, geojson }

/// Supported sports.
enum Sport { unknown, running, cycling, swimming, hiking, walking, other }

/// Swim stroke type as recorded in FIT swim sessions.
///
/// Declaration order mirrors the FIT swim_stroke wire values (0–6);
/// the FIT parser decodes by index, so do not reorder.
enum SwimStroke {
  freestyle,
  backstroke,
  breaststroke,
  butterfly,
  drill,
  mixed,
  im,
}

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
    Iterable<GpxExtensionNode>? gpxExtensions,
    Map<String, String>? gpxAttributes,
  }) : time = time.toUtc(),
       gpxExtensions = gpxExtensions == null
           ? null
           : List.unmodifiable(gpxExtensions),
       gpxAttributes = gpxAttributes == null || gpxAttributes.isEmpty
           ? null
           : Map.unmodifiable(gpxAttributes);
  final double latitude;
  final double longitude;
  final double? elevation;
  final DateTime time;

  /// Unrecognized GPX point-level extension elements, preserved for lossless
  /// round-trips (everything inside `<trkpt><extensions>` that is not a
  /// Garmin TrackPointExtension). Null for points from other formats.
  final List<GpxExtensionNode>? gpxExtensions;

  /// Standard GPX point child elements without a dedicated field, keyed by
  /// local element name (e.g. `hdop`, `vdop`, `pdop`, `sat`, `fix`,
  /// `geoidheight`, `ageofdgpsdata`, `magvar`, `dgpsid`, `name`, `sym`).
  ///
  /// Raw string values, preserved so GPS-quality and waypoint metadata survive
  /// a GPX round-trip. Null for points from other formats.
  final Map<String, String>? gpxAttributes;

  GeoPoint copyWith({
    double? latitude,
    double? longitude,
    double? elevation,
    DateTime? time,
    Iterable<GpxExtensionNode>? gpxExtensions,
    Map<String, String>? gpxAttributes,
  }) => GeoPoint(
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    elevation: elevation ?? this.elevation,
    time: (time ?? this.time).toUtc(),
    gpxExtensions: gpxExtensions ?? this.gpxExtensions,
    gpxAttributes: gpxAttributes ?? this.gpxAttributes,
  );
}

/// A GPX route (`<rte>`): an ordered list of route points (`<rtept>`) with an
/// optional name and other metadata, preserved for lossless GPX round-trips.
class GpxRoute {
  GpxRoute({
    this.name,
    Iterable<GeoPoint>? points,
    Map<String, String>? metadata,
  }) : points = List.unmodifiable(points ?? const <GeoPoint>[]),
       metadata = metadata == null || metadata.isEmpty
           ? const {}
           : Map.unmodifiable(metadata);

  /// Route name (`<rte><name>`).
  final String? name;

  /// Ordered route points.
  final List<GeoPoint> points;

  /// Other `<rte>`-level child elements (e.g. `desc`, `type`, `number`), keyed
  /// by local element name.
  final Map<String, String> metadata;

  GpxRoute copyWith({
    String? name,
    Iterable<GeoPoint>? points,
    Map<String, String>? metadata,
  }) => GpxRoute(
    name: name ?? this.name,
    points: points ?? this.points,
    metadata: metadata ?? this.metadata,
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

/// A single strength-training set recorded by a fitness device.
class WorkoutSet {
  WorkoutSet({
    required DateTime startTime,
    required DateTime endTime,
    required this.isRest,
    this.exerciseCategoryId,
    this.exerciseCategory,
    this.repetitions,
    this.weightKg,
  }) : startTime = startTime.toUtc(),
       endTime = endTime.toUtc();

  /// When this set started (UTC).
  final DateTime startTime;

  /// When this set ended (UTC).
  final DateTime endTime;

  /// True for rest periods between active sets.
  final bool isRest;

  /// Raw FIT `exercise_category` value.
  ///
  /// Preserved so sets can be round-tripped back to FIT without relying on
  /// the human-readable [exerciseCategory] label.
  final int? exerciseCategoryId;

  /// Human-readable exercise category (e.g. "Squat", "Bench Press").
  final String? exerciseCategory;

  /// Number of repetitions performed.
  final int? repetitions;

  /// Weight used in kilograms.
  final double? weightKg;

  Duration get elapsed => endTime.difference(startTime);

  /// Returns a copy with selective field overrides.
  WorkoutSet copyWith({
    DateTime? startTime,
    DateTime? endTime,
    bool? isRest,
    int? exerciseCategoryId,
    String? exerciseCategory,
    int? repetitions,
    double? weightKg,
  }) => WorkoutSet(
    startTime: (startTime ?? this.startTime).toUtc(),
    endTime: (endTime ?? this.endTime).toUtc(),
    isRest: isRest ?? this.isRest,
    exerciseCategoryId: exerciseCategoryId ?? this.exerciseCategoryId,
    exerciseCategory: exerciseCategory ?? this.exerciseCategory,
    repetitions: repetitions ?? this.repetitions,
    weightKg: weightKg ?? this.weightKg,
  );

  /// FIT exercise_category labels, indexed by the raw FIT value (0–32).
  static const List<String> _categoryLabels = [
    'Bench Press', 'Calf Raise', 'Cardio', 'Carry', 'Chop', 'Core', //
    'Crunch', 'Curl', 'Deadlift', 'Fly', 'Hip Raise', 'Hip Stability',
    'Hip Swing', 'Hyperextension', 'Lateral Raise', 'Leg Curl', 'Leg Raise',
    'Lunge', 'Olympic Lift', 'Plank', 'Plyometric', 'Pull-up', 'Push-up',
    'Row', 'Shoulder Press', 'Shoulder Stability', 'Shrug', 'Sit-up',
    'Squat', 'Total Body', 'Triceps Extension', 'Warm-up', 'Run',
  ];

  /// Maps a FIT exercise_category integer to a human-readable label.
  static String? categoryLabel(int? value) =>
      value != null && value >= 0 && value < _categoryLabels.length
      ? _categoryLabels[value]
      : null;
}

/// A timer or marker event recorded by a fitness device (FIT event messages).
///
/// Timer events carry the pause information of an activity: a stop event
/// followed by a start event delimits a pause.
class ActivityEvent {
  ActivityEvent({
    required DateTime time,
    required this.event,
    required this.eventType,
    this.data,
  }) : time = time.toUtc();

  /// When the event occurred (UTC).
  final DateTime time;

  /// Raw FIT `event` value (0 = timer).
  final int event;

  /// Raw FIT `event_type` value (0 = start, 1 = stop, 4 = stop_all).
  final int eventType;

  /// Raw FIT `data` value, if present.
  final int? data;

  /// True for timer events (pause/resume boundaries).
  bool get isTimerEvent => event == 0;

  /// True when this event starts (or resumes) the timer.
  bool get isStart => eventType == 0;

  /// True when this event stops (pauses) the timer.
  bool get isStop => eventType == 1 || eventType == 4;

  ActivityEvent copyWith({
    DateTime? time,
    int? event,
    int? eventType,
    int? data,
  }) => ActivityEvent(
    time: (time ?? this.time).toUtc(),
    event: event ?? this.event,
    eventType: eventType ?? this.eventType,
    data: data ?? this.data,
  );
}

/// A single pool length from a FIT swim activity (length messages).
class SwimLength {
  SwimLength({
    required DateTime startTime,
    required DateTime endTime,
    required this.isActive,
    this.totalStrokes,
    this.avgSpeed,
    this.swimStroke,
  }) : startTime = startTime.toUtc(),
       endTime = endTime.toUtc();

  /// When this length started (UTC).
  final DateTime startTime;

  /// When this length ended (UTC).
  final DateTime endTime;

  /// True for active lengths; false for idle time at the pool wall.
  final bool isActive;

  /// Strokes taken in this length.
  final int? totalStrokes;

  /// Average speed for this length (m/s).
  final double? avgSpeed;

  /// Stroke swum in this length.
  final SwimStroke? swimStroke;

  Duration get elapsed => endTime.difference(startTime);

  SwimLength copyWith({
    DateTime? startTime,
    DateTime? endTime,
    bool? isActive,
    int? totalStrokes,
    double? avgSpeed,
    SwimStroke? swimStroke,
  }) => SwimLength(
    startTime: (startTime ?? this.startTime).toUtc(),
    endTime: (endTime ?? this.endTime).toUtc(),
    isActive: isActive ?? this.isActive,
    totalStrokes: totalStrokes ?? this.totalStrokes,
    avgSpeed: avgSpeed ?? this.avgSpeed,
    swimStroke: swimStroke ?? this.swimStroke,
  );
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
    this.numActiveLengths,
    this.swimStroke,
    this.tcxIntensity,
    this.tcxTriggerMethod,
    Map<int, double>? extraFitFields,
    Map<int, List<double>>? extraFitArrays,
  }) : startTime = startTime.toUtc(),
       endTime = endTime.toUtc(),
       extraFitFields = Map.unmodifiable(
         extraFitFields ?? const <int, double>{},
       ),
       extraFitArrays = Map.unmodifiable(
         extraFitArrays ?? const <int, List<double>>{},
       );

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

  /// Active lengths completed in this lap (swim only).
  final int? numActiveLengths;

  /// Swim stroke for this lap (swim only).
  final SwimStroke? swimStroke;

  /// Raw FIT lap fields with no dedicated property, keyed by FIT field number
  /// (e.g. total_ascent, normalized_power). Values are the raw on-wire numbers;
  /// field-specific scale/units are not applied. Preserved so a FIT lap
  /// round-trips without silently dropping unmodeled metrics.
  final Map<int, double> extraFitFields;

  /// Raw FIT lap *array* fields with no dedicated property, keyed by FIT field
  /// number (e.g. time_in_hr_zone). Raw per-element values; kept separate from
  /// [extraFitFields] because a scalar cannot represent a multi-element array.
  final Map<int, List<double>> extraFitArrays;

  /// TCX lap `<Intensity>` (`Active` or `Resting`); null for non-TCX laps.
  final String? tcxIntensity;

  /// TCX lap `<TriggerMethod>` (`Manual`, `Distance`, `Location`, `Time`,
  /// `HeartRate`); null for non-TCX laps.
  final String? tcxTriggerMethod;

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
    int? numActiveLengths,
    SwimStroke? swimStroke,
    String? tcxIntensity,
    String? tcxTriggerMethod,
    Map<int, double>? extraFitFields,
    Map<int, List<double>>? extraFitArrays,
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
    numActiveLengths: numActiveLengths ?? this.numActiveLengths,
    swimStroke: swimStroke ?? this.swimStroke,
    tcxIntensity: tcxIntensity ?? this.tcxIntensity,
    tcxTriggerMethod: tcxTriggerMethod ?? this.tcxTriggerMethod,
    extraFitFields: extraFitFields ?? this.extraFitFields,
    extraFitArrays: extraFitArrays ?? this.extraFitArrays,
  );

  /// Returns a copy of this lap with [sport] cleared while preserving all
  /// other metadata.
  ///
  /// [copyWith] cannot null out a field, so use this when the per-lap sport
  /// should fall back to the activity-level sport again (e.g. after splitting
  /// a multi-sport activity into single-sport activities).
  Lap copyWithoutSport() => Lap(
    startTime: startTime,
    endTime: endTime,
    distanceMeters: distanceMeters,
    name: name,
    calories: calories,
    avgSpeed: avgSpeed,
    maxSpeed: maxSpeed,
    avgHeartRate: avgHeartRate,
    maxHeartRate: maxHeartRate,
    avgCadence: avgCadence,
    maxCadence: maxCadence,
    avgPower: avgPower,
    maxPower: maxPower,
    event: event,
    eventType: eventType,
    numActiveLengths: numActiveLengths,
    swimStroke: swimStroke,
    tcxIntensity: tcxIntensity,
    tcxTriggerMethod: tcxTriggerMethod,
    extraFitFields: extraFitFields,
    extraFitArrays: extraFitArrays,
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
    this.poolLengthMeters,
    this.numActiveLengths,
    this.swimStroke,
    this.avgStrokeCount,
    this.subSport,
    this.totalCycles,
    this.sport,
    this.extraFitFields = const {},
    this.extraFitArrays = const {},
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

  /// Pool length in meters (swim only).
  final double? poolLengthMeters;

  /// Total active lengths completed (swim only).
  final int? numActiveLengths;

  /// Dominant swim stroke for the session (swim only).
  final SwimStroke? swimStroke;

  /// Average strokes per pool length for the session (swim only).
  final double? avgStrokeCount;

  /// FIT sub-sport identifier (e.g. 35 = alpine skiing, 36 = XC skiing).
  final int? subSport;

  /// Total movement cycles for the session.
  ///
  /// Meaning is sport-specific: jump-rope jumps, running strides, cycling
  /// pedal revolutions, swimming strokes, etc.
  final int? totalCycles;

  /// Sport of this session.
  ///
  /// Set for sessions parsed from multi-session FIT files (e.g. triathlon
  /// legs) so each session keeps its own sport; null when the session simply
  /// inherits the activity-level sport.
  final Sport? sport;

  /// Raw FIT session fields with no dedicated property, keyed by FIT field
  /// number (e.g. total_ascent, normalized_power, training_stress_score).
  ///
  /// Values are the raw on-wire numbers; field-specific scale/units are not
  /// applied. Preserved so a FIT session round-trips without silently dropping
  /// metrics the model does not model explicitly.
  final Map<int, double> extraFitFields;

  /// Raw FIT session *array* fields with no dedicated property, keyed by FIT
  /// field number (e.g. time_in_hr_zone, time_in_power_zone).
  ///
  /// Values are the raw on-wire numbers per element; scale/units are not
  /// applied. Kept separate from [extraFitFields] because a single scalar
  /// cannot represent a multi-element array.
  final Map<int, List<double>> extraFitArrays;

  /// Whether no summary field carries data (all scalars null, no extras).
  bool get isEmpty =>
      elapsedTime == null &&
      timerTime == null &&
      totalDistanceMeters == null &&
      avgSpeed == null &&
      maxSpeed == null &&
      avgHeartRate == null &&
      maxHeartRate == null &&
      avgCadence == null &&
      maxCadence == null &&
      avgPower == null &&
      maxPower == null &&
      calories == null &&
      poolLengthMeters == null &&
      numActiveLengths == null &&
      swimStroke == null &&
      avgStrokeCount == null &&
      subSport == null &&
      totalCycles == null &&
      sport == null &&
      extraFitFields.isEmpty &&
      extraFitArrays.isEmpty;

  /// Whether any summary field carries data.
  bool get isNotEmpty => !isEmpty;

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
    double? poolLengthMeters,
    int? numActiveLengths,
    SwimStroke? swimStroke,
    double? avgStrokeCount,
    int? subSport,
    int? totalCycles,
    Sport? sport,
    Map<int, double>? extraFitFields,
    Map<int, List<double>>? extraFitArrays,
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
    poolLengthMeters: poolLengthMeters ?? this.poolLengthMeters,
    numActiveLengths: numActiveLengths ?? this.numActiveLengths,
    swimStroke: swimStroke ?? this.swimStroke,
    avgStrokeCount: avgStrokeCount ?? this.avgStrokeCount,
    subSport: subSport ?? this.subSport,
    totalCycles: totalCycles ?? this.totalCycles,
    sport: sport ?? this.sport,
    extraFitFields: extraFitFields ?? this.extraFitFields,
    extraFitArrays: extraFitArrays ?? this.extraFitArrays,
  );
}

/// Metadata describing the recording device or software.
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
    Iterable<WorkoutSet>? sets,
    Iterable<ActivityEvent>? events,
    Iterable<SwimLength>? lengths,
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
    Iterable<RawActivity>? additionalTracks,
    Iterable<ActivitySummary>? additionalSessions,
    Iterable<GeoPoint>? gpxWaypoints,
    Iterable<GpxRoute>? gpxRoutes,
    Iterable<int>? gpxTrackSegments,
    String? tcxNotes,
    String? tcxAuthor,
    Map<String, Object?>? metadata,
  }) => RawActivity._canonical(
    points: points,
    channels: channels,
    laps: laps,
    sets: sets,
    events: events,
    lengths: lengths,
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
    additionalTracks: additionalTracks,
    additionalSessions: additionalSessions,
    gpxWaypoints: gpxWaypoints,
    gpxRoutes: gpxRoutes,
    gpxTrackSegments: gpxTrackSegments,
    tcxNotes: tcxNotes,
    tcxAuthor: tcxAuthor,
    metadata: metadata,
    assumeCanonical: false,
  );

  RawActivity._canonical({
    Iterable<GeoPoint>? points,
    Map<Channel, Iterable<Sample>>? channels,
    Iterable<Lap>? laps,
    Iterable<WorkoutSet>? sets,
    Iterable<ActivityEvent>? events,
    Iterable<SwimLength>? lengths,
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
    Iterable<RawActivity>? additionalTracks,
    Iterable<ActivitySummary>? additionalSessions,
    Iterable<GeoPoint>? gpxWaypoints,
    Iterable<GpxRoute>? gpxRoutes,
    Iterable<int>? gpxTrackSegments,
    this.tcxNotes,
    this.tcxAuthor,
    Map<String, Object?>? metadata,
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
       sets = List<WorkoutSet>.unmodifiable(sets ?? const <WorkoutSet>[]),
       events = List<ActivityEvent>.unmodifiable(
         events ?? const <ActivityEvent>[],
       ),
       lengths = List<SwimLength>.unmodifiable(lengths ?? const <SwimLength>[]),
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
             ),
       additionalTracks = List<RawActivity>.unmodifiable(
         additionalTracks ?? const <RawActivity>[],
       ),
       additionalSessions = List<ActivitySummary>.unmodifiable(
         additionalSessions ?? const <ActivitySummary>[],
       ),
       gpxWaypoints = List<GeoPoint>.unmodifiable(
         gpxWaypoints ?? const <GeoPoint>[],
       ),
       gpxRoutes = List<GpxRoute>.unmodifiable(gpxRoutes ?? const <GpxRoute>[]),
       gpxTrackSegments = List<int>.unmodifiable(
         gpxTrackSegments ?? const <int>[],
       ),
       metadata = metadata == null || metadata.isEmpty
           ? const {}
           : Map.unmodifiable(metadata);

  /// Sequence of geographic points.
  final List<GeoPoint> points;

  /// Time-aligned sensor channels.
  final Map<Channel, List<Sample>> channels;

  /// Declared laps or segments.
  final List<Lap> laps;

  /// Strength-training sets recorded by a fitness device (FIT set messages).
  final List<WorkoutSet> sets;

  /// Timer and marker events (FIT event messages); timer stop/start pairs
  /// delimit pauses.
  final List<ActivityEvent> events;

  /// Per-length pool-swim data (FIT length messages).
  final List<SwimLength> lengths;

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

  /// Additional GPX tracks from a multi-track file.
  ///
  /// When a GPX file contains more than one `<trk>` element the primary track
  /// is represented by this [RawActivity] and every subsequent track is stored
  /// here, preserving the file structure for lossless round-trips.
  ///
  /// Empty for activities parsed from single-track files, TCX, FIT, or any
  /// other format that does not carry multi-track structure.
  final List<RawActivity> additionalTracks;

  /// Additional sessions from a multi-session file.
  ///
  /// When a FIT file contains more than one session message (e.g. the legs of
  /// a triathlon), the first session becomes [summary] and every subsequent
  /// session is stored here — each with its own [ActivitySummary.sport] — so
  /// per-leg statistics survive round-trips.
  ///
  /// Empty for single-session files and formats without session structure.
  final List<ActivitySummary> additionalSessions;

  /// GPX standalone waypoints (`<wpt>`): named points of interest carried at
  /// the file root, not part of the track. Each is a [GeoPoint] whose name,
  /// symbol, and other metadata live in [GeoPoint.gpxAttributes]. Empty for
  /// non-GPX sources or GPX files without waypoints.
  final List<GeoPoint> gpxWaypoints;

  /// GPX routes (`<rte>`): planned/ordered route-point sequences, distinct from
  /// the recorded track. Empty for non-GPX sources or GPX files without routes.
  final List<GpxRoute> gpxRoutes;

  /// Start indices into [points] where each GPX track segment (`<trkseg>`)
  /// begins, so multi-segment tracks re-emit their segment boundaries.
  ///
  /// Empty or single-entry `[0]` means one segment. Cleared by [flattened]
  /// (indices no longer align after tracks are merged).
  final List<int> gpxTrackSegments;

  /// TCX activity `<Notes>` free text; null for other sources.
  final String? tcxNotes;

  /// TCX file `<Author>` name (the creating software/person); null otherwise.
  final String? tcxAuthor;

  /// Arbitrary activity-level metadata preserved from the source, keyed by
  /// property name with raw scalar values (String/num/bool), e.g. GeoJSON
  /// feature properties such as `notes`, `weather_summary`, `start_time`,
  /// `total_distance`. Original JSON types are kept so they round-trip exactly.
  ///
  /// Empty for sources without free-form activity metadata.
  final Map<String, Object?> metadata;

  double? _approximateDistanceCache;

  /// Returns the samples for a given [channel], if present.
  List<Sample> channel(Channel channel) =>
      channels[channel] ?? const <Sample>[];

  /// Creates a copy with overrides.
  RawActivity copyWith({
    Iterable<GeoPoint>? points,
    Map<Channel, Iterable<Sample>>? channels,
    Iterable<Lap>? laps,
    Iterable<WorkoutSet>? sets,
    Iterable<ActivityEvent>? events,
    Iterable<SwimLength>? lengths,
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
    Iterable<RawActivity>? additionalTracks,
    Iterable<ActivitySummary>? additionalSessions,
    Iterable<GeoPoint>? gpxWaypoints,
    Iterable<GpxRoute>? gpxRoutes,
    Iterable<int>? gpxTrackSegments,
    String? tcxNotes,
    String? tcxAuthor,
    Map<String, Object?>? metadata,
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
      sets: sets ?? this.sets,
      events: events ?? this.events,
      lengths: lengths ?? this.lengths,
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
      additionalTracks: additionalTracks ?? this.additionalTracks,
      additionalSessions: additionalSessions ?? this.additionalSessions,
      gpxWaypoints: gpxWaypoints ?? this.gpxWaypoints,
      gpxRoutes: gpxRoutes ?? this.gpxRoutes,
      gpxTrackSegments: gpxTrackSegments ?? this.gpxTrackSegments,
      tcxNotes: tcxNotes ?? this.tcxNotes,
      tcxAuthor: tcxAuthor ?? this.tcxAuthor,
      metadata: metadata ?? this.metadata,
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

  /// Returns this activity with all [additionalTracks] merged into a single
  /// flat track.
  ///
  /// Points, channel samples, laps, and sets from every track are combined
  /// and sorted chronologically; the result has an empty [additionalTracks]
  /// list. Encoders for formats that cannot represent multiple tracks
  /// (TCX, FIT, CSV, GeoJSON) call this before encoding so that no track
  /// data is silently dropped.
  ///
  /// Returns `this` unchanged when there are no additional tracks.
  RawActivity flattened() {
    if (additionalTracks.isEmpty) {
      return this;
    }
    final mergedPoints = <GeoPoint>[...points];
    final mergedChannels = <Channel, List<Sample>>{
      for (final entry in channels.entries) entry.key: [...entry.value],
    };
    final mergedLaps = <Lap>[...laps];
    final mergedSets = <WorkoutSet>[...sets];
    final mergedEvents = <ActivityEvent>[...events];
    final mergedLengths = <SwimLength>[...lengths];
    for (final track in additionalTracks) {
      final flat = track.flattened();
      mergedPoints.addAll(flat.points);
      for (final entry in flat.channels.entries) {
        mergedChannels
            .putIfAbsent(entry.key, () => <Sample>[])
            .addAll(entry.value);
      }
      mergedLaps.addAll(flat.laps);
      mergedSets.addAll(flat.sets);
      mergedEvents.addAll(flat.events);
      mergedLengths.addAll(flat.lengths);
    }
    mergedPoints.sort((a, b) => a.time.compareTo(b.time));
    for (final samples in mergedChannels.values) {
      samples.sort((a, b) => a.time.compareTo(b.time));
    }
    mergedLaps.sort((a, b) => a.startTime.compareTo(b.startTime));
    mergedSets.sort((a, b) => a.startTime.compareTo(b.startTime));
    mergedEvents.sort((a, b) => a.time.compareTo(b.time));
    mergedLengths.sort((a, b) => a.startTime.compareTo(b.startTime));
    return copyWith(
      points: mergedPoints,
      channels: mergedChannels,
      laps: mergedLaps,
      sets: mergedSets,
      events: mergedEvents,
      lengths: mergedLengths,
      additionalTracks: const [],
      // Segment boundaries index the primary track's points; after merging and
      // re-sorting they no longer align, so drop them.
      gpxTrackSegments: const [],
    );
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
      total += haversineMeters(points[i - 1], points[i]);
    }
    return total;
  }
}
