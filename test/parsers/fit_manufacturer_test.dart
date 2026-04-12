// SPDX-License-Identifier: BSD-3-Clause
/// Tests for FIT manufacturer database.
///
/// Tests the fitManufacturerNames map which provides human-readable names
/// for FIT manufacturer IDs.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

void main() {
  group('Expanded FIT Manufacturer Database', () {
    test('includes major manufacturers', () {
      expect(fitManufacturerNames[1], 'Garmin');
      expect(fitManufacturerNames[32], 'Wahoo Fitness');
      expect(fitManufacturerNames[260], 'Zwift');
      expect(fitManufacturerNames[123], 'Polar Electro');
      expect(fitManufacturerNames[268], 'SRAM');
      expect(fitManufacturerNames[289], 'Hammerhead');
      expect(fitManufacturerNames[281], 'TrainerRoad');
    });

    test('includes 179 manufacturers', () {
      expect(fitManufacturerNames.length, 179);
    });

    test('includes specialized manufacturers', () {
      expect(fitManufacturerNames[63], 'Specialized');
      expect(fitManufacturerNames[69], 'Stages Cycling');
      expect(fitManufacturerNames[89], 'Tacx');
      expect(fitManufacturerNames[100], 'Campagnolo SRL');
    });

    test('includes development manufacturer', () {
      expect(fitManufacturerNames[255], 'Development');
    });
  });
}
