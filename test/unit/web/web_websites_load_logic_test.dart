import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/web/services/web_websites_load_logic.dart';

Uint8List _blob(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, dynamic> _gen(
  String id, {
  String tagId = 't1',
  String updatedAt = '2026-01-02T00:00:00.000',
  List<Map<String, dynamic>> assets = const [],
}) =>
    {
      'id': id,
      'tagId': tagId,
      'tagName': 'websites-demo',
      'prompt': 'p',
      'status': WebsiteGenStatus.completed.index,
      'createdAt': '2026-01-01T00:00:00.000',
      'updatedAt': updatedAt,
      'assets': assets,
    };

Map<String, dynamic> _asset(String name, {String? parsedContent}) => {
      'localPath': '',
      'fileName': name,
      'type': 'document',
      'cid': 'bafy-$name',
      'uploaded': true,
      'parsedContent': parsedContent,
    };

void main() {
  group('decodeGenerationsBlobs', () {
    test('merges blobs, first blob (v8) wins an id, sorts updatedAt desc',
        () async {
      final v8 = _blob({
        'generations': [
          _gen('a', updatedAt: '2026-01-05T00:00:00.000'),
          _gen('b', updatedAt: '2026-01-03T00:00:00.000'),
        ],
      });
      final legacy = _blob({
        'generations': [
          // Same id as v8's 'a' but a different stamp — must LOSE.
          _gen('a', updatedAt: '2026-01-01T00:00:00.000'),
          _gen('c', updatedAt: '2026-01-04T00:00:00.000'),
        ],
      });
      final out = await decodeGenerationsBlobs([v8, legacy]);
      expect(out.map((g) => g.id).toList(), ['a', 'c', 'b']);
      expect(out.first.updatedAt.toIso8601String(),
          '2026-01-05T00:00:00.000');
    });

    test('a malformed entry aborts the rest of ITS blob only', () async {
      final bad = _blob({
        'generations': [
          _gen('a'),
          {'id': null}, // fromJson throws on null id
          _gen('never-reached'),
        ],
      });
      final good = _blob({
        'generations': [_gen('b')],
      });
      final out = await decodeGenerationsBlobs([bad, good]);
      expect(out.map((g) => g.id).toSet(), {'a', 'b'});
    });

    test('non-JSON blob skipped without dropping other blobs', () async {
      final junk = Uint8List.fromList(utf8.encode('not json'));
      final good = _blob({
        'generations': [_gen('a')],
      });
      final out = await decodeGenerationsBlobs([junk, good]);
      expect(out.single.id, 'a');
    });

    test('dropParsedContent nulls every asset; default keeps it', () async {
      final blob = _blob({
        'generations': [
          _gen('a', assets: [
            _asset('x.txt', parsedContent: 'hello'),
            _asset('y.txt', parsedContent: 'world'),
          ]),
        ],
      });
      final kept = await decodeGenerationsBlobs([blob]);
      expect(kept.single.assets.map((a) => a.parsedContent).toList(),
          ['hello', 'world']);
      final dropped =
          await decodeGenerationsBlobs([blob], dropParsedContent: true);
      expect(dropped.single.assets.map((a) => a.parsedContent).toList(),
          [null, null]);
      // Everything else survives the strip untouched.
      expect(dropped.single.assets.first.cid, 'bafy-x.txt');
      expect(dropped.single.assets.first.uploaded, isTrue);
    });

    test('yields do not change results for large inputs', () async {
      final blob = _blob({
        'generations': [
          for (var i = 0; i < 40; i++)
            _gen('g$i',
                updatedAt:
                    '2026-01-01T00:00:${(i % 60).toString().padLeft(2, '0')}.000'),
        ],
      });
      final out = await decodeGenerationsBlobs([blob], yieldEvery: 3);
      expect(out.length, 40);
    });

    /// The website DETAIL screen froze on open because it decoded and
    /// RETAINED `parsedContent` for every group in the vault (tens of MB
    /// of strings on the main thread) before filtering down to the one
    /// group it shows. It still needs the parses for THAT group — its
    /// recreate flow reuses them — so the fix is per-tag, not all-or-nothing.
    test('keepParsedForTagId retains parses for that tag only', () async {
      final blob = _blob({
        'generations': [
          _gen('mine', tagId: 'wanted', assets: [
            _asset('a.html', parsedContent: 'keep me'),
          ]),
          _gen('other', tagId: 'unwanted', assets: [
            _asset('b.html', parsedContent: 'drop me'),
          ]),
        ],
      });
      final out =
          await decodeGenerationsBlobs([blob], keepParsedForTagId: 'wanted');
      final mine = out.firstWhere((g) => g.id == 'mine');
      final other = out.firstWhere((g) => g.id == 'other');
      expect(mine.assets.single.parsedContent, 'keep me');
      expect(other.assets.single.parsedContent, isNull,
          reason: 'other groups must not stay resident');
      // Nothing is dropped from the RESULT — only the heavy field is.
      expect(out.length, 2);
    });

    test('dropParsedContent wins over keepParsedForTagId', () async {
      final blob = _blob({
        'generations': [
          _gen('mine', tagId: 'wanted', assets: [
            _asset('a.html', parsedContent: 'x'),
          ]),
        ],
      });
      final out = await decodeGenerationsBlobs([blob],
          dropParsedContent: true, keepParsedForTagId: 'wanted');
      expect(out.single.assets.single.parsedContent, isNull);
    });

    test('keepParsedForTagId null keeps everything (unchanged default)',
        () async {
      final blob = _blob({
        'generations': [
          _gen('a', tagId: 't1', assets: [_asset('a.html', parsedContent: 'p')]),
          _gen('b', tagId: 't2', assets: [_asset('b.html', parsedContent: 'q')]),
        ],
      });
      final out = await decodeGenerationsBlobs([blob]);
      expect(out.map((g) => g.assets.single.parsedContent).toList(),
          containsAll(<String>['p', 'q']));
    });
  });

  group('decodePointersBlobs', () {
    Map<String, dynamic> pointer(String tagId, {String name = 'k51abc'}) => {
          'tagId': tagId,
          'ipnsName': name,
          'frontDoorUrl': 'https://fxfiles.top/w/$name',
          'ipnsGatewayUrl': 'https://$name.ipns.dweb.link/',
          'createdAt': '2026-01-01T00:00:00.000',
          'updatedAt': '2026-01-01T00:00:00.000',
        };

    test('list shape parses; first blob wins a tagId', () async {
      final v8 = _blob({
        'pointers': [pointer('t1', name: 'k51-v8')],
      });
      final legacy = _blob({
        'pointers': [pointer('t1', name: 'k51-old'), pointer('t2')],
      });
      final out = await decodePointersBlobs([v8, legacy]);
      expect(out.keys.toSet(), {'t1', 't2'});
      expect(out['t1']!.ipnsName, 'k51-v8');
    });

    test('legacy map shape falls back to j.values', () async {
      final blob = _blob({
        't1': pointer('t1'),
        't2': pointer('t2'),
      });
      final out = await decodePointersBlobs([blob]);
      expect(out.keys.toSet(), {'t1', 't2'});
    });

    test('malformed entries skipped, malformed blob keeps accumulated',
        () async {
      final ok = _blob({
        'pointers': [
          pointer('t1'),
          {'tagId': 't-broken'}, // missing required fields → skipped
        ],
      });
      final junk = Uint8List.fromList(utf8.encode('not json'));
      final neverReached = _blob({
        'pointers': [pointer('t3')],
      });
      // junk aborts the remaining blobs (documented outer-catch shape)
      // but keeps what already accumulated.
      final out = await decodePointersBlobs([ok, junk, neverReached]);
      expect(out.keys.toSet(), {'t1'});
    });
  });
}
