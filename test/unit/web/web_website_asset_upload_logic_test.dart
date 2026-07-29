import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/web/services/web_website_asset_upload_logic.dart';

void main() {
  group('key building', () {
    test('objectKey = sanitized name + / + fileName (native byte parity)', () {
      expect(websiteAssetObjectKey('Real Estate', 'Photo 1.png'),
          'Real_Estate/Photo 1.png'); // fileName is NOT sanitized — key parity
      expect(websiteAssetObjectKey('My-Site_1', 'a.mp4'), 'My-Site_1/a.mp4');
    });

    test('remoteKey = bucket/objectKey', () {
      expect(websiteAssetRemoteKey('Real Estate', 'a.png'),
          'website-assets/Real_Estate/a.png');
    });

    test('isWebsiteAssetRemoteKey', () {
      expect(isWebsiteAssetRemoteKey('website-assets/X/a.png'), isTrue);
      expect(isWebsiteAssetRemoteKey('images-v8/a.png'), isFalse);
      expect(isWebsiteAssetRemoteKey(null), isFalse);
      expect(isWebsiteAssetRemoteKey(''), isFalse);
    });

    test('objectKeyFromRemoteKey round-trips; rejects foreign/malformed', () {
      expect(websiteAssetObjectKeyFromRemoteKey('website-assets/X/a.png'),
          'X/a.png');
      expect(websiteAssetObjectKeyFromRemoteKey('website-assets/'), isNull);
      expect(websiteAssetObjectKeyFromRemoteKey('images-v8/a.png'), isNull);
      expect(websiteAssetObjectKeyFromRemoteKey(null), isNull);
    });

    test('encodeObjectKeyForUrl percent-encodes per segment, keeps slashes', () {
      expect(encodeObjectKeyForUrl('My_Site/My Photo 1.jpg'),
          'My_Site/My%20Photo%201.jpg');
      expect(encodeObjectKeyForUrl('X/a#b?c&d.png'), 'X/a%23b%3Fc%26d.png');
      expect(encodeObjectKeyForUrl('X/plain.png'), 'X/plain.png');
      // Parses cleanly as a URL afterwards.
      expect(
          Uri.parse('https://h/b/${encodeObjectKeyForUrl('S/a b#c.png')}')
              .pathSegments
              .last,
          'a b#c.png');
    });
  });

  group('validateWebsiteAssetImport', () {
    ({bool ok, String? reason}) v(String name, int size, {int known = 0}) =>
        validateWebsiteAssetImport(
            fileName: name, sizeBytes: size, groupKnownBytes: known);

    test('accepts supported types under their caps', () {
      expect(v('a.png', kWebsiteMaxImageBytes).ok, isTrue);
      expect(v('a.pdf', kWebsiteMaxBinaryDocBytes).ok, isTrue);
      expect(v('a.md', kWebsiteMaxTextBytes).ok, isTrue);
      expect(v('a.mp4', kWebsiteMaxVideoBytes).ok, isTrue);
      expect(v('A.JPG', 1024).ok, isTrue); // case-insensitive ext
    });

    test('rejects unsupported extensions with a reason', () {
      final r = v('archive.zip', 10);
      expect(r.ok, isFalse);
      expect(r.reason, contains('archive.zip'));
      expect(r.reason, contains('unsupported'));
      expect(v('noext', 10).ok, isFalse);
      expect(v('clip.mkv', 10).ok, isFalse); // non-browser-playable video
    });

    test('rejects per-type oversize with both sizes in the reason', () {
      final r = v('big.png', kWebsiteMaxImageBytes + 1);
      expect(r.ok, isFalse);
      expect(r.reason, contains('big.png'));
      expect(r.reason, contains('too large'));
      final vid = v('big.mp4', kWebsiteMaxVideoBytes + 1);
      expect(vid.ok, isFalse);
    });

    test('rejects when the group aggregate would exceed the total cap', () {
      final r = v('a.mp4', kWebsiteMaxVideoBytes,
          known: kWebsiteMaxTotalUploadBytes - kWebsiteMaxVideoBytes + 1);
      expect(r.ok, isFalse);
      expect(r.reason, contains('group total'));
      // Exactly at the cap is fine.
      expect(
          v('a.mp4', kWebsiteMaxVideoBytes,
                  known: kWebsiteMaxTotalUploadBytes - kWebsiteMaxVideoBytes)
              .ok,
          isTrue);
    });
  });

  group('cidFromEtagHeader', () {
    test('de-quotes and returns a plain CID', () {
      expect(cidFromEtagHeader('"bafkreiabc123"'), 'bafkreiabc123');
      expect(cidFromEtagHeader('bafybeidef'), 'bafybeidef');
      expect(cidFromEtagHeader(' "bafk1" '), 'bafk1');
    });

    test('null/empty → null', () {
      expect(cidFromEtagHeader(null), isNull);
      expect(cidFromEtagHeader(''), isNull);
      expect(cidFromEtagHeader('""'), isNull);
    });

    test('composite multipart ETag ({32hex}-{n}) is REJECTED, never a CID', () {
      expect(
          cidFromEtagHeader('"0123456789abcdef0123456789abcdef-3"'), isNull);
      expect(cidFromEtagHeader('deadbeefdeadbeefdeadbeefdeadbeef-12'), isNull);
      // 32-hex WITHOUT a part suffix is not the composite shape — allowed.
      expect(cidFromEtagHeader('0123456789abcdef0123456789abcdef'),
          '0123456789abcdef0123456789abcdef');
    });
  });

  group('shouldRetryUpload', () {
    test('one automatic retry for network/5xx only', () {
      expect(shouldRetryUpload(attempt: 1, status: 0), isTrue); // network
      expect(shouldRetryUpload(attempt: 1, status: 500), isTrue);
      expect(shouldRetryUpload(attempt: 1, status: 503), isTrue);
      expect(shouldRetryUpload(attempt: 2, status: 0), isFalse); // exhausted
      expect(shouldRetryUpload(attempt: 2, status: 502), isFalse);
    });

    test('4xx never auto-retries', () {
      expect(shouldRetryUpload(attempt: 1, status: 401), isFalse);
      expect(shouldRetryUpload(attempt: 1, status: 403), isFalse);
      expect(shouldRetryUpload(attempt: 1, status: 404), isFalse);
      expect(shouldRetryUpload(attempt: 1, status: 413), isFalse);
    });
  });
}
