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
}
