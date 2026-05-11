// SKELETON — Scenario #8: Tags + face metadata restored after
// clearing storage.
//
// **What CAN be unit-tested (TODO):**
// - `TagStorageService.restoreFromCloud()` correctly merges the
//   downloaded JSON blob into local Hive (mock Hive via
//   `Hive.initFlutter(testTempDir)` + open in-memory boxes).
// - `FaceDetectionService` doesn't double-detect a face whose
//   embedding is already in storage.
// - Conflict resolution: local-newer wins / cloud-newer wins.
//
// **What needs integration testing (TODO):**
// - Real Hive on a connected device, real cloud round-trip.
// - Background ML Kit face detection completes and stores results.
//
// **Test helpers we'd need to add for this scenario:**
//   - `test/helpers/hive_test.dart`: setUp/tearDown that creates an
//     ephemeral Hive root + closes all boxes between tests. (Not
//     yet built; the current 4 scenarios don't need it.)
//   - `FakeTagStorageService` mirroring the `FakeFulaApi` pattern.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Scenario #8 — Tags + faces restore (SKELETON)', () {
    test('TODO: TagStorageService.restoreFromCloud merges into local Hive',
        () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: FaceDetectionService skips already-known faces', () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: integration — clear + restore round-trip', () => null,
        skip: 'requires integration_test/ harness + real device');
  });
}
