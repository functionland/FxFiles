/**
 * Tests for the stable-link resolver Worker.
 *
 *   node --test cloudflare/ipns-resolver-worker.test.mjs
 *
 * No wrangler, no network: the Worker's outbound calls — w3name, and a read of
 * the published page — are stubbed per-test. Everything else is URL handling.
 *
 * This Worker fronts EVERY shared link the app has ever minted, so the cases
 * below are mostly about what happens when the input is not what we expect —
 * a typo'd `?gw=`, a hostile w3name answer or page, an unreachable upstream.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import worker from './ipns-resolver-worker.js';
import {
  chooseGateway,
  extractPreview,
  hasNonImageRelativeRefs,
  pipelineVersion,
  previewImageUrl,
} from './site-page.js';

const NAME = 'k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8';
const CID = 'bafybeifx7yeb55armcsxwwitkymga5xf53dxiarykms3ygqic223w5sk3m';
const ASSET = 'bafkr4igkfdgbt4wedjgzsalyegd5mcnw7ibgphmh5kg4n5tf7uyrvv74lu';

const FB = (cid = CID, path = '/') => `https://ipfs.filebase.io/ipfs/${cid}${path}`;
const FX = (cid = CID, path = '/') => `https://ipfs.cloud.fx.land/gateway/${cid}${path}`;
const IB = (cid = CID, path = '/') => `https://${cid}.ipfs.inbrowser.link${path}`;

const BROWSER = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

// Page shapes, one per publish pipeline.
const LEGACY_PAGE = `<!doctype html><html><head><title>Old site</title></head><body><img src="https://${ASSET}.ipfs.dweb.link/"></body></html>`;
const V1_IMAGES_ONLY = `<!doctype html><html><head><script data-fx>/* data-fx-try */</script></head><body><img src="../${ASSET}"><script data-fx defer src="../${ASSET}"></script></body></html>`;
const V1_WITH_VIDEO = `<!doctype html><html><head><script>/* data-fx-try */</script></head><body><video><source src="../${ASSET}"></video></body></html>`;
const V2_PAGE = `<!doctype html><html><head><script data-fx data-fx-v="2">/* data-fx-try */</script></head><body><img src="../${ASSET}"></body></html>`;

/**
 * Stub the network. `value` is the w3name record (null => w3name rejects);
 * `page` is what the published-page read returns (null => the read fails).
 */
function stubNetwork(value, page) {
  const original = globalThis.fetch;
  globalThis.fetch = async (input) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url.startsWith('https://name.web3.storage/')) {
      if (value === null) throw new Error('w3name unreachable');
      return new Response(JSON.stringify({ value }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    if (url.startsWith('https://ipfs.filebase.io/ipfs/')) {
      if (page === null) throw new Error('gateway unreachable');
      return new Response(page, { status: 200, headers: { 'content-type': 'text/html' } });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  return () => { globalThis.fetch = original; };
}

async function get(
  path,
  { value = `/ipfs/${CID}`, method = 'GET', ua = BROWSER, page = V2_PAGE } = {},
) {
  const restore = stubNetwork(value, page);
  try {
    const headers = ua === null ? {} : { 'user-agent': ua };
    return await worker.fetch(
      new Request(`https://fxfiles.top${path}`, { method, headers }),
      {},
    );
  } finally {
    restore();
  }
}

const location = (res) => res.headers.get('location');

/** Every unresolvable case ends the same way: a plain 502, never a redirect. */
function assertUnresolved(res) {
  assert.equal(res.status, 502, `expected 502, got ${res.status}`);
  assert.equal(location(res), null, 'a 502 must not carry a Location');
}

// ------------------------------------------------------------- gateway choice

test('defaults to inbrowser', async () => {
  const res = await get(`/w/${NAME}`);
  assert.equal(res.status, 302);
  assert.equal(location(res), IB());
});

test('gw=fx switches to our own gateway', async () => {
  assert.equal(location(await get(`/w/${NAME}?gw=fx`)), FX());
});

test('gw=filebase is honoured for a current page', async () => {
  assert.equal(location(await get(`/w/${NAME}?gw=filebase`)), FB());
});

test('gw=inbrowser is honoured, in subdomain form', async () => {
  const res = await get(`/w/${NAME}?gw=inbrowser`);
  assert.equal(res.status, 302);
  assert.equal(location(res), IB());
});

// dweb is retired and no longer an allowlist key, so links pinned to it fall
// back rather than pointing at a host that is being switched off.
test('the retired gw=dweb falls back to the default', async () => {
  assert.equal(location(await get(`/w/${NAME}?gw=dweb`)), IB());
});

test('an unknown gw key falls back rather than erroring', async () => {
  assert.equal(location(await get(`/w/${NAME}?gw=cloudflare`)), IB());
  assert.equal(location(await get(`/w/${NAME}?gw=bogus`)), IB());
});

// The regression this block exists for. A plain object literal inherits from
// Object.prototype, so a bare `GATEWAYS[gwKey] ||` treats these as a HIT and
// then throws on the undefined `.cid`, turning a typo into a dead link.
for (const key of ['__proto__', 'toString', 'constructor', 'valueOf', 'hasOwnProperty']) {
  test(`?gw=${key} falls back to the default instead of breaking`, async () => {
    const res = await get(`/w/${NAME}?gw=${encodeURIComponent(key)}`);
    assert.equal(res.status, 302);
    assert.equal(location(res), IB());
  });
}

// ------------------------------------------------------ pages that cannot move

/**
 * A published page is immutable, so where it can render is decided here. The
 * sites published before relative assets name dweb.link for every image — an
 * explicit ?gw=filebase on such a link (the app decorated links with it while
 * Filebase was the default) must NOT land them where every image is dead.
 */
test('a pre-relative-assets page goes to inbrowser whatever was asked', async () => {
  for (const gw of ['', '?gw=filebase', '?gw=fx', '?gw=inbrowser']) {
    assert.equal(location(await get(`/w/${NAME}${gw}`, { page: LEGACY_PAGE })), IB(), gw);
  }
});

test('a version-1 page that only needs images goes to inbrowser', async () => {
  assert.equal(location(await get(`/w/${NAME}?gw=filebase`, { page: V1_IMAGES_ONLY })), IB());
});

test('a version-1 page with a video stays on the path gateway', async () => {
  assert.equal(location(await get(`/w/${NAME}?gw=inbrowser`, { page: V1_WITH_VIDEO })), FB());
  assert.equal(location(await get(`/w/${NAME}`, { page: V1_WITH_VIDEO })), FB());
});

test('an unreadable page is served as asked, except on the gateway that just failed it', async () => {
  assert.equal(location(await get(`/w/${NAME}`, { page: null })), IB());
  assert.equal(location(await get(`/w/${NAME}?gw=fx`, { page: null })), FX());
  // Filebase could not serve this page in time, and most pages that exist
  // (pre-relative-assets) cannot render there at all
  assert.equal(location(await get(`/w/${NAME}?gw=filebase`, { page: null })), IB());
  assert.equal(chooseGateway(null, 'filebase'), 'inbrowser');
});

test('a non-HTML entry (a bare file) is served as asked', async () => {
  const restore = (() => {
    const original = globalThis.fetch;
    globalThis.fetch = async (input) => {
      const url = String(input);
      if (url.startsWith('https://name.web3.storage/')) {
        return new Response(JSON.stringify({ value: `/ipfs/${CID}` }), { status: 200 });
      }
      return new Response('%PDF-1.7', { status: 200, headers: { 'content-type': 'application/pdf' } });
    };
    return () => { globalThis.fetch = original; };
  })();
  try {
    const res = await worker.fetch(
      new Request(`https://fxfiles.top/w/${NAME}?gw=filebase`, { headers: { 'user-agent': BROWSER } }),
      {},
    );
    assert.equal(location(res), FB());
  } finally {
    restore();
  }
});

// --------------------------------------------------------- who is asking

// inbrowser is a service-worker gateway: it answers anything that is not a
// browser with 403 or its bootstrap page. Those clients get the path gateway.
test('non-browser clients are sent to the path gateway', async () => {
  for (const ua of [null, 'curl/8.4.0', 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)', 'python-requests/2.31']) {
    assert.equal(location(await get(`/w/${NAME}`, { ua, page: LEGACY_PAGE })), FB(), String(ua));
  }
});

// ---------------------------------------------------------- link previews

test('a preview crawler gets Open Graph tags, not a redirect', async () => {
  const page = `<!doctype html><html><head><title>Final Expense Insurance</title>
    <meta name="description" content="Affordable coverage &amp; peace of mind."></head>
    <body><img src="https://${ASSET}.ipfs.dweb.link/" alt="hero"></body></html>`;
  const res = await get(`/w/${NAME}?gw=inbrowser`, { ua: 'facebookexternalhit/1.1', page });
  assert.equal(res.status, 200);
  assert.equal(location(res), null);
  assert.equal(res.headers.get('content-security-policy'), "default-src 'none'");
  const body = await res.text();
  assert.match(body, /<meta property="og:title" content="Final Expense Insurance">/);
  assert.match(body, /<meta property="og:description" content="Affordable coverage &#38; peace of mind.">/);
  // dweb.link is dead and inbrowser is browser-only: the image goes via the path gateway
  assert.match(body, new RegExp(`<meta property="og:image" content="https://ipfs\\.filebase\\.io/ipfs/${ASSET}">`));
  assert.match(body, new RegExp(`<meta property="og:url" content="https://fxfiles\\.top/w/${NAME}">`));
  assert.match(body, /summary_large_image/);
});

for (const ua of ['Twitterbot/1.0', 'LinkedInBot/1.0 (compatible; Mozilla/5.0)', 'WhatsApp/2.23.20.0 A', 'Slackbot-LinkExpanding 1.0', 'TelegramBot (like TwitterBot)', 'Mozilla/5.0 (compatible; Discordbot/2.0)']) {
  test(`preview for ${ua.split(/[ /]/)[0]}`, async () => {
    const res = await get(`/w/${NAME}`, { ua, page: LEGACY_PAGE });
    assert.equal(res.status, 200);
    assert.match(await res.text(), /og:title" content="Old site"/);
  });
}

test('a preview crawler whose page cannot be read is redirected to the path gateway', async () => {
  const res = await get(`/w/${NAME}`, { ua: 'Twitterbot/1.0', page: null });
  assert.equal(location(res), FB());
});

test('a hostile page cannot inject markup into the preview', async () => {
  const page = `<title>"><script>alert(1)</script></title>
    <meta property="og:description" content="x&quot;&gt;&lt;img src=x onerror=alert(2)&gt;">
    <meta property="og:image" content="javascript:alert(3)">`;
  const body = await (await get(`/w/${NAME}`, { ua: 'Twitterbot/1.0', page })).text();
  assert.ok(!/<script>/i.test(body), body);
  assert.ok(!/<img/i.test(body), body);
  assert.ok(!/javascript:/i.test(body), body);
  // every attribute value stays inside its quotes
  for (const [, content] of body.matchAll(/content="([^"]*)"/g)) assert.ok(!content.includes('<'), content);
});

test('extractPreview prefers declared tags and falls back sensibly', () => {
  assert.deepEqual(
    extractPreview(`<meta property="og:title" content="Declared"><title>Tag</title><meta property="og:image" content="../${ASSET}">`),
    { title: 'Declared', description: '', image: FB(ASSET, '') },
  );
  const fallback = extractPreview(`<h1>Heading <em>only</em></h1><script>var p = "<p>not prose at all, this is inside a script tag</p>";</script><p>short</p><p>This paragraph is long enough to be a useful description of the site.</p><img src="data:image/png;base64,AAAA"><img src="https://example.com/a.png">`);
  assert.equal(fallback.title, 'Heading only');
  assert.equal(fallback.description, 'This paragraph is long enough to be a useful description of the site.');
  assert.equal(fallback.image, 'https://example.com/a.png');
});

test('previewImageUrl re-points every CID shape at the path gateway', () => {
  const want = FB(ASSET, '');
  for (const raw of [`https://${ASSET}.ipfs.dweb.link/`, `https://${ASSET}.ipfs.inbrowser.link/`, `https://ipfs.cloud.fx.land/gateway/${ASSET}`, `../${ASSET}`, ASSET]) {
    assert.equal(previewImageUrl(raw), want, raw);
  }
  for (const raw of ['data:image/png;base64,AA', 'http://example.com/a.png', 'javascript:alert(1)', 'not a url', '']) {
    assert.equal(previewImageUrl(raw), null, raw);
  }
});

test('pipeline versions and routing decisions', () => {
  assert.equal(pipelineVersion(LEGACY_PAGE), 0);
  assert.equal(pipelineVersion(V1_IMAGES_ONLY), 1);
  assert.equal(pipelineVersion(V2_PAGE), 2);
  assert.equal(hasNonImageRelativeRefs(V1_IMAGES_ONLY), false);
  assert.equal(hasNonImageRelativeRefs(V1_WITH_VIDEO), true);
  assert.equal(hasNonImageRelativeRefs(`<a href="../${ASSET}/">page</a>`), true);
  assert.equal(hasNonImageRelativeRefs(`<div style="background:url(../${ASSET})"></div>`), true);
  assert.equal(hasNonImageRelativeRefs(`<img src="../${ASSET}" srcset="../${ASSET} 2x">`), true);
  assert.equal(chooseGateway(V2_PAGE, 'fx'), 'fx');
  assert.equal(chooseGateway(V2_PAGE, 'filebase'), 'filebase');
});

// ------------------------------------------------ CID / hostname hazards

// The hazard a subdomain gateway brings: the CID lands in the HOSTNAME, where
// case is lost and labels cap at 63 chars. Serving a mangled hostname would
// silently fetch a DIFFERENT cid, so these fall back to path-style instead.
test('a CIDv0 on a subdomain gateway falls back to path-style', async () => {
  const v0 = 'QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG';
  const loc = location(await get(`/w/${NAME}`, { value: `/ipfs/${v0}` }));
  assert.equal(loc, FB(v0));
  assert.ok(loc.includes(v0), `case-mangled: ${loc}`);
  // even a legacy page, which would otherwise be sent to inbrowser
  assert.equal(location(await get(`/w/${NAME}`, { value: `/ipfs/${v0}`, page: LEGACY_PAGE })), FB(v0));
});

test('an over-63-char CID on a subdomain gateway falls back too', async () => {
  const long = 'b' + 'a'.repeat(75);
  assert.equal(location(await get(`/w/${NAME}`, { value: `/ipfs/${long}` })), FB(long));
});

test('a normal CIDv1 uses the subdomain form', async () => {
  assert.equal(location(await get(`/w/${NAME}?gw=inbrowser`)), IB());
});

test('a subpath is carried through', async () => {
  assert.equal(location(await get(`/w/${NAME}/about/page.html`)), IB(CID, '/about/page.html'));
  assert.equal(location(await get(`/w/${NAME}/about/page.html?gw=fx`)), FX(CID, '/about/page.html'));
});

test('gw is stripped from the forwarded query, other params survive', async () => {
  const loc = location(await get(`/w/${NAME}?utm=x&gw=fx&b=2`));
  assert.ok(!loc.includes('gw='), `gw leaked into ${loc}`);
  assert.ok(loc.includes('utm=x') && loc.includes('b=2'));
});

test('a query with no gw is forwarded untouched', async () => {
  assert.equal(location(await get(`/w/${NAME}?utm=x`)), `${IB()}?utm=x`);
});

// A CID is interpolated straight into the redirect target, so a hostile or
// compromised w3name answer must not be able to smuggle a host separator in.
for (const evil of [
  'evil.com/#',
  'abc@evil.com',
  'abc\\evil.com',
  'abc.evil.com',
  '../../etc',
  'short',
]) {
  test(`rejects a non-CID w3name value: ${JSON.stringify(evil)}`, async () => {
    const res = await get(`/w/${NAME}`, { value: `/ipfs/${evil}` });
    assertUnresolved(res);
  });
}

// A record may point INTO a directory. Dropping that suffix would serve the
// wrong page. (This app publishes a bare /ipfs/<cid>, but the Worker resolves
// any name.)
test('an inner path in the IPNS record is preserved', async () => {
  // No trailing slash appended: `/site/index.html/` is not the same resource
  // as the file, and a bare `/` from the visitor means "whatever the record
  // points at".
  assert.equal(
    location(await get(`/w/${NAME}`, { value: `/ipfs/${CID}/site/index.html` })),
    IB(CID, '/site/index.html'),
  );
});

test('an inner path composes with the visitor subpath', async () => {
  assert.equal(
    location(await get(`/w/${NAME}/a.html`, { value: `/ipfs/${CID}/site` })),
    IB(CID, '/site/a.html'),
  );
});

// `inner` is the one piece of the Location that is raw text from an upstream
// rather than a URL-normalized value, so it is the only CRLF-injection seam.
test('a control character in the record is refused, not put in a header', async () => {
  for (const evil of ['/a\r\nX-Injected: 1', '/a\nB', '/a\0b']) {
    const res = await get(`/w/${NAME}`, { value: `/ipfs/${CID}${evil}` });
    assertUnresolved(res);
    assert.equal(res.headers.get('x-injected'), null);
  }
});

test('502s when w3name is unreachable, rather than redirecting to a dead host', async () => {
  const res = await get(`/w/${NAME}`, { value: null });
  assertUnresolved(res);
  assert.match(await res.text(), /unreachable/i);
});

test('502s when the record is not an /ipfs/ value', async () => {
  assertUnresolved(await get(`/w/${NAME}`, { value: '/ipns/somethingelse' }));
});

test('implausible names are rejected before any upstream call', async () => {
  for (const bad of ['notak51name', 'k' + 'z'.repeat(200), 'K51UPPER']) {
    const res = await get(`/w/${encodeURIComponent(bad)}`);
    assert.equal(res.status, 400, `expected 400 for ${bad}`);
  }
  // `..` never reaches the name check: `new URL()` collapses dot segments, so
  // /w/.. is already `/` by the time the Worker looks at it and misses the
  // route entirely. Rejected either way — just by a different branch.
  assert.equal((await get('/w/..')).status, 404);
});

test('a path outside /w/ is a 404', async () => {
  assert.equal((await get('/')).status, 404);
  assert.equal((await get('/w/')).status, 404);
});

test('non-GET/HEAD is refused', async () => {
  const res = await get(`/w/${NAME}`, { method: 'POST' });
  assert.equal(res.status, 405);
  assert.equal(res.headers.get('allow'), 'GET, HEAD');
});

/**
 * Generated sites reference their assets DOCUMENT-RELATIVELY (`../<cid>`) so
 * they render on whatever PATH gateway serves them. That makes two properties
 * of this Worker load-bearing:
 *
 *  1. The redirect target must keep its TRAILING SLASH. From `/ipfs/<page>/`
 *     the reference resolves to `/ipfs/<cid>`; from `/ipfs/<page>` it resolves
 *     to `/<cid>` and 404s.
 *  2. It must REDIRECT browsers, never proxy the site. If this Worker served
 *     the page itself, the document URL would be `fxfiles.top/w/<name>` and
 *     `../<cid>` would resolve back into the Worker instead of reaching a
 *     gateway at all. (Crawlers get a preview page that references nothing
 *     relatively.)
 */
test('keeps the trailing slash — relative asset refs depend on it', async () => {
  const loc = location(await get(`/w/${NAME}?gw=filebase`));
  assert.ok(loc.endsWith('/'), `no trailing slash: ${loc}`);
  // and the reference a generated page carries resolves back onto the gateway
  assert.equal(new URL(`../${CID}`, loc).href, FB(CID, '').replace(/\/$/, ''));
});

test('redirects are 302, short-cached, and vary by client', async () => {
  const res = await get(`/w/${NAME}`);
  assert.equal(res.status, 302);
  assert.match(res.headers.get('cache-control'), /max-age=30/);
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
  assert.equal(res.headers.get('vary'), 'User-Agent');
});

// The Location header is built by string interpolation, so prove the pieces
// that come from the caller cannot break out of it.
test('no CR/LF can reach the Location header', async () => {
  const res = await get(`/w/${NAME}/a%0d%0aX-Injected:%201?gw=fx`);
  const loc = location(res);
  assert.ok(!/[\r\n]/.test(loc), `raw CRLF in Location: ${JSON.stringify(loc)}`);
  assert.equal(res.headers.get('x-injected'), null);
});

test('a subpath cannot move the redirect off a gateway host', async () => {
  // Either the request is refused outright or it lands on a gateway host —
  // never anywhere else. `/a/../../evil` takes the first branch: URL
  // normalization rewrites it to /w/evil, whose "name" fails the k51 check.
  const allowed = new Set(['ipfs.filebase.io', 'ipfs.cloud.fx.land', `${CID}.ipfs.inbrowser.link`]);
  for (const p of ['//evil.com', '/..%2f..%2fevil', '/a/../../evil', '/\\evil.com']) {
    const res = await get(`/w/${NAME}${p}`);
    const loc = location(res);
    if (loc === null) {
      assert.ok(res.status >= 400, `no redirect but status ${res.status} for ${p}`);
      continue;
    }
    assert.ok(allowed.has(new URL(loc).host), `escaped via ${p}: ${loc}`);
  }
});
