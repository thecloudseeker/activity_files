// SPDX-License-Identifier: BSD-3-Clause
import '../encode/encoder_options.dart';
import '../models.dart';
import '../parse/parse_result.dart';
import '../validation.dart';
import 'export_stats.dart';

/// Internal helpers for isolate-safe serialization of export payloads.
class ExportSerialization {
  const ExportSerialization._();

  static Map<String, Object?> activityToJson(RawActivity activity) => {
    'points': [
      for (final point in activity.points)
        {
          'lat': point.latitude,
          'lon': point.longitude,
          'ele': point.elevation,
          'time': point.time.toUtc().toIso8601String(),
        },
    ],
    'channels': {
      for (final entry in activity.channels.entries)
        entry.key.id: [
          for (final sample in entry.value)
            {
              'time': sample.time.toUtc().toIso8601String(),
              'value': sample.value,
            },
        ],
    },
    'laps': [
      for (final lap in activity.laps)
        {
          'start': lap.startTime.toUtc().toIso8601String(),
          'end': lap.endTime.toUtc().toIso8601String(),
          'distance': lap.distanceMeters,
          'name': lap.name,
        },
    ],
    'sport': activity.sport.index,
    'creator': activity.creator,
    'device': deviceToJson(activity.device),
    'gpxMetadataName': activity.gpxMetadataName,
    'gpxMetadataDescription': activity.gpxMetadataDescription,
    'gpxIncludeCreatorMetadataDescription':
        activity.gpxIncludeCreatorMetadataDescription,
    'gpxTrackName': activity.gpxTrackName,
    'gpxTrackDescription': activity.gpxTrackDescription,
    'gpxTrackType': activity.gpxTrackType,
    'metadataExtensions': [
      for (final node in activity.gpxMetadataExtensions)
        extensionNodeToJson(node),
    ],
    'trackExtensions': [
      for (final node in activity.gpxTrackExtensions) extensionNodeToJson(node),
    ],
  };

  static RawActivity activityFromJson(Map<String, Object?> data) {
    final points = (data['points'] as List<dynamic>)
        .map((entry) {
          final map = (entry as Map).cast<String, Object?>();
          return GeoPoint(
            latitude: (map['lat'] as num).toDouble(),
            longitude: (map['lon'] as num).toDouble(),
            elevation: map['ele'] is num
                ? (map['ele'] as num).toDouble()
                : null,
            time: DateTime.parse(map['time'] as String),
          );
        })
        .toList(growable: false);
    final channelsRaw = (data['channels'] as Map).cast<String, Object?>();
    final channels = <Channel, List<Sample>>{};
    channelsRaw.forEach((id, value) {
      final samples = (value as List<dynamic>)
          .map((sample) {
            final map = (sample as Map).cast<String, Object?>();
            return Sample(
              time: DateTime.parse(map['time'] as String),
              value: (map['value'] as num).toDouble(),
            );
          })
          .toList(growable: false);
      channels[_channelFromId(id)] = samples;
    });
    final laps = (data['laps'] as List<dynamic>)
        .map((entry) {
          final map = (entry as Map).cast<String, Object?>();
          return Lap(
            startTime: DateTime.parse(map['start'] as String),
            endTime: DateTime.parse(map['end'] as String),
            distanceMeters: map['distance'] is num
                ? (map['distance'] as num).toDouble()
                : null,
            name: map['name'] as String?,
          );
        })
        .toList(growable: false);
    final metadataExtensions = (data['metadataExtensions'] as List<dynamic>)
        .map(
          (entry) =>
              extensionNodeFromJson((entry as Map).cast<String, Object?>()),
        )
        .toList(growable: false);
    final trackExtensions = (data['trackExtensions'] as List<dynamic>)
        .map(
          (entry) =>
              extensionNodeFromJson((entry as Map).cast<String, Object?>()),
        )
        .toList(growable: false);
    return RawActivity(
      points: points,
      channels: channels,
      laps: laps,
      sport: Sport.values[data['sport'] as int],
      creator: data['creator'] as String?,
      device: deviceFromJson((data['device'] as Map?)?.cast<String, Object?>()),
      gpxMetadataName: data['gpxMetadataName'] as String?,
      gpxMetadataDescription: data['gpxMetadataDescription'] as String?,
      gpxIncludeCreatorMetadataDescription:
          (data['gpxIncludeCreatorMetadataDescription'] as bool?) ?? true,
      gpxTrackName: data['gpxTrackName'] as String?,
      gpxTrackDescription: data['gpxTrackDescription'] as String?,
      gpxTrackType: data['gpxTrackType'] as String?,
      gpxMetadataExtensions: metadataExtensions,
      gpxTrackExtensions: trackExtensions,
    );
  }

  static Map<String, Object?>? deviceToJson(ActivityDeviceMetadata? device) {
    if (device == null) {
      return null;
    }
    return {
      'manufacturer': device.manufacturer,
      'model': device.model,
      'product': device.product,
      'serialNumber': device.serialNumber,
      'softwareVersion': device.softwareVersion,
      'fitManufacturerId': device.fitManufacturerId,
      'fitProductId': device.fitProductId,
    };
  }

  static ActivityDeviceMetadata? deviceFromJson(Map<String, Object?>? data) {
    if (data == null) {
      return null;
    }
    return ActivityDeviceMetadata(
      manufacturer: data['manufacturer'] as String?,
      model: data['model'] as String?,
      product: data['product'] as String?,
      serialNumber: data['serialNumber'] as String?,
      softwareVersion: data['softwareVersion'] as String?,
      fitManufacturerId: data['fitManufacturerId'] as int?,
      fitProductId: data['fitProductId'] as int?,
    );
  }

  static Map<String, Object?> extensionNodeToJson(GpxExtensionNode node) => {
    'name': node.name,
    'prefix': node.namespacePrefix,
    'uri': node.namespaceUri,
    'value': node.value,
    'attributes': node.attributes,
    'children': [for (final child in node.children) extensionNodeToJson(child)],
  };

  static GpxExtensionNode extensionNodeFromJson(Map<String, Object?> data) =>
      GpxExtensionNode(
        name: data['name'] as String,
        namespacePrefix: data['prefix'] as String?,
        namespaceUri: data['uri'] as String?,
        value: data['value'] as String?,
        attributes:
            (data['attributes'] as Map?)?.cast<String, String>() ??
            const <String, String>{},
        children: (data['children'] as List<dynamic>)
            .map(
              (child) =>
                  extensionNodeFromJson((child as Map).cast<String, Object?>()),
            )
            .toList(growable: false),
      );

  static Map<String, Object?> encoderOptionsToJson(EncoderOptions options) => {
    'defaultMaxDeltaMicros': options.defaultMaxDelta.inMicroseconds,
    'precisionLatLon': options.precisionLatLon,
    'precisionEle': options.precisionEle,
    'maxDeltaPerChannel': {
      for (final entry in options.maxDeltaPerChannel.entries)
        entry.key.id: entry.value.inMicroseconds,
    },
    'gpxVersion': options.gpxVersion.name,
    'tcxVersion': options.tcxVersion.name,
  };

  static EncoderOptions encoderOptionsFromJson(Map<String, Object?> data) {
    final perChannel =
        (data['maxDeltaPerChannel'] as Map?)?.cast<String, int>() ??
        const <String, int>{};
    String? gpxVersionRaw;
    String? tcxVersionRaw;
    final gpxVersionValue = data['gpxVersion'];
    if (gpxVersionValue is String) {
      gpxVersionRaw = gpxVersionValue;
    }
    final tcxVersionValue = data['tcxVersion'];
    if (tcxVersionValue is String) {
      tcxVersionRaw = tcxVersionValue;
    }
    return EncoderOptions(
      defaultMaxDelta: Duration(
        microseconds: data['defaultMaxDeltaMicros'] as int,
      ),
      precisionLatLon: data['precisionLatLon'] as int,
      precisionEle: data['precisionEle'] as int,
      maxDeltaPerChannel: {
        for (final entry in perChannel.entries)
          _channelFromId(entry.key): Duration(microseconds: entry.value),
      },
      gpxVersion: _gpxVersionFromString(gpxVersionRaw),
      tcxVersion: _tcxVersionFromString(tcxVersionRaw),
    );
  }

  static Map<String, Object?> diagnosticToJson(ParseDiagnostic diagnostic) => {
    'severity': diagnostic.severity.index,
    'code': diagnostic.code,
    'message': diagnostic.message,
    'node': diagnostic.node == null
        ? null
        : {
            'path': diagnostic.node!.path,
            'index': diagnostic.node!.index,
            'description': diagnostic.node!.description,
          },
  };

  static ParseDiagnostic diagnosticFromJson(Map<String, Object?> data) {
    final nodeData = data['node'] is Map
        ? (data['node'] as Map).cast<String, Object?>()
        : null;
    return ParseDiagnostic(
      severity: ParseSeverity.values[data['severity'] as int],
      code: data['code'] as String,
      message: data['message'] as String,
      node: nodeData == null
          ? null
          : ParseNodeReference(
              path: nodeData['path'] as String,
              index: nodeData['index'] as int?,
              description: nodeData['description'] as String?,
            ),
    );
  }

  static Map<String, Object?> validationToJson(ValidationResult validation) => {
    'errors': validation.errors,
    'warnings': validation.warnings,
  };

  static ValidationResult validationFromJson(Map<String, Object?> data) =>
      ValidationResult(
        errors: (data['errors'] as List<dynamic>).cast<String>(),
        warnings: (data['warnings'] as List<dynamic>).cast<String>(),
      );

  static Map<String, Object?> normalizationStatsToJson(
    NormalizationStats stats,
  ) => {
    'applied': stats.applied,
    'pointsBefore': stats.pointsBefore,
    'pointsAfter': stats.pointsAfter,
    'samplesBefore': stats.totalSamplesBefore,
    'samplesAfter': stats.totalSamplesAfter,
    'durationMicros': stats.duration.inMicroseconds,
  };

  static NormalizationStats normalizationStatsFromJson(
    Map<String, Object?> data,
  ) => NormalizationStats(
    applied: data['applied'] as bool,
    pointsBefore: data['pointsBefore'] as int,
    pointsAfter: data['pointsAfter'] as int,
    totalSamplesBefore: data['samplesBefore'] as int,
    totalSamplesAfter: data['samplesAfter'] as int,
    duration: Duration(microseconds: data['durationMicros'] as int),
  );

  static Map<String, Object?> processingStatsToJson(
    ActivityProcessingStats stats,
  ) => {
    'normalization': stats.normalization == null
        ? null
        : normalizationStatsToJson(stats.normalization!),
    'validationDurationMicros': stats.validationDuration?.inMicroseconds,
  };

  static ActivityProcessingStats processingStatsFromJson(
    Map<String, Object?>? data,
  ) {
    if (data == null) {
      return const ActivityProcessingStats();
    }
    return ActivityProcessingStats(
      normalization: data['normalization'] is Map
          ? normalizationStatsFromJson(
              (data['normalization'] as Map).cast<String, Object?>(),
            )
          : null,
      validationDuration: data['validationDurationMicros'] is int
          ? Duration(microseconds: data['validationDurationMicros'] as int)
          : null,
    );
  }

  static Channel _channelFromId(String id) {
    switch (id) {
      case 'heart_rate':
        return Channel.heartRate;
      case 'cadence':
        return Channel.cadence;
      case 'power':
        return Channel.power;
      case 'temperature':
        return Channel.temperature;
      case 'speed':
        return Channel.speed;
      case 'distance':
        return Channel.distance;
      default:
        return Channel.custom(id);
    }
  }

  static GpxVersion _gpxVersionFromString(String? value) {
    switch (value) {
      case 'v1_0':
        return GpxVersion.v1_0;
      case 'v1_1':
      default:
        return GpxVersion.v1_1;
    }
  }

  static TcxVersion _tcxVersionFromString(String? value) {
    switch (value) {
      case 'v1':
        return TcxVersion.v1;
      case 'v2':
      default:
        return TcxVersion.v2;
    }
  }
}
