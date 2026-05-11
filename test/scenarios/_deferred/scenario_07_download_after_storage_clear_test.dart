// SKELETON — Scenario #7: Download after app storage cleared.
//
// **Why this isn't covered (integration-only):**
// "Storage cleared" means BOTH:
//   - the BLOCKS / KEY_TO_CID redb cache wiped, AND
//   - in-memory Riverpod / forest_cache state lost.
// Recreating that state from inside a `flutter test` process means
// constructing a fresh app instance, which is what an integration
// test does anyway. Unit tests of "what happens when the cache is
// empty" already exist in `crates/fula-client/tests/offline_e2e.rs`
// at the SDK tier — duplicating them here adds no value.
//
// **What this test SHOULD eventually do (integration_test/):**
// 1. Sign in, upload a file, observe successful upload.
// 2. `pm clear land.fx.files.dev` (Android) or `Clear Data` button.
// 3. Re-launch app, sign in.
// 4. Download the previously-uploaded file. Must succeed (master-up
//    fresh-fetch populates BLOCKS, then bytes returned).
// 5. Now mutate endpoint to bogus URL → restart client.
// 6. Try download again. Bytes must still come from BLOCKS, but if
//    the bucket-listing manifest was rotated by another device since
//    step 4, the cold-start resolver (Phase 3.3) has to be working.
//
// Implementation effort: ~300 LOC of integration_test scaffolding.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Scenario #7 — Download after storage clear (SKELETON)', () {
    test('TODO: integration — full clear-then-download flow', () => null,
        skip: 'requires integration_test/ harness + real device');
  });
}
