// SKELETON — Nice-to-have #11: Share link with 7-day expiry works.
//
// **Coverage plan:**
// Unit tests (testable today, just deferred):
// - `SharingService.createPublicLink(file, expiry: 7d)` produces a
//   token whose decoded `expiresAt` is now+7d (±a few seconds).
// - `SharingService.acceptShare(token)` rejects an expired token
//   with a typed error.
// - Token serialization round-trip.
//
// Integration test (the load-bearing part):
// - Real receiver flow: device A creates link, device B accepts +
//   downloads. Verify a 7d-expired token returns the expected error.
// - Server: master enforces expiry on the GET side. (Owned by
//   fula-client tier, not FxFiles.)
//
// **TODO:** add `FulaApi.createShareToken(...)` to the abstract
// surface (it's intentionally NOT there yet — see fula_api.dart
// comment), then write tests.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Nice-to-have #11 — Share link with 7d expiry (SKELETON)', () {
    test('TODO: createShareToken yields token with expiresAt ~7d ahead',
        () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: acceptShare rejects expired token cleanly', () => null, skip: 'TODO: see file header for implementation plan');
    test('TODO: integration — cross-device share + accept', () => null,
        skip: 'requires two app instances or fake receiver');
  });
}
