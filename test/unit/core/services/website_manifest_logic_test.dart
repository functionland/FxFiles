import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/website_manifest_logic.dart';
import 'package:fula_files/web/services/web_website_assets_logic.dart';

Map<String, dynamic> _gen(
  String id, {
  int? status,
  String updatedAt = '2026-01-02T00:00:00.000',
  String createdAt = '2026-01-01T00:00:00.000',
  List<dynamic>? assets,
  bool omitStatus = false,
}) =>
    {
      'id': id,
      'tagId': 't1',
      'tagName': 'websites-demo',
      'prompt': 'p',
      if (!omitStatus) 'status': status ?? WebsiteGenStatus.completed.index,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      if (assets != null) 'assets': assets,
    };

Map<String, dynamic> _asset(
  String name, {
  String? parsedContent,
  bool uploaded = true,
  String? cid,
  bool omitCid = false,
}) =>
    {
      'localPath': '',
      'fileName': name,
      'type': 'document',
      if (!omitCid) 'cid': cid ?? 'bafy-$name',
      'uploaded': uploaded,
      'parsedContent': parsedContent,
      'comment': 'note-$name',
    };

String? _pc(List<Map<String, dynamic>> out, String genId, String fileName) {
  final g = out.firstWhere((m) => m['id'] == genId);
  final a = (g['assets'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((m) => m['fileName'] == fileName);
  return a['parsedContent'] as String?;
}

void main() {
  group('stripAssetParsedContent', () {
    test('nulls every asset parsedContent, preserves everything else', () {
      final input = _gen('a', assets: [
        _asset('x.txt', parsedContent: 'X'),
        _asset('y.txt', parsedContent: 'Y'),
      ]);
      final out = stripAssetParsedContent(input);
      final assets = (out['assets'] as List).cast<Map<String, dynamic>>();
      expect(assets.map((a) => a['parsedContent']).toList(), [null, null]);
      expect(assets.first['cid'], 'bafy-x.txt');
      expect(assets.first['comment'], 'note-x.txt');
      expect(out['id'], 'a');
      // Input untouched.
      expect((input['assets'] as List).first['parsedContent'], 'X');
    });

    test('missing/odd assets shapes pass through without throwing', () {
      expect(stripAssetParsedContent(_gen('a'))['assets'], isNull);
      final odd = _gen('a', assets: ['junk', 42]);
      expect(stripAssetParsedContent(odd)['assets'], ['junk', 42]);
    });
  });

  group('stripParsedContentKeepFreshest', () {
    test('freshest completed occurrence keeps parsedContent, older nulled',
        () {
      final out = stripParsedContentKeepFreshest([
        _gen('old',
            updatedAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'OLD')]),
        _gen('new',
            updatedAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'NEW')]),
      ]);
      expect(_pc(out, 'new', 'x.txt'), 'NEW');
      expect(_pc(out, 'old', 'x.txt'), isNull);
    });

    test('a file only present in an OLDER generation keeps its parse there',
        () {
      final out = stripParsedContentKeepFreshest([
        _gen('old',
            updatedAt: '2026-01-01T00:00:00.000',
            assets: [_asset('only-old.txt', parsedContent: 'KEEP')]),
        _gen('new',
            updatedAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'NEW')]),
      ]);
      expect(_pc(out, 'old', 'only-old.txt'), 'KEEP');
    });

    test('winner with NULL parsedContent does not resurrect older value',
        () {
      final out = stripParsedContentKeepFreshest([
        _gen('old',
            updatedAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'OLD')]),
        _gen('new',
            updatedAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: null)]),
      ]);
      expect(_pc(out, 'new', 'x.txt'), isNull);
      expect(_pc(out, 'old', 'x.txt'), isNull);
    });

    test('non-completed generations never claim; older completed one wins',
        () {
      final out = stripParsedContentKeepFreshest([
        _gen('done',
            updatedAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'DONE')]),
        _gen('failed',
            status: WebsiteGenStatus.error.index,
            updatedAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'FAILED')]),
      ]);
      expect(_pc(out, 'done', 'x.txt'), 'DONE');
      expect(_pc(out, 'failed', 'x.txt'), isNull);
    });

    test('missing status coerces to completed (fromJson default)', () {
      final out = stripParsedContentKeepFreshest([
        _gen('a',
            omitStatus: true,
            assets: [_asset('x.txt', parsedContent: 'KEEP')]),
      ]);
      expect(_pc(out, 'a', 'x.txt'), 'KEEP');
    });

    test('uploaded=false or missing/empty cid never claims', () {
      final out = stripParsedContentKeepFreshest([
        _gen('winner',
            updatedAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'GOOD')]),
        _gen('later-bad',
            updatedAt: '2026-01-05T00:00:00.000',
            assets: [
              _asset('x.txt', parsedContent: 'NOT-UPLOADED', uploaded: false),
              _asset('y.txt', parsedContent: 'NO-CID', omitCid: true),
              _asset('z.txt', parsedContent: 'EMPTY-CID', cid: ''),
            ]),
      ]);
      expect(_pc(out, 'winner', 'x.txt'), 'GOOD');
      expect(_pc(out, 'later-bad', 'x.txt'), isNull);
      expect(_pc(out, 'later-bad', 'y.txt'), isNull);
      expect(_pc(out, 'later-bad', 'z.txt'), isNull);
    });

    test('duplicate fileName within one generation: first occurrence wins',
        () {
      final out = stripParsedContentKeepFreshest([
        _gen('a', assets: [
          _asset('x.txt', parsedContent: 'FIRST'),
          _asset('x.txt', parsedContent: 'SECOND'),
        ]),
      ]);
      final assets = ((out.single)['assets'] as List)
          .cast<Map<String, dynamic>>();
      expect(assets[0]['parsedContent'], 'FIRST');
      expect(assets[1]['parsedContent'], isNull);
    });

    test('robust to id-less, assets-less, malformed-date entries', () {
      final out = stripParsedContentKeepFreshest([
        {'tagId': 't1'}, // no id, no assets, no dates
        _gen('a',
            updatedAt: 'not-a-date',
            assets: [_asset('x.txt', parsedContent: 'KEEP')]),
        {
          'id': 'weird',
          'assets': 'not-a-list',
        },
      ]);
      expect(out, hasLength(3));
      expect(_pc(out, 'a', 'x.txt'), 'KEEP');
      expect(out[2]['assets'], 'not-a-list');
    });

    test('inputs never mutated; output preserves input order', () {
      final input = [
        _gen('b',
            updatedAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'B')]),
        _gen('a',
            updatedAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'A')]),
      ];
      final snapshot = jsonEncode(input);
      final out = stripParsedContentKeepFreshest(input);
      expect(jsonEncode(input), snapshot);
      expect(out.map((m) => m['id']).toList(), ['b', 'a']);
    });

    test(
        'ROUND-TRIP PROPERTY: websiteCidAssetsByName resolves identically '
        'over stripped and unstripped manifests', () {
      final manifest = [
        _gen('g1',
            updatedAt: '2026-01-01T00:00:00.000',
            assets: [
              _asset('a.txt', parsedContent: 'a-old'),
              _asset('only-g1.txt', parsedContent: 'g1-only'),
              _asset('never-uploaded.txt',
                  parsedContent: 'nope', uploaded: false),
            ]),
        _gen('g2',
            status: WebsiteGenStatus.error.index,
            updatedAt: '2026-01-06T00:00:00.000',
            assets: [_asset('a.txt', parsedContent: 'from-failed-run')]),
        _gen('g3',
            updatedAt: '2026-01-04T00:00:00.000',
            assets: [
              _asset('a.txt', parsedContent: 'a-new'),
              _asset('b.txt', parsedContent: null),
              _asset('b.txt', parsedContent: 'dup-later'),
            ]),
      ];

      List<WebsiteGeneration> decode(List<Map<String, dynamic>> ms) =>
          ms.map(WebsiteGeneration.fromJson).toList()
            ..sort((x, y) => y.updatedAt.compareTo(x.updatedAt));

      final before = websiteCidAssetsByName(decode(manifest));
      final after =
          websiteCidAssetsByName(decode(stripParsedContentKeepFreshest(manifest)));

      expect(after.keys.toSet(), before.keys.toSet());
      for (final k in before.keys) {
        expect(after[k]!.parsedContent, before[k]!.parsedContent,
            reason: 'parsedContent for $k must survive the strip');
        expect(after[k]!.cid, before[k]!.cid);
      }
    });
  });
}
