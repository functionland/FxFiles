// SKELETON — Nice-to-have #12: Share a folder in "latest" mode →
// receiver sees newly-added files in the same link.
//
// **What "latest mode" means (per sharing.rs in fula-client):**
// The token references the folder's CURRENT bucket manifest pointer.
// On accept, the receiver dereferences that pointer freshly each
// time → newer manifests reach the receiver as the owner writes.
//
// **TODO:** see scenario_11 for the prereq (extend FulaApi surface
// with createShareToken). Then:
// - Unit: token mode encoding is "latest" not "snapshot".
// - Integration: owner uploads folder → receiver lists → owner adds
//   file → receiver re-lists → sees the new file.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Nice-to-have #12 — Folder share, latest mode (SKELETON)', () {
    test('TODO: createShareToken emits ShareMode.latest', () => null,
        skip: 'TODO: see file header for implementation plan');
    test('TODO: integration — receiver sees post-share additions', () => null,
        skip: 'requires two-device or fake-receiver integration harness');
  });
}
