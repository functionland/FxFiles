// SKELETON — Scenario #5: Deleting an uploaded file so it no longer
// exists on device.
//
// **Why this isn't covered yet (integration-mostly):**
// `dart:io File.delete()` works in widget tests with a temp dir,
// but the FxFiles delete flow includes:
// - SAF / MANAGE_EXTERNAL_STORAGE permission check on Android.
// - MediaStore content-resolver delete on Android 11+ scoped storage.
// - PhotoKit asset deletion on iOS (requires user consent dialog).
// None of these are widget-test reachable.
//
// **What CAN be unit-tested (TODO):**
// - The "should I prompt for confirm before delete" decision logic.
// - The "remove from in-memory file list after successful delete"
//   state update.
//
// **What needs integration testing (TODO):**
// - Real File.delete() on a temp file in app sandbox.
// - SAF prompt-and-confirm flow.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Scenario #5 — Delete local file (SKELETON)', () {
    test('TODO: delete-confirm prompt logic for unsynced files', () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: in-memory list pruned after successful delete', () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: integration — real File.delete in temp dir', () => null,
        skip: 'requires integration_test/ harness');
  });
}
