import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';

/// A published site references its assets relatively (`../<cid>`), which only
/// resolves from the SLASHED page URL. On Filebase (the default gateway) the
/// inline fallback that would rescue an unslashed page is blocked by CSP, so a
/// missing slash is a broken image. Every link to a site page goes through
/// [WebsiteGeneration.gatewayUrl]; these pin that it always carries the slash.
void main() {
  const cid = 'bafkr4icktd4n2vmazsp7zv5qx5z5gcumnqr5il6yo7fjxubwtp2nizrikq';

  WebsiteGeneration gen({String? resultCid, String? resultGatewayUrl}) =>
      WebsiteGeneration(
        id: 'g1',
        tagId: 't1',
        tagName: 'Site',
        prompt: 'p',
        status: WebsiteGenStatus.completed,
        resultCid: resultCid,
        resultGatewayUrl: resultGatewayUrl,
        createdAt: DateTime(2026, 9, 16),
        updatedAt: DateTime(2026, 9, 16),
      );

  tearDown(() =>
      IpfsGatewayHelper.updateCache(IpfsGatewayHelper.defaultTemplate));

  test('path-style gateway (Filebase, the default) gets a trailing slash', () {
    IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
    expect(gen(resultCid: cid).gatewayUrl,
        'https://ipfs.filebase.io/ipfs/$cid/');
  });

  test('the relative asset ref resolves onto the gateway from that URL', () {
    IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
    final page = Uri.parse(gen(resultCid: cid).gatewayUrl!);
    const asset = 'bafkr4ia4svyucgp4yjjcnku2qc6nvhlur6tghwsdk3o5cx5ggoa2s6hzaa';
    expect(page.resolve('../$asset').toString(),
        'https://ipfs.filebase.io/ipfs/$asset');
  });

  test('subdomain-style gateway is unchanged — it already ends in a slash', () {
    IpfsGatewayHelper.updateCache(IpfsGatewayHelper.inbrowserTemplate);
    expect(gen(resultCid: cid).gatewayUrl,
        'https://$cid.ipfs.inbrowser.link/');
  });

  test('a custom path template without a trailing slash still gets one', () {
    IpfsGatewayHelper.updateCache('https://my-host/ipfs');
    expect(gen(resultCid: cid).gatewayUrl, 'https://my-host/ipfs/$cid/');
  });

  test('never doubles the slash', () {
    IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
    expect(gen(resultCid: cid).gatewayUrl!.endsWith('//'), isFalse);
  });

  test('a legacy slashed resultGatewayUrl still yields the right CID', () {
    IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
    expect(
      gen(resultGatewayUrl: 'https://ipfs.cloud.fx.land/gateway/$cid/')
          .gatewayUrl,
      'https://ipfs.filebase.io/ipfs/$cid/',
    );
  });

  test('no CID means no link', () {
    expect(gen().gatewayUrl, isNull);
  });

  // File shares use the same template helper but are files, not pages, and
  // must stay bare. The slash is deliberately confined to site links.
  test('public FILE-share URLs are NOT slashed', () {
    IpfsGatewayHelper.updateCache(IpfsGatewayHelper.filebaseTemplate);
    expect(publicGatewayUrlForCid(cid), 'https://ipfs.filebase.io/ipfs/$cid');
  });
}
