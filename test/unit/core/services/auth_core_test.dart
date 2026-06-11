import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/auth_core.dart';
import 'package:fula_files/core/utils/canonical_kek_input.dart';
import 'package:fula_files/core/utils/seed_signing_input.dart';

void main() {
  group('AuthCore.buildSignedTranscript', () {
    test('golden bytes: layout matches the issuer wire format exactly', () {
      // "fula.seed-auth.v1\0" || purpose || 0x00 || euid_hex_ascii ||
      // 0x00 || challenge — MUST match
      // pinning-service/server/services/seedAuth.ts buildSignedTranscript.
      //
      // This pin exists because the domain separator's trailing NUL once
      // lived as an invisible literal 0x00 inside a string literal in
      // auth_service.dart; an editor or refactor replacing it with a
      // space would fork the protocol silently. The expected bytes below
      // are assembled WITHOUT referencing AuthCore's constants so a
      // drifted constant cannot satisfy its own test.
      final challenge = Uint8List.fromList([1, 2, 3, 0xfe, 0xff]);
      final got = AuthCore.buildSignedTranscript(
        'register-mode-c',
        '00ffab10',
        challenge,
      );

      final expected = <int>[
        ...utf8.encode('fula.seed-auth.v1'),
        0, // NUL inside the domain separator
        ...utf8.encode('register-mode-c'),
        0,
        ...ascii.encode('00ffab10'),
        0,
        1, 2, 3, 0xfe, 0xff,
      ];
      expect(got, equals(Uint8List.fromList(expected)));
    });

    test('NUL separator offsets are position-stable across purpose lengths',
        () {
      // Hardening (advisor review): boundary purposes must not shift the
      // relative layout — each section ends exactly at its NUL.
      for (final purpose in ['', 'x', 'register-mode-b' * 20]) {
        final got = AuthCore.buildSignedTranscript(
          purpose,
          'ab',
          Uint8List.fromList([7]),
        );
        final sepLen = 'fula.seed-auth.v1'.length;
        expect(got[sepLen], 0, reason: 'NUL after domain separator');
        expect(got[sepLen + 1 + purpose.length], 0, reason: 'NUL after purpose');
        expect(got[sepLen + 1 + purpose.length + 1 + 2], 0,
            reason: 'NUL after euid hex');
        expect(got.last, 7, reason: 'challenge is the tail');
        expect(got.length, sepLen + 1 + purpose.length + 1 + 2 + 1 + 1);
      }
    });

    test('domain separator constant ends with a single NUL', () {
      final bytes = utf8.encode(AuthCore.seedAuthDomainSeparator);
      expect(bytes.length, 'fula.seed-auth.v1'.length + 1);
      expect(bytes.last, 0);
      expect(
        utf8.decode(bytes.sublist(0, bytes.length - 1)),
        'fula.seed-auth.v1',
      );
    });
  });

  group('AuthCore KDF input assembly', () {
    test('Mode A input string is provider:userId:email', () {
      expect(
        AuthCore.modeAKekInput(
          providerName: 'google',
          userId: 'uid-123',
          email: 'a@b.c',
        ),
        'google:uid-123:a@b.c',
      );
    });

    test('KDF context constants are pinned', () {
      // These strings are KDF domain separators; changing any of them
      // re-keys every existing vault of that mode.
      expect(AuthCore.kekContextModeA, 'fula-files-v1');
      expect(AuthCore.kekContextModeB, 'fula-files-v2-mode-b');
      expect(AuthCore.kekContextModeC, 'fula-files-v2-mode-c');
      expect(AuthCore.bucketsIndexKeyContext, 'fula:user-buckets-index:v1');
      expect(AuthCore.userEntrySigningContext, 'fula:user-entry-signing:v1');
    });
  });

  group('canonical KEK input golden bytes (length-prefix layout)', () {
    List<int> u32le(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

    test('Mode B: u32le(len)||provider || u32le(len)||sub || u32le(len)||NFC(seed)', () {
      final got = canonicalKekInputModeB('google', 'sub1', 'seed');
      final expected = <int>[
        ...u32le(6), ...utf8.encode('google'),
        ...u32le(4), ...utf8.encode('sub1'),
        ...u32le(4), ...utf8.encode('seed'),
      ];
      expect(got, equals(Uint8List.fromList(expected)));
    });

    test('Mode C: u32le(len)||NFC(seed)', () {
      final got = canonicalKekInputModeC('abc');
      expect(got, equals(Uint8List.fromList([...u32le(3), ...utf8.encode('abc')])));
    });
  });

  group('modeBSigningInput byte shape', () {
    test('NUL separators survive utf8 encoding at exact offsets', () {
      // 'b\x00provider\x00sub\x00password' — the FFI consumes the utf8
      // bytes; the NULs are the collision barrier (audit fix #3).
      final bytes = utf8.encode(modeBSigningInput('google', 's1', 'pw'));
      final expected = <int>[
        ...utf8.encode('b'), 0,
        ...utf8.encode('google'), 0,
        ...utf8.encode('s1'), 0,
        ...utf8.encode('pw'),
      ];
      expect(bytes, equals(expected));
    });
  });

  group('AuthCore.bytesToHex', () {
    test('lowercase, zero-padded', () {
      expect(AuthCore.bytesToHex([0x00, 0xff, 0x10, 0xab]), '00ff10ab');
      expect(AuthCore.bytesToHex([]), '');
    });
  });

  group('AuthCore.extractJwtSub', () {
    String makeJwt(Map<String, dynamic> payload) {
      String b64(Map<String, dynamic> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      return '${b64({'alg': 'HS256'})}.${b64(payload)}.sig';
    }

    test('extracts sub from a well-formed JWT', () {
      expect(AuthCore.extractJwtSub(makeJwt({'sub': 'abc123'})), 'abc123');
    });

    test('null/empty/malformed inputs return null', () {
      expect(AuthCore.extractJwtSub(null), isNull);
      expect(AuthCore.extractJwtSub(''), isNull);
      expect(AuthCore.extractJwtSub('not-a-jwt'), isNull);
      expect(AuthCore.extractJwtSub(makeJwt({'no_sub': true})), isNull);
      expect(AuthCore.extractJwtSub(makeJwt({'sub': ''})), isNull);
    });
  });
}
