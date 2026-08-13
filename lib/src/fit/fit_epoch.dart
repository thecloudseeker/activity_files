// SPDX-License-Identifier: BSD-3-Clause

/// FIT epoch (00:00 UTC, Dec 31 1989): the origin every FIT `uint32`
/// timestamp field counts seconds from. Single source of truth for parser
/// and encoder so the constant cannot diverge.
final DateTime fitEpoch = DateTime.utc(1989, 12, 31);

/// Seconds from [fitEpoch] to [time], clamped to 0 for anything earlier.
/// FIT timestamp fields are unsigned; encoding a negative delta directly
/// would silently wrap around to a nonsensical date decades in the future.
int fitSecondsSinceEpoch(DateTime time) {
  final seconds = time.toUtc().difference(fitEpoch).inSeconds;
  return seconds < 0 ? 0 : seconds;
}
