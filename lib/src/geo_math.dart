// SPDX-License-Identifier: BSD-3-Clause
import 'dart:math' as math;

import 'models.dart';

/// Great-circle distance in meters between [a] and [b] using the haversine
/// formula on a spherical Earth (radius 6371 km).
double haversineMeters(GeoPoint a, GeoPoint b) {
  const earthRadius = 6371000.0; // meters
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

double _radians(double deg) => deg * math.pi / 180.0;
