import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/website_manifest_logic.dart';
import 'package:fula_files/web/services/web_website_assets_logic.dart';

Map<String, dynamic> _gen(
  String id, {
  String tagId = 't1',
  int? status,
  String updatedAt = '2026-01-02T00:00:00.000',
  String createdAt = '2026-01-01T00:00:00.000',
  List<dynamic>? assets,
  bool omitStatus = false,
}) =>
    {
      'id': id,
      'tagId': tagId,
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

/// EXACTLY what the recreate flow does before calling
/// websiteCidAssetsByName (web_website_detail_screen.dart `_generations`):
/// filter to ONE website group, then sort createdAt-DESC.
List<WebsiteGeneration> _consumerView(
        List<Map<String, dynamic>> manifest, String tagId) =>
    manifest
        .where((m) => m['tagId'] == tagId)
        .map(WebsiteGeneration.fromJson)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

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
      expect((input['assets'] as List).first['parsedContent'], 'X');
    });

    test('missing/odd assets shapes pass through without throwing', () {
      expect(stripAssetParsedContent(_gen('a'))['assets'], isNull);
      final odd = _gen('a', assets: ['junk', 42]);
      expect(stripAssetParsedContent(odd)['assets'], ['junk', 42]);
    });
  });

  group('stripParsedContentKeepFreshest', () {
    test('newest-by-createdAt completed occurrence keeps parsedContent', () {
      final out = stripParsedContentKeepFreshest([
        _gen('old',
            createdAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'OLD')]),
        _gen('new',
            createdAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'NEW')]),
      ]);
      expect(_pc(out, 'new', 'x.txt'), 'NEW');
      expect(_pc(out, 'old', 'x.txt'), isNull);
    });

    // REGRESSION (found in review): the consumer sorts by createdAt, so an
    // updatedAt-ordered strip preserved the WRONG copy whenever a
    // generation was created earlier but completed later.
    test('createdAt wins over updatedAt when the two disagree', () {
      final out = stripParsedContentKeepFreshest([
        // Created FIRST, completed LAST -> biggest updatedAt, older createdAt.
        _gen('created-first-finished-last',
            createdAt: '2026-01-01T00:00:00.000',
            updatedAt: '2026-01-09T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'LOSER')]),
        // Created LAST -> this is the one the consumer resolves.
        _gen('created-last',
            createdAt: '2026-01-04T00:00:00.000',
            updatedAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'WINNER')]),
      ]);
      expect(_pc(out, 'created-last', 'x.txt'), 'WINNER');
      expect(_pc(out, 'created-first-finished-last', 'x.txt'), isNull);
    });

    // REGRESSION (found in review): the consumer is scoped to ONE website
    // group, so a global winner-per-fileName stripped the parse a second
    // website needed for the same file name.
    test('two websites sharing a fileName each keep their own parse', () {
      final out = stripParsedContentKeepFreshest([
        _gen('a1',
            tagId: 'website-A',
            createdAt: '2026-01-09T00:00:00.000',
            assets: [_asset('logo.png', parsedContent: 'A-LOGO')]),
        _gen('b1',
            tagId: 'website-B',
            createdAt: '2026-01-02T00:00:00.000',
            assets: [_asset('logo.png', parsedContent: 'B-LOGO')]),
      ]);
      expect(_pc(out, 'a1', 'logo.png'), 'A-LOGO');
      expect(_pc(out, 'b1', 'logo.png'), 'B-LOGO');
    });

    test('within one website, older duplicates are still stripped', () {
      final out = stripParsedContentKeepFreshest([
        _gen('a1',
            tagId: 'website-A',
            createdAt: '2026-01-01T00:00:00.000',
            assets: [_asset('logo.png', parsedContent: 'A-OLD')]),
        _gen('a2',
            tagId: 'website-A',
            createdAt: '2026-01-09T00:00:00.000',
            assets: [_asset('logo.png', parsedContent: 'A-NEW')]),
      ]);
      expect(_pc(out, 'a2', 'logo.png'), 'A-NEW');
      expect(_pc(out, 'a1', 'logo.png'), isNull);
    });

    test('a file only present in an OLDER generation keeps its parse', () {
      final out = stripParsedContentKeepFreshest([
        _gen('old',
            createdAt: '2026-01-01T00:00:00.000',
            assets: [_asset('only-old.txt', parsedContent: 'KEEP')]),
        _gen('new',
            createdAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'NEW')]),
      ]);
      expect(_pc(out, 'old', 'only-old.txt'), 'KEEP');
    });

    test('winner with NULL parsedContent does not resurrect older value', () {
      final out = stripParsedContentKeepFreshest([
        _gen('old',
            createdAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'OLD')]),
        _gen('new',
            createdAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: null)]),
      ]);
      expect(_pc(out, 'new', 'x.txt'), isNull);
      expect(_pc(out, 'old', 'x.txt'), isNull);
    });

    test('non-completed generations never claim; older completed one wins',
        () {
      final out = stripParsedContentKeepFreshest([
        _gen('done',
            createdAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'DONE')]),
        _gen('failed',
            status: WebsiteGenStatus.error.index,
            createdAt: '2026-01-05T00:00:00.000',
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
            createdAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'GOOD')]),
        _gen('later-bad', createdAt: '2026-01-05T00:00:00.000', assets: [
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
      final assets =
          ((out.single)['assets'] as List).cast<Map<String, dynamic>>();
      expect(assets[0]['parsedContent'], 'FIRST');
      expect(assets[1]['parsedContent'], isNull);
    });

    test('robust to id-less, assets-less, malformed-date entries', () {
      final out = stripParsedContentKeepFreshest([
        {'tagId': 't1'},
        _gen('a',
            createdAt: 'not-a-date',
            assets: [_asset('x.txt', parsedContent: 'KEEP')]),
        {'id': 'weird', 'assets': 'not-a-list'},
      ]);
      expect(out, hasLength(3));
      expect(_pc(out, 'a', 'x.txt'), 'KEEP');
      expect(out[2]['assets'], 'not-a-list');
    });

    test('missing tagId does not merge distinct groups by accident', () {
      final out = stripParsedContentKeepFreshest([
        _gen('a', tagId: 't-A', assets: [_asset('x.txt', parsedContent: 'A')]),
        {
          'id': 'no-tag',
          'createdAt': '2026-01-09T00:00:00.000',
          'updatedAt': '2026-01-09T00:00:00.000',
          'status': WebsiteGenStatus.completed.index,
          'assets': [_asset('x.txt', parsedContent: 'NOTAG')],
        },
      ]);
      // Different groups ('' vs 't-A') → each keeps its own copy.
      expect(_pc(out, 'a', 'x.txt'), 'A');
      expect(_pc(out, 'no-tag', 'x.txt'), 'NOTAG');
    });

    test('inputs never mutated; output preserves input order', () {
      final input = [
        _gen('b',
            createdAt: '2026-01-05T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'B')]),
        _gen('a',
            createdAt: '2026-01-01T00:00:00.000',
            assets: [_asset('x.txt', parsedContent: 'A')]),
      ];
      final snapshot = jsonEncode(input);
      final out = stripParsedContentKeepFreshest(input);
      expect(jsonEncode(input), snapshot);
      expect(out.map((m) => m['id']).toList(), ['b', 'a']);
    });

    test(
        'ROUND-TRIP PROPERTY: for EVERY website group, websiteCidAssetsByName '
        'resolves identically over stripped and unstripped manifests', () {
      // Deliberately exercises the two review counterexamples: a fileName
      // shared across groups, and createdAt/updatedAt disagreeing.
      final manifest = [
        _gen('a1', tagId: 'A', createdAt: '2026-01-01T00:00:00.000', assets: [
          _asset('logo.png', parsedContent: 'A-logo-old'),
          _asset('only-a1.txt', parsedContent: 'a1-only'),
          _asset('never-uploaded.txt',
              parsedContent: 'nope', uploaded: false),
        ]),
        _gen('a2',
            tagId: 'A',
            createdAt: '2026-01-04T00:00:00.000',
            updatedAt: '2026-01-02T00:00:00.000', // older than a3's
            assets: [
              _asset('logo.png', parsedContent: 'A-logo-new'),
              _asset('b.txt', parsedContent: null),
              _asset('b.txt', parsedContent: 'dup-later'),
            ]),
        _gen('a3',
            tagId: 'A',
            status: WebsiteGenStatus.error.index,
            createdAt: '2026-01-06T00:00:00.000',
            updatedAt: '2026-01-09T00:00:00.000',
            assets: [_asset('logo.png', parsedContent: 'from-failed-run')]),
        _gen('b1', tagId: 'B', createdAt: '2026-01-03T00:00:00.000', assets: [
          _asset('logo.png', parsedContent: 'B-logo'),
        ]),
      ];

      final stripped = stripParsedContentKeepFreshest(manifest);

      for (final tagId in ['A', 'B']) {
        final before = websiteCidAssetsByName(_consumerView(manifest, tagId));
        final after = websiteCidAssetsByName(_consumerView(stripped, tagId));
        expect(after.keys.toSet(), before.keys.toSet(),
            reason: 'group $tagId: resolved file set changed');
        for (final k in before.keys) {
          expect(after[k]!.parsedContent, before[k]!.parsedContent,
              reason: 'group $tagId: parsedContent for $k must survive');
          expect(after[k]!.cid, before[k]!.cid, reason: 'group $tagId: $k cid');
        }
      }
    });
  });
}
