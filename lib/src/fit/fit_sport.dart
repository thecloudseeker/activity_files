// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';

/// Official FIT sport enum values (Garmin FIT profile) mapped to [Sport].
///
/// Single source of truth for parser and encoder so the two cannot diverge.
/// FIT value 0 is "generic", which maps to [Sport.unknown] on decode and is
/// the fallback on encode for sports FIT cannot represent.
const Map<int, Sport> sportByFitId = {
  0: Sport.unknown, // generic
  1: Sport.running,
  2: Sport.cycling,
  5: Sport.swimming,
  11: Sport.walking,
  17: Sport.hiking,
};

/// Reverse lookup of [sportByFitId]; unmapped sports encode as 0 (generic).
final Map<Sport, int> fitIdBySport = {
  for (final entry in sportByFitId.entries) entry.value: entry.key,
};

/// Decodes a FIT sport value; unmapped values become [Sport.other].
Sport sportFromFitId(int value) => sportByFitId[value] ?? Sport.other;

/// Encodes a [Sport] as FIT sport value; unmapped sports become 0 (generic).
int fitIdFromSport(Sport sport) => fitIdBySport[sport] ?? 0;
