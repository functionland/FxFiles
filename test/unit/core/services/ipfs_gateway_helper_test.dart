import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/services/ipfs_gateway_helper.dart';

/// Covers everything in [IpfsGatewayHelper] that does NOT touch storage.
/// `init()` is the only member that reads SecureStorage; the template cache
/// is driven here through `updateCache`, exactly as the settings screen does
/// after a save.
void main() {
  // Each group leaves the cache on the default so ordering cannot matter.
  tearDown(() => IpfsGatewayHelper.updateCache(IpfsGatewayHelper.defaultTemplate));

  group('buildUrl', () {
    const cid = 'bafybeifx7yeb55armcsxwwitkymga5xf53dxiarykms3ygqic223w5sk3m';

    test('substitutes {cid} for subdomain-style templates', () {
      expect(
        IpfsGatewayHelper.buildUrl(IpfsGatewayHelper.defaultTemplate, cid),
        'https://$cid.ipfs.dweb.link/',
      );
    });

    test('appends the cid for path-style templates', () {
      expect(
        IpfsGatewayHelper.buildUrl(IpfsGatewayHelper.filebaseTemplate, cid),
        'https://ipfs.filebase.io/ipfs/$cid',
      );
    });

    test('adds the missing separator on a path template without one', () {
      expect(
        IpfsGatewayHelper.buildUrl('https://my-host/ipfs', cid),
        'https://my-host/ipfs/$cid',
      );
    });

    test('buildUrlForCid follows the cached template', () {
      IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
      expect(
        IpfsGatewayHelper.buildUrlForCid(cid),
        'https://ipfs.filebase.io/ipfs/$cid',
      );
    });
  });

  group('updateCache', () {
    test('trims, and falls back to the default on empty', () {
      IpfsGatewayHelper.updateCache('  ${IpfsGatewayHelper.filebaseTemplate}  ');
      expect(IpfsGatewayHelper.cachedTemplate,
          IpfsGatewayHelper.filebaseTemplate);

      IpfsGatewayHelper.updateCache('   ');
      expect(IpfsGatewayHelper.cachedTemplate,
          IpfsGatewayHelper.defaultTemplate);
    });
  });

  group('presetLabelFor', () {
    test('names the two presets and nothing else', () {
      expect(IpfsGatewayHelper.presetLabelFor(IpfsGatewayHelper.defaultTemplate),
          'dweb.link');
      expect(
          IpfsGatewayHelper.presetLabelFor(IpfsGatewayHelper.filebaseTemplate),
          'Filebase');
      expect(IpfsGatewayHelper.presetLabelFor('https://my-host/ipfs/'), isNull);
    });

    test('tolerates surrounding whitespace', () {
      expect(
        IpfsGatewayHelper.presetLabelFor(
            '  ${IpfsGatewayHelper.filebaseTemplate} '),
        'Filebase',
      );
    });

    test('every preset value round-trips back to its own label', () {
      IpfsGatewayHelper.presets.forEach((label, template) {
        expect(IpfsGatewayHelper.presetLabelFor(template), label);
      });
    });
  });

  group('frontDoorGatewayKey', () {
    test('maps the presets to the resolver keys', () {
      expect(IpfsGatewayHelper.frontDoorGatewayKey(
          IpfsGatewayHelper.defaultTemplate), 'dweb');
      expect(IpfsGatewayHelper.frontDoorGatewayKey(
          IpfsGatewayHelper.filebaseTemplate), 'filebase');
    });

    test('a custom gateway has no key — the resolver allowlists, by design',
        () {
      expect(IpfsGatewayHelper.frontDoorGatewayKey('https://my-host/ipfs/'),
          isNull);
    });

    test('reads the cache when no template is passed', () {
      IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
      expect(IpfsGatewayHelper.frontDoorGatewayKey(), 'filebase');
    });

    // The worker's allowlist is the other half of this contract: a key here
    // that it does not know would silently fall back to its default.
    test('only ever emits keys the worker allowlists', () {
      const workerKeys = {'dweb', 'filebase'};
      for (final template in IpfsGatewayHelper.presets.values) {
        expect(workerKeys, contains(
            IpfsGatewayHelper.frontDoorGatewayKey(template)));
      }
    });
  });

  group('decorateFrontDoorUrl', () {
    const link = 'https://fxfiles.top/w/k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i';

    test('appends ?gw= for a preset gateway', () {
      IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
      expect(IpfsGatewayHelper.decorateFrontDoorUrl(link), '$link?gw=filebase');
    });

    test('appends the dweb key explicitly, so the link is self-describing',
        () {
      expect(IpfsGatewayHelper.decorateFrontDoorUrl(link), '$link?gw=dweb');
    });

    test('uses & when the link already carries a query', () {
      IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
      expect(
        IpfsGatewayHelper.decorateFrontDoorUrl('$link?utm=x'),
        '$link?utm=x&gw=filebase',
      );
    });

    test('leaves the link untouched for a custom gateway', () {
      IpfsGatewayHelper.updateCache('https://my-host/ipfs/');
      expect(IpfsGatewayHelper.decorateFrontDoorUrl(link), link);
    });

    test('leaves an empty link empty rather than emitting a bare query', () {
      IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
      expect(IpfsGatewayHelper.decorateFrontDoorUrl(''), '');
    });

    test('honours an explicit template over the cache', () {
      IpfsGatewayHelper.updateCache(IpfsGatewayHelper.defaultTemplate);
      expect(
        IpfsGatewayHelper.decorateFrontDoorUrl(link,
            template: IpfsGatewayHelper.filebaseTemplate),
        '$link?gw=filebase',
      );
    });

    test('is not applied twice by accident', () {
      IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
      final once = IpfsGatewayHelper.decorateFrontDoorUrl(link);
      // Decorating an already-decorated link appends a second key. The
      // resolver reads the FIRST `gw`, so this stays correct — but it is
      // ugly, and a sign a caller decorated a value that was already
      // decorated. Pinned so the shape is a deliberate choice, not a
      // surprise.
      expect(IpfsGatewayHelper.decorateFrontDoorUrl(once),
          '$link?gw=filebase&gw=filebase');
    });
  });
}
