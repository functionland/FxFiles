// SKELETON — Scenario #1: Loading categories pre-login on device.
//
// **Why this isn't covered yet (integration-only):**
// Category discovery hits MediaStore (Android) or PhotoKit (iOS) via
// platform channels. Pre-login state is the natural device state
// (no auth required for local file enumeration). Unit/widget tests
// can't reach the platform channel in a meaningful way.
//
// **What CAN be unit-tested (TODO):**
// - The `FileCategory` enum's grouping logic: given a list of
//   `LocalFile` objects with paths, the categorizer assigns each to
//   Images / Videos / Documents / Audio / Apps / Other correctly.
// - Widget: a categories grid rendered with stub `LocalFile` lists
//   shows the right tile counts and thumbnails.
//
// **What needs integration testing (TODO):**
// - Real device file scan returns the expected categories.
// - Permission flow on first launch.
// - SAF / MANAGE_EXTERNAL_STORAGE on Android 11+.
//
// To implement:
//   1. Read `lib/core/services/media_service.dart` and
//      `lib/core/services/file_service.dart` for the discovery seams.
//   2. Inject a `FakeMediaService` via a new Riverpod provider
//      (mirroring the FulaApi pattern). See test/README.md.
//   3. Add categorizer unit tests here.
//   4. Move integration aspects to `integration_test/scenarios/`.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Scenario #1 — Categories pre-login (SKELETON)', () {
    test('TODO: categorizer assigns paths to FileCategory correctly',
        () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: widget grid renders one tile per non-empty category',
        () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: integration — real device scan finds expected categories',
        () => null,
        skip: 'requires integration_test/ harness with a connected device');
  });
}
