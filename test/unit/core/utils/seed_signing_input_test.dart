/// Tests for audit fix #3 — Mode B signing-key derivation must bind
/// to `(provider, oauth_sub, password)` so two Mode B users with the
/// same password under different OAuth identities derive DIFFERENT
/// Ed25519 keypairs.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/utils/seed_signing_input.dart';

void main() {
  group('Mode B signing-key input (audit fix #3)', () {
    test('distinct oauth_subs produce distinct signing inputs', () {
      final a = modeBSigningInput('google', 'sub-A', 'common-password');
      final b = modeBSigningInput('google', 'sub-B', 'common-password');
      expect(a, isNot(equals(b)),
          reason: 'Without this binding, two users sharing a password under '
              'different Google accounts would have identical Ed25519 '
              'keypairs — meaning either could sign in to the other\'s vault '
              'after reading the effective_user_id from the public CBOR.');
    });

    test('distinct providers produce distinct signing inputs', () {
      final a = modeBSigningInput('google', 'shared-sub', 'pw');
      final b = modeBSigningInput('apple', 'shared-sub', 'pw');
      expect(a, isNot(equals(b)));
    });

    test('distinct passwords produce distinct signing inputs', () {
      final a = modeBSigningInput('google', 'sub', 'password-A');
      final b = modeBSigningInput('google', 'sub', 'password-B');
      expect(a, isNot(equals(b)));
    });

    test('determinism: same inputs → same string', () {
      final a = modeBSigningInput('google', 'sub-X', 'P@ssw0rd');
      final b = modeBSigningInput('google', 'sub-X', 'P@ssw0rd');
      expect(a, equals(b));
    });

    test('Mode B leading tag prevents collision with Mode C', () {
      // A Mode C user whose seed happens to look like the Mode B
      // input format MUST NOT collide. The leading 'b\x00' tag
      // ensures this.
      final modeB = modeBSigningInput('', '', 'foo');
      final modeC = modeCSigningInput('foo');
      expect(modeB, isNot(equals(modeC)));
      expect(modeB, startsWith('b\x00'));
    });

    test('Mode C: seed passes through unchanged', () {
      expect(modeCSigningInput('hello-world'), equals('hello-world'));
    });
  });
}
