// SKELETON — Nice-to-have #13: Share folder in "snapshot" mode →
// receiver does NOT see post-share additions.
//
// **What "snapshot mode" means:**
// The token references a SPECIFIC manifest CID at share-creation
// time. Subsequent owner-side writes don't update that CID; the
// receiver keeps seeing the original snapshot until the owner
// rotates the share.
//
// **Companion to scenario #12** — together they prove the mode
// distinction works end to end.
//
// **TODO:** see scenario_11 for the prereq + integration-harness
// requirement.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Nice-to-have #13 — Folder share, snapshot mode (SKELETON)', () {
    test('TODO: createShareToken emits ShareMode.snapshot', () => null,
        skip: 'TODO: see file header for implementation plan');
    test('TODO: integration — receiver does NOT see post-share additions',
        () => null,
        skip: 'requires two-device or fake-receiver integration harness');
  });
}
