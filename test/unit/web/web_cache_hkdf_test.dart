import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_cache_hkdf.dart';

Uint8List _hex(String s) {
  final clean = s.replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('hkdfSha256', () {
    test('RFC 5869 test case 1 (SHA-256)', () {
      final okm = hkdfSha256(
        _hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        salt: _hex('000102030405060708090a0b0c'),
        info: _hex('f0f1f2f3f4f5f6f7f8f9'),
        length: 42,
      );
      expect(
        _toHex(okm),
        '3cb25f25faacd57a90434f64d0362f2a'
        '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });

    test('RFC 5869 test case 3 (zero-length salt and info)', () {
      final okm = hkdfSha256(
        _hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        salt: const [],
        info: const [],
        length: 42,
      );
      expect(
        _toHex(okm),
        '8da4e775a563c18f715f802a063c5a31'
        'b8a11f5c5ee1879ec3454e5f3c738d2d'
        '9d201395faa4b61a96c8',
      );
    });

    test('deterministic and length-exact for the cache derivation', () {
      final ikm = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final a = hkdfSha256(ikm,
          salt: 'fxfiles-web-listing-cache-salt-v1'.codeUnits,
          info: 'web-listing-cache-v1'.codeUnits);
      final b = hkdfSha256(ikm,
          salt: 'fxfiles-web-listing-cache-salt-v1'.codeUnits,
          info: 'web-listing-cache-v1'.codeUnits);
      expect(a, b);
      expect(a.length, 32);
      // Different info ⇒ different key (domain separation).
      final c = hkdfSha256(ikm,
          salt: 'fxfiles-web-listing-cache-salt-v1'.codeUnits,
          info: 'other-context'.codeUnits);
      expect(_toHex(c), isNot(_toHex(a)));
    });
  });
}
