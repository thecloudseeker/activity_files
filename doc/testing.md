# Testing Guide

## Running Tests

```bash
# All tests
dart test

# Specific categories
dart test test/unit/        # Fast unit tests
dart test test/integration/ # Integration tests
dart test test/parsers/      # Parser tests
dart test test/encoders/     # Encoder tests
dart test test/formats/      # Format compatibility
dart test test/platform/     # Platform-specific

# With coverage
dart test --coverage=coverage
dart pub global run coverage:format_coverage \
  --lcov --in=coverage --out=coverage/lcov.info \
  --packages=.dart_tool/package_config.json \
  --report-on=lib
```

## Directory Structure

```
test/
├── unit/              # Fast, isolated unit tests
├── integration/       # Cross-component tests
├── parsers/           # Format parser tests
├── encoders/          # Format encoder tests
├── formats/           # Version compatibility
├── platform/          # Platform-specific (isolates, file system)
├── fixtures/          # Shared test data
│   ├── sample_data.dart      # GPX/TCX/FIT samples
│   ├── builders.dart         # ActivityBuilder API
│   └── real_world/           # Real activity files
└── helpers/           # Test utilities
    ├── fit_helpers.dart      # FIT binary utilities
    ├── stream_helpers.dart   # Stream helpers
    └── matchers.dart         # Custom matchers
```

## Writing Tests

### Where to Add Tests

- **Unit tests** (`test/unit/`) - Single component, no external dependencies
- **Integration tests** (`test/integration/`) - Multiple components working together
- **Parser tests** (`test/parsers/`) - Format-specific parsing
- **Encoder tests** (`test/encoders/`) - Format-specific encoding
- **Format tests** (`test/formats/`) - Version compatibility
- **Platform tests** (`test/platform/`) - Isolates, file system

### Template

```dart
// SPDX-License-Identifier: BSD-3-Clause
/// Brief description of what this tests.
library;

import 'package:activity_files/activity_files.dart';
import 'package:test/test.dart';

import '../fixtures/sample_data.dart';
import '../fixtures/builders.dart';

void main() {
  group('Feature', () {
    test('specific behavior', () {
      final activity = buildRunningActivity();
      expect(activity.points.length, 3);
    });
  });
}
```

## Shared Utilities

### Fixtures

```dart
// Shared samples
import '../fixtures/sample_data.dart';

final result = ActivityParser.parse(sampleGpx, ActivityFileFormat.gpx);
// Also: sampleTcx, gpx10Sample, tcxV1Sample

// Activity builder
import '../fixtures/builders.dart';

final activity = ActivityBuilder()
  .withPoints(5)
  .withHeartRate([140, 145, 150, 155, 160])
  .withSport(Sport.running)
  .build();

// Pre-built activities
final running = buildRunningActivity();
final cycling = buildCyclingActivity();

// Artificial fixtures (generated)
// Run: dart run scripts/generate_artificial_fixtures.dart
// Outputs:
// - example/assets/sample.{gpx,tcx,fit}
// - test/fixtures/real_world/sample.{gpx,tcx,fit}
```

### Helpers

```dart
// FIT utilities
import '../helpers/fit_helpers.dart';

final crc = fitCrc(bytes);
final header = buildFitHeader(dataSize);

// Stream utilities
import '../helpers/stream_helpers.dart';

final stream = CountingStream([[1, 2], [3, 4]]);
expect(stream.listenCount, equals(1));

// Custom matchers
import '../helpers/matchers.dart';

expect(
  hasMatchingSample(samples, target, Duration(seconds: 2)),
  isTrue,
);
```

## Best Practices

1. Use shared fixtures - Don't duplicate test data
2. Keep tests focused - One assertion per test
3. Use descriptive names - Test names should explain what they verify
4. Arrange-Act-Assert - Clear test structure
5. Import only what you need - Avoid unused imports
