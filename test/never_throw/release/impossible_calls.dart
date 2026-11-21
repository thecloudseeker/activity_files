// SPDX-License-Identifier: BSD-3-Clause
// Run without assertions, as a release build runs: makes every call with
// impossible arguments and prints, per call, whether it threw and which
// diagnostic codes it left. Read by impossible_arguments_test.dart.
import 'dart:convert';

import 'package:activity_files/activity_files.dart';

Future<void> main() async {
  final t0 = DateTime.utc(2024, 1, 1, 10);
  final activity = RawActivity(
    points: [
      for (var i = 0; i < 3; i++)
        GeoPoint(
          latitude: 46 + i / 1e3,
          longitude: 13,
          time: t0.add(Duration(seconds: i * 10)),
        ),
    ],
  );
  final results = <String, Object?>{};
  Future<void> call(String name, Future<Object?> Function() body) async {
    try {
      results[name] = await body();
    } catch (error) {
      results[name] = 'threw ${error.runtimeType}';
    }
  }

  Object editor(RawEditor e) => {
    'points': e.activity.points.length,
    'codes': [for (final d in e.repairDiagnostics) d.code],
  };
  final before = t0.subtract(const Duration(hours: 1));
  await call(
    'crop',
    () async => editor(ActivityFiles.edit(activity).crop(t0, before)),
  );
  await call(
    'deleteRange',
    () async => editor(ActivityFiles.edit(activity).deleteRange(t0, before)),
  );
  await call(
    'insertPause',
    () async => editor(
      ActivityFiles.edit(activity).insertPause(t0, const Duration(seconds: -1)),
    ),
  );
  await call(
    'removePause',
    () async => editor(ActivityFiles.edit(activity).removePause(t0, before)),
  );
  await call(
    'downsampleTime',
    () async =>
        editor(ActivityFiles.edit(activity).downsampleTime(Duration.zero)),
  );
  await call(
    'downsampleDistance',
    () async => editor(ActivityFiles.edit(activity).downsampleDistance(-1)),
  );
  await call(
    'markLapsByDistance',
    () async =>
        editor(ActivityFiles.edit(activity).markLapsByDistance(double.nan)),
  );
  await call(
    'merge',
    () async => {
      'points': RawEditor.merge(const []).points.length,
      'codes': <String>[],
    },
  );
  // ignore: deprecated_member_use_from_same_package
  await call(
    'resample',
    () async => {
      'points': RawTransforms.resample(
        activity,
        step: Duration.zero,
      ).points.length,
      'codes': <String>[],
    },
  );
  await call('convertAndExport', () async {
    // ignore: deprecated_member_use_from_same_package
    final result = await ActivityFiles.convertAndExport(
      to: ActivityFileFormat.gpx,
    );
    return {
      'points': result.activity.points.length,
      'codes': [for (final d in result.diagnostics) d.code],
    };
  });
  print(jsonEncode(results));
}
