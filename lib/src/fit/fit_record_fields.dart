// SPDX-License-Identifier: BSD-3-Clause
import '../models.dart';

/// FIT profile field numbers for the record (global 20) message's optional
/// fields this library knows about. Single source of truth for parser and
/// encoder so a field number or scale can't diverge between them, the exact
/// way the field 78/120 mapping bug happened in this release.
const int fitFieldHeartRate = 3;
const int fitFieldCadence = 4;
const int fitFieldDistance = 5;
const int fitFieldSpeed = 6;
const int fitFieldPower = 7;
const int fitFieldGrade = 9;
const int fitFieldTemperature = 13;
const int fitFieldLeftRightBalance = 30;
const int fitFieldEbikeAssistLevelPercent = 120;

/// Decode/encode scale for [fitFieldDistance] (raw = meters * 100).
const double fitFieldDistanceScale = 100;

/// Decode/encode scale for [fitFieldSpeed] (raw = m/s * 1000).
const double fitFieldSpeedScale = 1000;

/// Decode/encode scale for [fitFieldGrade] (raw = percent * 100).
const double fitFieldGradeScale = 100;

/// A [channel] carried natively by record field [number], decoded/encoded
/// with `raw = value * scale`.
class FitRecordField {
  const FitRecordField({
    required this.channel,
    required this.number,
    required this.scale,
  });

  final Channel channel;
  final int number;
  final double scale;
}

/// Known optional record fields this library reads/writes as a named or
/// custom [Channel]. `grade`, `left_right_balance`, and
/// `ebike_assist_level_percent` mirror the names the parser assigns those
/// fields so they round-trip natively instead of via `fit_field_<n>`.
final List<FitRecordField> knownFitRecordFields = [
  const FitRecordField(
    channel: Channel.heartRate,
    number: fitFieldHeartRate,
    scale: 1,
  ),
  const FitRecordField(
    channel: Channel.cadence,
    number: fitFieldCadence,
    scale: 1,
  ),
  const FitRecordField(
    channel: Channel.distance,
    number: fitFieldDistance,
    scale: fitFieldDistanceScale,
  ),
  const FitRecordField(
    channel: Channel.speed,
    number: fitFieldSpeed,
    scale: fitFieldSpeedScale,
  ),
  const FitRecordField(channel: Channel.power, number: fitFieldPower, scale: 1),
  const FitRecordField(
    channel: Channel.temperature,
    number: fitFieldTemperature,
    scale: 1,
  ),
  FitRecordField(
    channel: Channel.custom('grade'),
    number: fitFieldGrade,
    scale: fitFieldGradeScale,
  ),
  FitRecordField(
    channel: Channel.custom('left_right_balance'),
    number: fitFieldLeftRightBalance,
    scale: 1,
  ),
  FitRecordField(
    channel: Channel.custom('ebike_assist_level_percent'),
    number: fitFieldEbikeAssistLevelPercent,
    scale: 1,
  ),
];
