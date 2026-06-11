import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/share_link_builder.dart';

void main() {
  group('public share URL', () {
    test('v2 payload fields + fragment decode round-trip', () {
      final url = buildPublicShareUrl(
        baseUrl: 'https://cloud.fx.land',
        tokenId: 'tid-1',
        fulaToken: '{"tok":1}',
        bucket: 'documents-v8',
        pathScope: '/a.txt',
        storageKey: 'bafy123',
        linkSecretKey: Uint8List.fromList(List.filled(32, 7)),
        fileName: 'a.txt',
      );
      expect(url, startsWith('https://cloud.fx.land/view/tid-1#'));
      final payload = jsonDecode(
              utf8.decode(base64Url.decode(Uri.parse(url).fragment)))
          as Map<String, dynamic>;
      expect(payload['v'], 2);
      expect(payload['t'], '{"tok":1}');
      expect(payload['b'], 'documents-v8');
      expect(payload['k'], '/a.txt');
      expect(payload['cid'], 'bafy123');
      expect(base64Decode(payload['sk'] as String),
          List.filled(32, 7));
      expect(payload['f'], 'a.txt');
      expect(payload.containsKey('folder'), isFalse);
    });
  });

  group('password-protected share URL', () {
    test('outer envelope decodes and inner payload decrypts with the '
        'password-derived key (wire-format pin)', () async {
      final built = await buildPasswordProtectedShareUrl(
        baseUrl: 'https://cloud.fx.land',
        tokenId: 'tid-2',
        fulaToken: '{"tok":2}',
        bucket: 'images-v8',
        pathScope: '/p.jpg',
        storageKey: 'bafyXYZ',
        linkSecretKey: Uint8List.fromList(List.filled(32, 9)),
        password: 'correct horse battery staple',
        fileName: 'p.jpg',
      );

      final outer = jsonDecode(
              utf8.decode(base64Url.decode(Uri.parse(built.url).fragment)))
          as Map<String, dynamic>;
      expect(outer['v'], 2);
      expect(outer['p'], true);
      expect(outer['b'], 'images-v8');
      expect(outer['k'], '/p.jpg');
      expect(base64Decode(outer['s'] as String), built.salt);

      // Recipient-side: derive from password+salt, decrypt, read inner.
      final key = await sharePasswordDeriveKey(
          'correct horse battery staple', built.salt);
      final inner = jsonDecode(utf8.decode(await sharePasswordDecrypt(
              Uint8List.fromList(base64Decode(outer['e'] as String)), key)))
          as Map<String, dynamic>;
      expect(inner['v'], 2);
      expect(inner['t'], '{"tok":2}');
      expect(inner['cid'], 'bafyXYZ');
      expect(base64Decode(inner['sk'] as String), List.filled(32, 9));

      // Wrong password must fail authentication.
      final wrongKey = await sharePasswordDeriveKey('wrong', built.salt);
      expect(
        () => sharePasswordDecrypt(
            Uint8List.fromList(base64Decode(outer['e'] as String)),
            wrongKey),
        throwsA(anything),
      );
    });
  });

  group('FULA share-ID codec', () {
    test('encode → decode round-trips a 32-byte key', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
      final id = encodeFulaShareId(key);
      expect(id, startsWith('FULA-'));
      expect(id.contains('='), isFalse); // padding stripped
      expect(decodeFulaShareId(id), key);
    });

    test('accepts lowercase prefix, surrounding whitespace and bare '
        'base64url without the prefix', () {
      final key = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final id = encodeFulaShareId(key);
      expect(decodeFulaShareId('  $id  '), key);
      expect(decodeFulaShareId('fula-${id.substring(5)}'), key);
      expect(decodeFulaShareId(id.substring(5)), key);
    });

    test('accepts standard base64 with padding (legacy paste)', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
      expect(decodeFulaShareId(base64Encode(key)), key);
    });

    test('throws on garbage input', () {
      expect(() => decodeFulaShareId('FULA-???not-base64???'),
          throwsA(isA<FormatException>()));
    });
  });

  group('recipient share link', () {
    test('uses the fxblox deep-link base by default', () {
      expect(buildRecipientShareUrl('TOKEN'), 'fxblox://share/TOKEN');
      expect(buildRecipientShareUrl('TOKEN', baseUrl: 'app://s'),
          'app://s/TOKEN');
    });
  });
}
