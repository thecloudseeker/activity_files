// SPDX-License-Identifier: BSD-3-Clause
part of '../activity_files_facade.dart';

/// Fluent builder for assembling [RawActivity] instances.
class RawActivityBuilder {
  RawActivityBuilder({RawActivity? seed})
    : sport = seed?.sport ?? Sport.unknown,
      creator = seed?.creator,
      device = seed?.device,
      gpxMetadataName = seed?.gpxMetadataName,
      gpxMetadataDescription = seed?.gpxMetadataDescription,
      gpxIncludeCreatorMetadataDescription =
          seed?.gpxIncludeCreatorMetadataDescription ?? true,
      gpxTrackName = seed?.gpxTrackName,
      gpxTrackDescription = seed?.gpxTrackDescription,
      gpxTrackType = seed?.gpxTrackType {
    if (seed != null) {
      addPoints(seed.points);
      seed.channels.forEach(addChannel);
      addLaps(seed.laps);
      _metadataExtensions.addAll(seed.gpxMetadataExtensions);
      _trackExtensions.addAll(seed.gpxTrackExtensions);
    }
  }

  /// Dominant sport classification.
  Sport sport;

  /// Originating device or software label.
  String? creator;

  /// Metadata describing the recording device.
  ActivityDeviceMetadata? device;

  /// Optional metadata title used for GPX exports.
  String? gpxMetadataName;

  /// Optional metadata description used for GPX exports.
  String? gpxMetadataDescription;

  /// Whether GPX encoders should fall back to [creator] when description null.
  bool gpxIncludeCreatorMetadataDescription;

  /// Optional GPX track name override.
  String? gpxTrackName;

  /// Optional GPX track description.
  String? gpxTrackDescription;

  /// Optional GPX track type override.
  String? gpxTrackType;

  final List<GeoPoint> _points = <GeoPoint>[];
  final Map<Channel, List<Sample>> _channels = <Channel, List<Sample>>{};
  final List<Lap> _laps = <Lap>[];
  final List<GpxExtensionNode> _metadataExtensions = <GpxExtensionNode>[];
  final List<GpxExtensionNode> _trackExtensions = <GpxExtensionNode>[];

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

  /// Replaces the device metadata payload.
  RawActivityBuilder setDeviceMetadata(ActivityDeviceMetadata? metadata) {
    device = metadata;
    return this;
  }

  /// Configures GPX metadata name/description behaviour.
  RawActivityBuilder configureGpxMetadata({
    String? name,
    String? description,
    bool? includeCreatorDescription,
  }) {
    gpxMetadataName = name ?? gpxMetadataName;
    gpxMetadataDescription = description ?? gpxMetadataDescription;
    if (includeCreatorDescription != null) {
      gpxIncludeCreatorMetadataDescription = includeCreatorDescription;
    }
    return this;
  }

  /// Configures GPX track presentation values.
  RawActivityBuilder configureGpxTrack({
    String? name,
    String? description,
    String? type,
  }) {
    gpxTrackName = name ?? gpxTrackName;
    gpxTrackDescription = description ?? gpxTrackDescription;
    gpxTrackType = type ?? gpxTrackType;
    return this;
  }

  /// Adds GPX metadata-level extensions.
  RawActivityBuilder addGpxMetadataExtensions(
    Iterable<GpxExtensionNode> extensions,
  ) {
    _metadataExtensions.addAll(extensions);
    return this;
  }

  /// Adds a single GPX metadata-level extension.
  RawActivityBuilder addGpxMetadataExtension(GpxExtensionNode extension) {
    _metadataExtensions.add(extension);
    return this;
  }

  /// Adds GPX track-level extensions.
  RawActivityBuilder addGpxTrackExtensions(
    Iterable<GpxExtensionNode> extensions,
  ) {
    _trackExtensions.addAll(extensions);
    return this;
  }

  /// Adds a single GPX track-level extension.
  RawActivityBuilder addGpxTrackExtension(GpxExtensionNode extension) {
    _trackExtensions.add(extension);
    return this;
  }

  /// Removes any previously added GPX extensions.
  RawActivityBuilder clearGpxExtensions() {
    _metadataExtensions.clear();
    _trackExtensions.clear();
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
      device: device,
      gpxMetadataName: gpxMetadataName,
      gpxMetadataDescription: gpxMetadataDescription,
      gpxIncludeCreatorMetadataDescription:
          gpxIncludeCreatorMetadataDescription,
      gpxTrackName: gpxTrackName,
      gpxTrackDescription: gpxTrackDescription,
      gpxTrackType: gpxTrackType,
      gpxMetadataExtensions: _metadataExtensions.toList(),
      gpxTrackExtensions: _trackExtensions.toList(),
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
    device = null;
    gpxMetadataName = null;
    gpxMetadataDescription = null;
    gpxIncludeCreatorMetadataDescription = true;
    gpxTrackName = null;
    gpxTrackDescription = null;
    gpxTrackType = null;
    _metadataExtensions.clear();
    _trackExtensions.clear();
  }

  /// Creates a GPX extension node representing an activity label.
  static GpxExtensionNode activityLabelNode(
    String label, {
    String prefix = ActivityFiles.gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, String> attributes = const <String, String>{},
  }) => GpxExtensionNode(
    name: 'activity',
    namespacePrefix: prefix,
    namespaceUri: namespaceUri ?? ActivityFiles.gpxDefaultExtensionNamespace,
    value: label,
    attributes: attributes,
  );

  /// Creates a GPX extension node describing a device payload.
  static GpxExtensionNode deviceNode(
    ActivityDeviceMetadata metadata, {
    String prefix = ActivityFiles.gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, String> attributes = const <String, String>{},
    Map<String, Object?> extras = const <String, Object?>{},
  }) {
    final uri = namespaceUri ?? ActivityFiles.gpxDefaultExtensionNamespace;
    return GpxExtensionNode(
      name: 'device',
      namespacePrefix: prefix,
      namespaceUri: uri,
      attributes: attributes,
      children: _deviceMetadataChildren(
        metadata,
        prefix: prefix,
        namespaceUri: uri,
        extras: extras,
      ),
    );
  }

  /// Creates a GPX extension node summarizing device metadata plus [extras].
  static GpxExtensionNode deviceSummaryNode(
    ActivityDeviceMetadata metadata, {
    String prefix = ActivityFiles.gpxDefaultExtensionPrefix,
    String? namespaceUri,
    Map<String, Object?> extras = const <String, Object?>{},
  }) {
    final uri = namespaceUri ?? ActivityFiles.gpxDefaultExtensionNamespace;
    return GpxExtensionNode(
      name: 'deviceSummary',
      namespacePrefix: prefix,
      namespaceUri: uri,
      children: _deviceMetadataChildren(
        metadata,
        prefix: prefix,
        namespaceUri: uri,
        extras: extras,
      ),
    );
  }

  static List<GpxExtensionNode> _deviceMetadataChildren(
    ActivityDeviceMetadata metadata, {
    required String? prefix,
    required String namespaceUri,
    Map<String, Object?> extras = const <String, Object?>{},
  }) {
    final children = <GpxExtensionNode>[];
    void addChild(String name, Object? value) {
      if (value == null) {
        return;
      }
      final text = value is DateTime
          ? value.toUtc().toIso8601String()
          : value.toString();
      if (text.trim().isEmpty) {
        return;
      }
      children.add(
        GpxExtensionNode(
          name: name,
          namespacePrefix: prefix,
          namespaceUri: namespaceUri,
          value: text,
        ),
      );
    }

    addChild('manufacturer', metadata.manufacturer);
    addChild('model', metadata.model);
    addChild('product', metadata.product);
    addChild('serialNumber', metadata.serialNumber);
    addChild('softwareVersion', metadata.softwareVersion);
    addChild('fitManufacturerId', metadata.fitManufacturerId);
    addChild('fitProductId', metadata.fitProductId);
    extras.forEach(addChild);
    return children;
  }
}
