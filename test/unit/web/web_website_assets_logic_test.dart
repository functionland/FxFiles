import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/web/services/web_website_assets_logic.dart';

WebsiteAsset _asset(String name,
        {String? cid, bool uploaded = false, String? url}) =>
    WebsiteAsset(
      localPath: '/x/$name',
      fileName: name,
      type: 'image',
      cid: cid,
      gatewayUrl: url,
      uploaded: uploaded,
    );

WebsiteGeneration _gen({
  required String id,
  required List<WebsiteAsset> assets,
  WebsiteGenStatus status = WebsiteGenStatus.completed,
  required DateTime createdAt,
}) =>
    WebsiteGeneration(
      id: id,
      tagId: 't',
      tagName: 'w',
      prompt: '',
      status: status,
      createdAt: createdAt,
      updatedAt: createdAt,
      totalAssets: assets.length,
      uploadedAssets: assets.where((a) => a.uploaded).length,
      assets: assets,
    );

GroupTaggedFile _tf(String name, {bool hasRemoteKey = false}) =>
    (fileName: name, hasRemoteKey: hasRemoteKey);

void main() {
  final t3 = DateTime.utc(2026, 6, 3);
  final t1 = DateTime.utc(2026, 6, 1);

  group('websiteCidAssetsByName', () {
    test('collects uploaded+cid assets across ALL completed generations', () {
      final gens = [
        _gen(id: 'g3', createdAt: t3, assets: [_asset('a', cid: 'A3', uploaded: true)]),
        _gen(id: 'g1', createdAt: t1, assets: [
          _asset('a', cid: 'A1', uploaded: true),
          _asset('b', cid: 'B1', uploaded: true),
        ]),
      ];
      final map = websiteCidAssetsByName(gens);
      expect(map.keys.toSet(), {'a', 'b'});
      // newest-first → first occurrence (g3) wins for 'a'.
      expect(map['a']!.cid, 'A3');
      expect(map['b']!.cid, 'B1');
    });

    test('skips non-uploaded / cid-less assets and non-completed gens', () {
      final gens = [
        _gen(id: 'g2', createdAt: t3, status: WebsiteGenStatus.generating, assets: [
          _asset('x', cid: 'X', uploaded: true), // ignored — gen not completed
        ]),
        _gen(id: 'g1', createdAt: t1, assets: [
          _asset('y', uploaded: false), // skipped by a cap → not CID-backed
          _asset('z', cid: '', uploaded: true), // empty cid
          _asset('ok', cid: 'OK', uploaded: true),
        ]),
      ];
      final map = websiteCidAssetsByName(gens);
      expect(map.keys.toSet(), {'ok'});
    });
  });

  group('resolveWebsiteGroupAssets', () {
    final cidByName = <String, ResolvedWebsiteAsset>{
      'a': (fileName: 'a', cid: 'A', gatewayUrl: 'https://a', note: ''),
      'b': (fileName: 'b', cid: 'B', gatewayUrl: null, note: 'hi'),
    };

    test('CID-backed current files are reusable; uncovered + no-remoteKey are app-only', () {
      final r = resolveWebsiteGroupAssets(
        taggedFiles: [_tf('a'), _tf('b'), _tf('c')],
        cidByName: cidByName,
      );
      expect(r.reusable.map((x) => x.fileName).toList(), ['a', 'b']);
      expect(r.appOnly, ['c']); // no cid, no remoteKey → on a device
    });

    test('a file with a private cloud copy but no public CID is omitted (not app-only)', () {
      final r = resolveWebsiteGroupAssets(
        taggedFiles: [_tf('d', hasRemoteKey: true)],
        cidByName: cidByName,
      );
      expect(r.reusable, isEmpty);
      expect(r.appOnly, isEmpty); // has a cloud copy → not "on a device"
    });

    test('dedupes by name, preserving group order', () {
      final r = resolveWebsiteGroupAssets(
        taggedFiles: [_tf('b'), _tf('a'), _tf('a')],
        cidByName: cidByName,
      );
      expect(r.reusable.map((x) => x.fileName).toList(), ['b', 'a']);
    });

    test('REGRESSION #44: an asset uploaded in an EARLIER generation '
        '(skipped in the latest) is still reusable', () {
      // Latest run skipped "a" (cap/failure → uploaded:false); an earlier run
      // uploaded it successfully. The old latest-only code flagged it
      // "on a device"; the union must keep it reusable.
      final gens = [
        _gen(id: 'gLatest', createdAt: t3, assets: [_asset('a', uploaded: false)]),
        _gen(id: 'gOld', createdAt: t1, assets: [_asset('a', cid: 'A1', uploaded: true)]),
      ];
      final map = websiteCidAssetsByName(gens);
      final r = resolveWebsiteGroupAssets(
        taggedFiles: [_tf('a')],
        cidByName: map,
      );
      expect(r.reusable.single.fileName, 'a');
      expect(r.reusable.single.cid, 'A1');
      expect(r.appOnly, isEmpty);
    });

    test('removed-from-group file is NOT resurrected as reusable', () {
      // 'old' has a CID in a generation but is no longer a current group file.
      final r = resolveWebsiteGroupAssets(
        taggedFiles: [_tf('a')],
        cidByName: {
          'a': (fileName: 'a', cid: 'A', gatewayUrl: null, note: ''),
          'old': (fileName: 'old', cid: 'OLD', gatewayUrl: null, note: ''),
        },
      );
      expect(r.reusable.map((x) => x.fileName).toList(), ['a']); // no 'old'
    });
  });

  group('sanitizeWebsiteName', () {
    test('matches the native asset-prefix transform', () {
      expect(sanitizeWebsiteName('Real Estate'), 'Real_Estate');
      expect(sanitizeWebsiteName('My-Site_1'), 'My-Site_1');
      expect(sanitizeWebsiteName('a b/c.d'), 'a_b_c_d');
    });
  });

  group('parseWebsiteAssetCids', () {
    const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>website-assets</Name>
  <Prefix>Real_Estate/</Prefix>
  <Contents><Key>Real_Estate/</Key><ETag>"folder"</ETag></Contents>
  <Contents><Key>Real_Estate/Mls-sample.webp</Key><ETag>"bafk1"</ETag></Contents>
  <Contents><Key>Real_Estate/Screenshot.Chrome.png</Key><ETag>"bafy2"</ETag></Contents>
  <Contents><Key>Other_Site/x.jpg</Key><ETag>"bafk9"</ETag></Contents>
</ListBucketResult>''';

    test('extracts {fileName: cid}, strips quotes/prefix, skips folder + other prefixes', () {
      final m = parseWebsiteAssetCids(xml, 'Real_Estate/');
      expect(m, {
        'Mls-sample.webp': 'bafk1',
        'Screenshot.Chrome.png': 'bafy2',
      });
    });

    test('non-matching prefix → empty', () {
      expect(parseWebsiteAssetCids(xml, 'Nope/'), isEmpty);
    });
  });

  group('mergeAuthoritativeCids', () {
    test('website-assets CID wins; manifest note preserved; new keys added', () {
      final manifest = <String, ResolvedWebsiteAsset>{
        'a': (fileName: 'a', cid: 'OLD', gatewayUrl: 'u', note: 'hello'),
        'c': (fileName: 'c', cid: 'CID_C', gatewayUrl: null, note: ''),
      };
      final m = mergeAuthoritativeCids(manifest, {'a': 'NEW', 'b': 'CID_B'});
      expect(m['a']!.cid, 'NEW'); // authoritative override
      expect(m['a']!.note, 'hello'); // note preserved
      expect(m['b']!.cid, 'CID_B'); // new key from website-assets
      expect(m['c']!.cid, 'CID_C'); // manifest-only key untouched
    });
  });
}
