// SKELETON — Scenario #2: Opening files inside each category.
//
// **Why this isn't covered yet (integration-only):**
// File opening uses `open_filex` which calls the platform-default
// viewer (gallery / video player / pdf reader / etc.). Unit tests
// can't observe what the OS opens.
//
// **What CAN be unit-tested (TODO):**
// - The MIME-type → viewer-route mapping: text/plain → text_viewer,
//   video/mp4 → video_viewer, application/pdf → pdf_viewer, etc.
// - Widget: tapping a file tile invokes the correct route.
//
// **What needs integration testing (TODO):**
// - Each viewer screen renders without error for a sample file.
// - External viewer dispatch happens for unsupported formats.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Scenario #2 — Open file (SKELETON)', () {
    test('TODO: MIME router selects correct in-app viewer', () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: unsupported MIME falls back to open_filex', () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: integration — image viewer screen renders sample image',
        () => null,
        skip: 'requires integration_test/ harness');
  });
}
