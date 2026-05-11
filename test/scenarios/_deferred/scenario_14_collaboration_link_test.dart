// SKELETON — Nice-to-have #14: Create a collaboration → receiver can
// open the link and see added files.
//
// **What collaboration adds beyond a share link (per
// `lib/core/services/collaboration_service.dart`):**
// - Bidirectional sync — receiver can add files too, owner sees them.
// - Persistent participant list with X25519 keys for each participant.
// - Conflict resolution on concurrent writes.
//
// **Test plan:**
// Unit tests (deferred):
// - Collaboration token construction encodes both owner + receiver
//   public keys correctly.
// - Per-participant access decisions: owner can revoke specific
//   receivers without rotating the whole bucket.
//
// Integration tests:
// - Owner creates collab → receiver accepts → owner adds file →
//   receiver sees it → receiver adds file → owner sees it.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Nice-to-have #14 — Collaboration link (SKELETON)', () {
    test('TODO: collaboration token encodes both keypairs', () => null,
        skip: 'TODO: see file header for implementation plan');
    test('TODO: integration — bidirectional file flow', () => null,
        skip: 'requires two-device or fake-receiver integration harness');
  });
}
