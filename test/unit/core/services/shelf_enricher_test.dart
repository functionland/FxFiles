// Unit tests for ShelfEnricher. Covers:
//   - Per-category branches: Link / Note / Image / Video / Audio /
//     Document / File / Other / Screenshot.
//   - R14 SSRF guards: private IPs and non-http schemes never fetch.
//   - Failure paths: missing source file → failed; HTTP errors → URL
//     fallback; ML Kit throws → null labels but result not failed.
//
// Hot platform plugins (ML Kit, video_thumbnail) are skipped or
// substituted via the test seams on ShelfEnricher.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_enricher.dart';

class _StubLabel implements ImageLabel {
  @override
  final String label;
  @override
  final double confidence;
  @override
  final int index;
  _StubLabel(this.label, [this.confidence = 0.9]) : index = 0;
}

class _CannedClient extends http.BaseClient {
  final List<int> body;
  _CannedClient({required this.body});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([body]),
      200,
      headers: const {'content-type': 'text/html'},
      request: request,
    );
  }
}

/// HTTP mock that maps requested URLs to canned responses. Each stub
/// provides a `matches` predicate (host check, path check, etc.) plus
/// the response body, status, and content-type to return. Used by the
/// link-thumbnail and Twitter-syndication tests where one enrich() call
/// triggers multiple fetches (HTML page → og:image; or syndication
/// JSON → media image).
class _Stub {
  final bool Function(Uri url) matches;
  final List<int> body;
  final int status;
  final String contentType;
  _Stub({
    required this.matches,
    required this.body,
    this.status = 200,
    this.contentType = 'text/html',
  });
}

class _MultiUrlClient extends http.BaseClient {
  final List<_Stub> stubs;
  final List<Uri> requestedUrls = <Uri>[];
  final List<Map<String, String>> requestedHeaders =
      <Map<String, String>>[];
  _MultiUrlClient(this.stubs);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestedUrls.add(request.url);
    requestedHeaders.add(Map<String, String>.from(request.headers));
    for (final stub in stubs) {
      if (stub.matches(request.url)) {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([stub.body]),
          stub.status,
          headers: {'content-type': stub.contentType},
          request: request,
        );
      }
    }
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      404,
      request: request,
    );
  }
}

ShelfItem _item({
  required String id,
  required ShelfCategory category,
  required String localCachePath,
  String originalName = 'sample',
  String? mimeType,
  int sizeBytes = 100,
  String? textPayload,
}) {
  return ShelfItem(
    id: id,
    receivedAt: DateTime.utc(2026, 5, 21),
    originalName: originalName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    localCachePath: localCachePath,
    category: category,
    contentSha: 'sha-$id',
    textPayload: textPayload,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dump_enricher_test_');
    ShelfEnricher.instance.resetForTesting();
    ShelfEnricher.instance.thumbsDirOverride =
        () async => Directory('${tempDir.path}/thumbs');
    // Stub DNS so the SSRF guard works offline. Treat `localhost` as
    // loopback (so the existing guard test still verifies blocking)
    // and every other host as a synthetic public address — the
    // private-IP check in `_isPublicHttpsTarget` runs against the
    // returned addresses, not the hostname.
    ShelfEnricher.instance.dnsLookupOverride = (host) async {
      if (host == 'localhost') {
        return [InternetAddress.loopbackIPv4];
      }
      return [InternetAddress('203.0.113.10')]; // TEST-NET-3
    };
  });

  tearDown(() async {
    ShelfEnricher.instance.resetForTesting();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // Windows occasionally holds the dir briefly; harmless.
    }
  });

  group('Note enrichment', () {
    test('title = first non-empty line trimmed, desc = leading 200 chars',
        () async {
      final path = '${tempDir.path}/note.txt';
      await File(path).writeAsString('  \n\nFirst line of the note\nbody');
      final item = _item(
        id: 'n1',
        category: ShelfCategory.note,
        localCachePath: path,
        originalName: 'note.txt',
        mimeType: 'text/plain',
        textPayload: '  \n\nFirst line of the note\nbody',
      );
      final res = await ShelfEnricher.instance.enrich(item);
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'First line of the note');
      expect(res.description, contains('First line of the note'));
    });

    test('very long first line is truncated', () async {
      final long = List.generate(200, (_) => 'x').join();
      final path = '${tempDir.path}/note.txt';
      await File(path).writeAsString(long);
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'n2',
        category: ShelfCategory.note,
        localCachePath: path,
        textPayload: long,
      ));
      expect(res.title!.length, lessThanOrEqualTo(60));
      expect(res.title!.endsWith('…'), isTrue);
    });

    test('empty payload returns title=originalName, desc=0 bytes · Note',
        () async {
      final path = '${tempDir.path}/note.txt';
      await File(path).writeAsString('');
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'n3',
        category: ShelfCategory.note,
        localCachePath: path,
        originalName: 'note.txt',
        textPayload: '',
      ));
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'note.txt');
      expect(res.description, contains('Note'));
    });
  });

  group('Link enrichment — R14 SSRF guards', () {
    test('non-http scheme returns host fallback without fetching', () async {
      ShelfEnricher.instance.linkHttpClientOverride = _CannedClient(
        body: 'should not be called'.codeUnits,
      );
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'l1',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'javascript:alert(1)',
      ));
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, isNotNull);
    });

    test('private-IP host is not fetched (no OG title)', () async {
      ShelfEnricher.instance.linkHttpClientOverride = _CannedClient(
        body: '<title>SHOULD NOT APPEAR</title>'.codeUnits,
      );
      // `localhost` resolves to 127.0.0.1 — the private-IP guard
      // should block the fetch.
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'l2',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'http://localhost/foo',
      ));
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'localhost');
      expect(res.description, 'http://localhost/foo');
    });

    test('empty/missing textPayload returns Link description', () async {
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'l3',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: '',
      ));
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.description, 'Link');
    });
  });

  group('Link enrichment — OG metadata + thumbnail', () {
    test('og:image is downloaded, downscaled, and saved as thumbnail',
        () async {
      final pngImage = img.Image(width: 512, height: 512);
      img.fill(pngImage, color: img.ColorRgb8(100, 50, 200));
      final pngBytes = img.encodePng(pngImage);

      final html = '''
        <html><head>
          <meta property="og:title" content="Test Article" />
          <meta property="og:description" content="A short description" />
          <meta property="og:image" content="https://images.example.com/hero.png" />
        </head><body></body></html>
      '''
          .codeUnits;

      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(
          matches: (u) => u.host == 'example.com',
          body: html,
          contentType: 'text/html; charset=utf-8',
        ),
        _Stub(
          matches: (u) => u.host == 'images.example.com',
          body: pngBytes,
          contentType: 'image/png',
        ),
      ]);

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'lp1',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/article',
      ));

      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'Test Article');
      expect(res.description, 'A short description');
      expect(res.thumbnailPath, isNotNull);
      final thumb = File(res.thumbnailPath!);
      expect(await thumb.exists(), isTrue);
      final decoded = img.decodeImage(await thumb.readAsBytes())!;
      expect(decoded.width, lessThanOrEqualTo(256));
      expect(decoded.height, lessThanOrEqualTo(256));
    });

    test('meta name="description" fallback when og:description absent',
        () async {
      final html = '''
        <html><head>
          <title>Plain Page</title>
          <meta name="description" content="Fallback description here" />
        </head><body></body></html>
      '''
          .codeUnits;
      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(matches: (u) => true, body: html),
      ]);

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'lp2',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/no-og',
      ));
      expect(res.title, 'Plain Page');
      expect(res.description, 'Fallback description here');
      expect(res.thumbnailPath, isNull);
    });

    test('og:image pointing to localhost is blocked', () async {
      final html = '''
        <html><head>
          <meta property="og:title" content="Try SSRF" />
          <meta property="og:image" content="http://localhost/admin.png" />
        </head><body></body></html>
      '''
          .codeUnits;
      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(matches: (u) => u.host == 'example.com', body: html),
      ]);

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'lp3',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/article',
      ));
      expect(res.title, 'Try SSRF');
      expect(res.thumbnailPath, isNull);
    });

    test('non-image content-type for og:image is rejected', () async {
      final html = '''
        <html><head>
          <meta property="og:title" content="Sneaky" />
          <meta property="og:image" content="https://images.example.com/fake" />
        </head><body></body></html>
      '''
          .codeUnits;
      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(matches: (u) => u.host == 'example.com', body: html),
        _Stub(
          matches: (u) => u.host == 'images.example.com',
          body: 'not an image'.codeUnits,
          contentType: 'text/plain',
        ),
      ]);

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'lp4',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/article',
      ));
      expect(res.title, 'Sneaky');
      expect(res.thumbnailPath, isNull);
    });

    test('non-ASCII OG metadata decodes correctly (Farsi UTF-8)',
        () async {
      // Farsi characters in HTML are encoded as UTF-8 multi-byte
      // sequences. Before the UTF-8 fix in _readCapped, this would
      // come back as mojibake (each byte interpreted as Latin-1).
      const farsiTitle = 'مقاله آزمایشی';
      const farsiDesc = 'این یک توضیح کوتاه است.';
      final html = utf8.encode('''
        <html><head>
          <meta property="og:title" content="$farsiTitle" />
          <meta property="og:description" content="$farsiDesc" />
        </head><body></body></html>
      ''');
      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(matches: (u) => true, body: html),
      ]);
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'lp_farsi',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/farsi',
      ));
      expect(res.title, farsiTitle);
      expect(res.description, farsiDesc);
    });

    test('long og:description is truncated to ~200 chars', () async {
      final longDesc = 'X' * 400;
      final html = '''
        <html><head>
          <meta property="og:title" content="LongDesc" />
          <meta property="og:description" content="$longDesc" />
        </head><body></body></html>
      '''
          .codeUnits;
      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(matches: (u) => true, body: html),
      ]);
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'lp5',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/article',
      ));
      expect(res.description!.length, lessThanOrEqualTo(200));
      expect(res.description!.endsWith('…'), isTrue);
    });
  });

  group('Link enrichment — Twitter / X syndication', () {
    test('computeTwitterSyndicationToken: non-empty, alphanumeric, no dots',
        () {
      final token = ShelfEnricher.computeTwitterSyndicationToken(
          '1234567890123456789');
      expect(token, isNotEmpty);
      expect(token.contains('.'), isFalse);
      expect(RegExp(r'^[0-9a-z]+$').hasMatch(token), isTrue);
    });

    test(
        'computeTwitterSyndicationToken: byte-exact match for realistic '
        'snowflake-shaped tweet IDs', () {
      // Reference values produced by Node.js using the canonical JS
      // formula `((Number(id) / 1e15) * Math.PI).toString(36)
      //         .replace(/(0+|\.)/g, '')`.
      //
      // Our Dart implementation matches JS for tweet IDs in the
      // 10^17–10^18 range (where real X snowflake IDs sit) by
      // generating digits until f reaches zero and returning the
      // shortest truncation whose reverse-parse equals the original
      // double. For IDs near `Number.MAX_SAFE_INTEGER` (≥ 9×10^18)
      // and very small IDs (< 10^10), JS's V8 engine uses an
      // additional delta-aware rounding step we don't fully port —
      // the syndication call in `_enrichLink` falls back to a
      // Twitterbot UA fetch when syndication returns nothing, so
      // those edge cases still surface real thumbnails.
      final cases = <String, String>{
        '100000000000000000': '8q5qeon85v4',
        '1000000000000000000': '2f9lc2ug9mm',
        '1234567890123456789': '2zqic77uqyk',
      };
      cases.forEach((id, expected) {
        expect(
          ShelfEnricher.computeTwitterSyndicationToken(id),
          equals(expected),
          reason: 'id=$id',
        );
      });
    });

    test('computeTwitterSyndicationToken: invalid id → empty', () {
      expect(
          ShelfEnricher.computeTwitterSyndicationToken('not-a-number'), '');
      expect(ShelfEnricher.computeTwitterSyndicationToken(''), '');
    });

    test('x.com URL → syndication produces title/desc/thumb', () async {
      final pngImage = img.Image(width: 300, height: 300);
      img.fill(pngImage, color: img.ColorRgb8(20, 130, 200));
      final pngBytes = img.encodePng(pngImage);

      final json = jsonEncode({
        'text': 'Hello world from the tweet body',
        'user': {
          'screen_name': 'alice',
          'profile_image_url_https':
              'https://pbs.twimg.com/profile_images/alice.png',
        },
        'mediaDetails': [
          {
            'media_url_https':
                'https://pbs.twimg.com/media/tweet-image.jpg',
          }
        ],
      });

      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(
          matches: (u) => u.host == 'cdn.syndication.twimg.com',
          body: json.codeUnits,
          contentType: 'application/json',
        ),
        _Stub(
          matches: (u) => u.host == 'pbs.twimg.com',
          body: pngBytes,
          contentType: 'image/jpeg',
        ),
      ]);

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'tw1',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://x.com/alice/status/1234567890123456789',
      ));

      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'Tweet by @alice');
      expect(res.description, 'Hello world from the tweet body');
      expect(res.thumbnailPath, isNotNull);
      expect(await File(res.thumbnailPath!).exists(), isTrue);
    });

    test('syndication 404 falls back to Twitterbot UA OG fetch',
        () async {
      final html = '''
        <html><head>
          <meta property="og:title" content="Fallback Title" />
        </head><body></body></html>
      '''
          .codeUnits;

      final mc = _MultiUrlClient([
        _Stub(
          matches: (u) => u.host == 'cdn.syndication.twimg.com',
          body: const <int>[],
          status: 404,
        ),
        _Stub(matches: (u) => u.host == 'x.com', body: html),
      ]);
      ShelfEnricher.instance.linkHttpClientOverride = mc;

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'tw2',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://x.com/bob/status/9999999999999999999',
      ));
      expect(res.title, 'Fallback Title');

      // The x.com follow-up fetch must use Twitterbot UA — that's
      // the only UA X actually serves OG metadata to (as of 2024+).
      final xIdx = mc.requestedUrls.indexWhere((u) => u.host == 'x.com');
      expect(xIdx, greaterThanOrEqualTo(0),
          reason: 'expected an x.com fallback fetch');
      expect(
        mc.requestedHeaders[xIdx]['User-Agent'],
        equals('Twitterbot/1.0'),
      );
    });

    test('non-twitter URL uses default User-Agent (not Twitterbot)',
        () async {
      final mc = _MultiUrlClient([
        _Stub(
          matches: (u) => u.host == 'example.com',
          body: '<title>Generic</title>'.codeUnits,
        ),
      ]);
      ShelfEnricher.instance.linkHttpClientOverride = mc;

      await ShelfEnricher.instance.enrich(_item(
        id: 'tw_ua_default',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/article',
      ));

      final idx =
          mc.requestedUrls.indexWhere((u) => u.host == 'example.com');
      expect(idx, greaterThanOrEqualTo(0));
      expect(
        mc.requestedHeaders[idx]['User-Agent'],
        equals('FxFiles-Shelf/1.0'),
      );
    });

    test('mobile.twitter.com / twitter.com hosts also route to syndication',
        () async {
      final json = jsonEncode({
        'text': 'mobile tweet',
        'user': {'screen_name': 'm'},
      });
      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(
          matches: (u) => u.host == 'cdn.syndication.twimg.com',
          body: json.codeUnits,
          contentType: 'application/json',
        ),
      ]);
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'tw3',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload:
            'https://mobile.twitter.com/m/status/1234567890123456789',
      ));
      expect(res.title, 'Tweet by @m');
      expect(res.description, 'mobile tweet');
    });

    test('non-twitter URL does not call the syndication endpoint',
        () async {
      final mc = _MultiUrlClient([
        _Stub(
          matches: (u) => true,
          body: '<title>Wiki</title>'.codeUnits,
        ),
      ]);
      ShelfEnricher.instance.linkHttpClientOverride = mc;
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'tw4',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://en.wikipedia.org/wiki/Test',
      ));
      expect(res.title, 'Wiki');
      expect(
        mc.requestedUrls
            .any((u) => u.host == 'cdn.syndication.twimg.com'),
        isFalse,
        reason: 'non-twitter URLs must not hit syndication',
      );
    });

    test(
        'facebook.com URL uses facebookexternalhit UA (not syndication, '
        'not default)', () async {
      final html = utf8.encode('''
        <html><head>
          <meta property="og:title" content="پست فیسبوک" />
          <meta property="og:description" content="یک توضیح فارسی" />
          <meta property="og:image" content="https://scontent.fb.com/img.jpg" />
        </head><body></body></html>
      ''');
      final pngBytes =
          img.encodePng(img.Image(width: 64, height: 64));
      final mc = _MultiUrlClient([
        _Stub(
          matches: (u) => u.host == 'www.facebook.com',
          body: html,
          contentType: 'text/html; charset=utf-8',
        ),
        _Stub(
          matches: (u) => u.host == 'scontent.fb.com',
          body: pngBytes,
          contentType: 'image/jpeg',
        ),
      ]);
      ShelfEnricher.instance.linkHttpClientOverride = mc;

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'fb1',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://www.facebook.com/share/p/abc123/',
      ));

      // Title + description come back as Farsi (UTF-8 round-trips).
      expect(res.title, 'پست فیسبوک');
      expect(res.description, 'یک توضیح فارسی');
      expect(res.thumbnailPath, isNotNull);

      // Verify the UA used for the FB page fetch — must NOT be the
      // default, must be facebookexternalhit. Without this UA,
      // Facebook serves a useless login wall.
      final fbIdx =
          mc.requestedUrls.indexWhere((u) => u.host == 'www.facebook.com');
      expect(fbIdx, greaterThanOrEqualTo(0));
      expect(
        mc.requestedHeaders[fbIdx]['User-Agent'],
        equals('facebookexternalhit/1.1'),
      );
      // And no syndication call should have happened (FB ≠ Twitter).
      expect(
        mc.requestedUrls
            .any((u) => u.host == 'cdn.syndication.twimg.com'),
        isFalse,
      );
    });

    test('fb.com / fb.watch / m.facebook.com all route through FB UA',
        () async {
      for (final host in [
        'fb.com',
        'fb.watch',
        'm.facebook.com',
        'mbasic.facebook.com',
      ]) {
        final mc = _MultiUrlClient([
          _Stub(
            matches: (u) => u.host == host,
            body: '<title>FB</title>'.codeUnits,
          ),
        ]);
        ShelfEnricher.instance.linkHttpClientOverride = mc;
        await ShelfEnricher.instance.enrich(_item(
          id: 'fb_$host',
          category: ShelfCategory.link,
          localCachePath: '${tempDir.path}/share.txt',
          textPayload: 'https://$host/some-post',
        ));
        final idx = mc.requestedUrls.indexWhere((u) => u.host == host);
        expect(idx, greaterThanOrEqualTo(0), reason: 'host=$host');
        expect(
          mc.requestedHeaders[idx]['User-Agent'],
          equals('facebookexternalhit/1.1'),
          reason: 'host=$host should use facebookexternalhit UA',
        );
      }
    });

    test('numeric character references in OG content decode correctly',
        () async {
      // Sites that emit Farsi/Arabic/CJK as numeric character
      // references — &#1606; is Farsi 'ن' (noon); &#x646; is the
      // same character in hex. &#65; is ASCII 'A'. Mixed with raw
      // UTF-8 + named entities.
      final html = utf8.encode('''
        <html><head>
          <meta property="og:title" content="&#65; &amp; B with &#1606;&#x648;&#x646; &gt; 1" />
          <meta property="og:description" content="نکته: &#1601;&#1575;&#1585;&#1587;&#1740;" />
        </head><body></body></html>
      ''');
      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(matches: (u) => true, body: html),
      ]);

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'ent1',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/article',
      ));

      // &#65; → 'A', &amp; → '&', &#1606; → 'ن', &#x648; → 'و',
      // &#x646; → 'ن' again, &gt; → '>'.
      expect(res.title, 'A & B with نون > 1');
      // 'نکته: ' + decoded Farsi sequence
      expect(res.description, 'نکته: فارسی');
    });

    test('malformed numeric references pass through unchanged',
        () async {
      final html = utf8.encode('''
        <html><head>
          <meta property="og:title" content="&#999999999; bad &#xZZZ; ok" />
        </head><body></body></html>
      ''');
      ShelfEnricher.instance.linkHttpClientOverride = _MultiUrlClient([
        _Stub(matches: (u) => true, body: html),
      ]);

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'ent_bad',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://example.com/article',
      ));
      // The out-of-range decimal stays literal; the invalid-hex
      // sequence (&#xZZZ;) doesn't match the regex at all, also
      // literal.
      expect(res.title, contains('&#999999999;'));
      expect(res.title, contains('&#xZZZ;'));
      expect(res.title, contains('ok'));
    });

    test('x.com profile URL (no /status/) skips syndication', () async {
      final mc = _MultiUrlClient([
        _Stub(
          matches: (u) => u.host == 'x.com',
          body: '<title>Alice on X</title>'.codeUnits,
        ),
      ]);
      ShelfEnricher.instance.linkHttpClientOverride = mc;
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'tw5',
        category: ShelfCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'https://x.com/alice',
      ));
      expect(res.title, 'Alice on X');
      expect(
        mc.requestedUrls
            .any((u) => u.host == 'cdn.syndication.twimg.com'),
        isFalse,
      );
    });
  });

  group('Image enrichment', () {
    Future<File> writePng(String name, int w, int h) async {
      final image = img.Image(width: w, height: h);
      img.fill(image, color: img.ColorRgb8(200, 100, 50));
      final bytes = img.encodePng(image);
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(bytes);
      return file;
    }

    test('ML Kit labels populate title (Title Case) + description', () async {
      final file = await writePng('photo.png', 800, 600);
      ShelfEnricher.instance.imageLabelOverride = (_) async => [
            _StubLabel('sunset', 0.9),
            _StubLabel('sky', 0.85),
            _StubLabel('cloud', 0.7),
          ];

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'i1',
        category: ShelfCategory.image,
        localCachePath: file.path,
        originalName: 'photo.png',
        mimeType: 'image/png',
      ));
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'Sunset');
      expect(res.description, 'sunset, sky, cloud');
      expect(res.mlLabels, ['sunset', 'sky', 'cloud']);
      expect(res.thumbnailPath, isNotNull);
      expect(await File(res.thumbnailPath!).exists(), isTrue);
    });

    test('screenshot category always titles as "Screenshot"', () async {
      final file = await writePng('Screenshot_2026-05-21.png', 400, 400);
      ShelfEnricher.instance.imageLabelOverride = (_) async => [
            _StubLabel('text', 0.9),
          ];
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'i2',
        category: ShelfCategory.screenshot,
        localCachePath: file.path,
        originalName: 'Screenshot_2026-05-21.png',
      ));
      expect(res.title, 'Screenshot');
      expect(res.description, 'text');
    });

    test('ML Kit throwing falls back to filename + size·category', () async {
      final file = await writePng('photo.png', 400, 300);
      ShelfEnricher.instance.imageLabelOverride =
          (_) async => throw StateError('ML Kit unavailable');

      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'i3',
        category: ShelfCategory.image,
        localCachePath: file.path,
        originalName: 'photo.png',
        sizeBytes: 1024 * 50,
      ));
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'photo');
      expect(res.description, contains('Image'));
      expect(res.mlLabels, isEmpty);
    });

    test('downscales source image into the thumbs dir', () async {
      final file = await writePng('big.png', 1024, 768);
      ShelfEnricher.instance.imageLabelOverride = (_) async => const [];
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'i4',
        category: ShelfCategory.image,
        localCachePath: file.path,
        originalName: 'big.png',
      ));
      expect(res.thumbnailPath, isNotNull);
      final thumbBytes = await File(res.thumbnailPath!).readAsBytes();
      final decoded = img.decodeImage(thumbBytes)!;
      expect(decoded.width, lessThanOrEqualTo(256));
      expect(decoded.height, lessThanOrEqualTo(256));
    });

    test('missing source file → enrichment failed', () async {
      ShelfEnricher.instance.imageLabelOverride = (_) async => const [];
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'i5',
        category: ShelfCategory.image,
        localCachePath: '${tempDir.path}/does-not-exist.png',
      ));
      expect(res.status, ShelfEnrichmentStatus.failed);
    });
  });

  group('Audio / Document / File branches', () {
    test('audio uses filename + size·Audio', () async {
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'a1',
        category: ShelfCategory.audio,
        localCachePath: '${tempDir.path}/song.mp3',
        originalName: 'song.mp3',
        sizeBytes: 4 * 1024 * 1024,
      ));
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'song');
      expect(res.description, '4.0 MB · Audio');
    });

    test('document title=filename, desc="size · PDF"', () async {
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'd1',
        category: ShelfCategory.document,
        localCachePath: '${tempDir.path}/report.pdf',
        originalName: 'report.pdf',
        sizeBytes: 250 * 1024,
      ));
      expect(res.title, 'report');
      expect(res.description, '250.0 KB · PDF');
    });

    test('file description includes mimeType', () async {
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'f1',
        category: ShelfCategory.file,
        localCachePath: '${tempDir.path}/archive.zip',
        originalName: 'archive.zip',
        mimeType: 'application/zip',
        sizeBytes: 1024,
      ));
      expect(res.description, contains('application/zip'));
    });

    test('other defaults to filename + "unknown" mime', () async {
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'o1',
        category: ShelfCategory.other,
        localCachePath: '${tempDir.path}/weird.dat',
        originalName: 'weird.dat',
        sizeBytes: 1,
      ));
      expect(res.description, contains('unknown'));
    });
  });

  group('Video enrichment', () {
    test('missing video file → failed', () async {
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'v1',
        category: ShelfCategory.video,
        localCachePath: '${tempDir.path}/missing.mp4',
      ));
      expect(res.status, ShelfEnrichmentStatus.failed);
    });

    test('present file → done, with title/desc set even when '
        'video_thumbnail unavailable (test env)', () async {
      // Touch a stub file; the platform plugin isn't actually wired
      // up in `flutter test`, so the thumbnail call will fail and
      // the enricher's catch block leaves thumbnailPath null while
      // still returning done.
      final f = File('${tempDir.path}/clip.mp4');
      await f.writeAsBytes(Uint8List.fromList(List.filled(16, 0)));
      final res = await ShelfEnricher.instance.enrich(_item(
        id: 'v2',
        category: ShelfCategory.video,
        localCachePath: f.path,
        originalName: 'clip.mp4',
        sizeBytes: 16,
      ));
      expect(res.status, ShelfEnrichmentStatus.done);
      expect(res.title, 'clip');
      expect(res.description, contains('Video'));
    });
  });
}
