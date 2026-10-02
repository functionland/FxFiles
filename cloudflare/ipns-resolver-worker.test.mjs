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
 * a stray `?gw=`, a hostile w3name answer or page, an unreachable upstream.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

import worker from './ipns-resolver-worker.js';
import {
  BLOCKED_TTL_MS,
  CHECK,
  INBROWSER_PROBE_URLS,
  INBROWSER_ROUTER_URLS,
  INBROWSER_SITE_SOURCE,
  jsonForScriptBlock,
  LAUNCHER_SCRIPT,
  LAUNCHER_STYLE,
  ORBITOR_ORIGIN,
  REACHABLE_TTL_MS,
} from './launcher.js';
import {
  browserChain,
  extractPreview,
  hasNonImageRelativeRefs,
  pipelineVersion,
  previewImageUrl,
  provenNotAnImage,
} from './site-page.js';

const NAME = 'k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8';
const CID = 'bafybeifx7yeb55armcsxwwitkymga5xf53dxiarykms3ygqic223w5sk3m';
const ASSET = 'bafkr4igkfdgbt4wedjgzsalyegd5mcnw7ibgphmh5kg4n5tf7uyrvv74lu';

const FB = (cid = CID, path = '/') => `https://ipfs.filebase.io/ipfs/${cid}${path}`;
const ORB = (cid = CID, path = '/') => `${ORBITOR_ORIGIN}/ipfs/${cid}${path}`;
const IB = (cid = CID, path = '/') => `https://${cid}.ipfs.inbrowser.link${path}`;

const BROWSER = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

// Page shapes, one per publish pipeline.
const LEGACY_PAGE = `<!doctype html><html><head><title>Old site</title></head><body><img src="https://${ASSET}.ipfs.dweb.link/"></body></html>`;
const V1_IMAGES_ONLY = `<!doctype html><html><head><script data-fx>/* data-fx-try */</script></head><body><img src="../${ASSET}"><script data-fx defer src="../${ASSET}"></script></body></html>`;
const V1_WITH_VIDEO = `<!doctype html><html><head><script>/* data-fx-try */</script></head><body><video><source src="../${ASSET}"></video></body></html>`;
const V2_PAGE = `<!doctype html><html><head><script data-fx data-fx-v="2">/* data-fx-try */</script></head><body><img src="../${ASSET}"></body></html>`;

const FULL_CHAIN = (cid = CID, path = '/') => [IB(cid, path), ORB(cid, path), FB(cid, path)];

/**
 * Stub the network. `value` is the w3name record (null => w3name rejects);
 * `page` is what reading the record's CID returns (null => the read fails).
 * Any other CID is an image, unless listed in `htmlCids`.
 */
const FB_BASE = 'https://ipfs.filebase.io/ipfs/';
const FX_BASE = 'https://ipfs.cloud.fx.land/gateway/';

function stubNetwork(value, page, htmlCids = [], unhappyCids = [], pageSources = ['filebase', 'fx']) {
  const original = globalThis.fetch;
  const pageCid = typeof value === 'string' ? value.match(/^\/ipfs\/([^/]+)/)?.[1] : null;
  globalThis.fetch = async (input) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url.startsWith('https://name.web3.storage/')) {
      if (value === null) throw new Error('w3name unreachable');
      return new Response(JSON.stringify({ value }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    if (url.startsWith(FB_BASE) || url.startsWith(FX_BASE)) {
      const fromFx = url.startsWith(FX_BASE);
      const cid = url.slice((fromFx ? FX_BASE : FB_BASE).length);
      if (cid === pageCid) {
        if (!pageSources.includes(fromFx ? 'fx' : 'filebase')) {
          throw new Error(`${fromFx ? 'fx' : 'filebase'} unreachable`);
        }
        if (page === null) throw new Error('gateway unreachable');
        return new Response(page, { status: 200, headers: { 'content-type': 'text/html' } });
      }
      if (htmlCids.includes(cid)) {
        return new Response('<!doctype html>', { status: 200, headers: { 'content-type': 'text/html' } });
      }
      if (unhappyCids.includes(cid)) {
        return new Response('slow down', { status: 429, headers: { 'content-type': 'text/plain' } });
      }
      return new Response('x', { status: 206, headers: { 'content-type': 'image/jpeg' } });
    }
    if (url.startsWith('https://example.com/')) {
      return new Response('x', { status: 206, headers: { 'content-type': 'image/png' } });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  return () => { globalThis.fetch = original; };
}

async function get(
  path,
  {
    value = `/ipfs/${CID}`,
    method = 'GET',
    ua = BROWSER,
    page = V2_PAGE,
    htmlCids = [],
    unhappyCids = [],
    pageSources = ['filebase', 'fx'],
  } = {},
) {
  const restore = stubNetwork(value, page, htmlCids, unhappyCids, pageSources);
  try {
    const headers = ua === null ? {} : { 'user-agent': ua };
    return await withLaunch(await worker.fetch(
      new Request(`https://fxfiles.top${path}`, { method, headers }),
      {},
    ));
  } finally {
    restore();
  }
}

/**
 * A browser gets the launcher page (see launcher.js), not a redirect. Its
 * destinations travel in a JSON data block; expose them as `res.launch` so a
 * test can ask where the visitor may end up.
 */
async function withLaunch(res) {
  if (res.status === 200 && (res.headers.get('content-type') || '').startsWith('text/html')) {
    const html = await res.clone().text();
    const m = html.match(/<script type="application\/json" id="fx-launch">([\s\S]*?)<\/script>/);
    if (m) res.launch = { ...JSON.parse(m[1]), html };
  }
  return res;
}

/** The launcher's candidate URLs, in the order they are tried. */
const chain = (res) => (res.launch ? res.launch.candidates.map((c) => c.url) : null);

/** Where a request goes first: the redirect target, or the launcher's first
 *  candidate. */
const location = (res) => res.headers.get('location') ?? res.launch?.candidates[0].url ?? null;

/** Every unresolvable case ends the same way: a plain 502, never a redirect. */
function assertUnresolved(res) {
  assert.equal(res.status, 502, `expected 502, got ${res.status}`);
  assert.equal(location(res), null, 'a 502 must not carry a Location');
}

// ------------------------------------------------------------- the chain

test('a browser gets the launcher with the chain inbrowser -> orbitor -> Filebase', async () => {
  const res = await get(`/w/${NAME}`);
  assert.equal(res.status, 200);
  assert.deepEqual(chain(res), FULL_CHAIN());
  assert.deepEqual(res.launch.candidates.map((c) => c.check), [CHECK.INBROWSER, CHECK.PAGE, CHECK.NONE]);
});

// The app decorated links with ?gw= for years; they must keep working, and the
// value — including hostile ones that once broke a plain-object lookup — must
// not steer or break anything.
for (const gw of ['fx', 'filebase', 'inbrowser', 'dweb', 'bogus', '__proto__', 'toString', 'constructor', 'valueOf', 'hasOwnProperty']) {
  test(`?gw=${gw} neither steers nor breaks the chain`, async () => {
    const res = await get(`/w/${NAME}?gw=${encodeURIComponent(gw)}`);
    assert.deepEqual(chain(res), FULL_CHAIN(), gw);
  });
}

test('pages published before relative assets start at inbrowser too', async () => {
  // only inbrowser's service worker still serves their dweb.link images
  assert.deepEqual(chain(await get(`/w/${NAME}`, { page: LEGACY_PAGE })), FULL_CHAIN());
  assert.deepEqual(chain(await get(`/w/${NAME}`, { page: V1_IMAGES_ONLY })), FULL_CHAIN());
});

// Correctness, not preference: on a subdomain gateway a relative video, link
// or background resolves inside the page's own CID and 404s.
test('a version-1 page with non-image relative references skips inbrowser', async () => {
  assert.deepEqual(chain(await get(`/w/${NAME}`, { page: V1_WITH_VIDEO })), [ORB(), FB()]);
});

test('an unreadable or non-HTML entry gets the full chain', async () => {
  assert.deepEqual(chain(await get(`/w/${NAME}`, { page: null })), FULL_CHAIN());
  const original = globalThis.fetch;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.startsWith('https://name.web3.storage/')) {
      return new Response(JSON.stringify({ value: `/ipfs/${CID}` }), { status: 200 });
    }
    return new Response('%PDF-1.7', { status: 200, headers: { 'content-type': 'application/pdf' } });
  };
  try {
    const res = await withLaunch(await worker.fetch(
      new Request(`https://fxfiles.top/w/${NAME}`, { headers: { 'user-agent': BROWSER } }), {},
    ));
    assert.deepEqual(chain(res), FULL_CHAIN());
  } finally {
    globalThis.fetch = original;
  }
});

// One gateway being slow or down must not decide the chain, nor cost a
// preview: Filebase took 26-30 s for a live page while fx served the same
// bytes in 1.8 s (2026-09-23).
test('either read source alone is enough', async () => {
  for (const sources of [['filebase'], ['fx']]) {
    assert.deepEqual(chain(await get(`/w/${NAME}`, { page: V1_WITH_VIDEO, pageSources: sources })), [ORB(), FB()], `browser, sources=${sources}`);
    const body = await (await get(`/w/${NAME}`, { ua: 'Twitterbot/1.0', page: LEGACY_PAGE, pageSources: sources })).text();
    assert.match(body, /og:title" content="Old site"/, `crawler, sources=${sources}`);
  }
  // with neither, the page cannot be judged: the full chain, the launcher decides
  assert.deepEqual(chain(await get(`/w/${NAME}`, { page: V1_WITH_VIDEO, pageSources: [] })), FULL_CHAIN());
});

// --------------------------------------------------------- who is asking

// Nothing can be checked for a client that is not a browser, and inbrowser
// answers those with 403 or its bootstrap page: they get the path gateway.
test('non-browser clients and HEAD are sent to Filebase', async () => {
  for (const ua of [null, 'curl/8.4.0', 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)', 'python-requests/2.31', 'Mozilla/5.0 HeadlessChrome/153.0.0.0']) {
    const res = await get(`/w/${NAME}`, { ua, page: LEGACY_PAGE });
    assert.equal(res.status, 302, String(ua));
    assert.equal(location(res), FB(), String(ua));
  }
  const head = await get(`/w/${NAME}`, { method: 'HEAD' });
  assert.equal(head.status, 302);
  assert.equal(location(head), FB());
});

// Real in-app browser user agents. They get the launcher like any browser:
// on iOS they are WKWebView with no service workers, and the launcher's own
// capability check (inbrowser's entry checks) rules inbrowser out there. None
// may be mistaken for a crawler and handed the preview page instead.
const IN_APP = {
  instagramIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 339.0.3.12.91 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624456287)',
  facebookIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/470.0.0.40.109;FBBV/630553372;FBDV/iPhone15,2;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBID/phone;FBLC/en_US;FBOP/5;FBRV/0]',
  facebookAndroid: 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UD1A.230803.041; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/470.0.0.41.109;]',
  messengerIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/MessengerForiOS;FBAV/467.0.0.37.109;FBBV/626339960;FBDV/iPhone15,2;FBMD/iPhone;FBSN/iOS;FBSV/17.5]',
  threadsIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Barcelona 339.0.0.23.109 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624470301)',
  tiktokIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 musical_ly_35.3.0 JsSdk/2.0 NetType/WIFI Channel/App Store ByteLocale/en Region/US ByteFullLocale/en-US isDarkMode/0 WKWebView/1 RevealType/Dialog BytedanceWebview/d8a21c6',
  snapchatIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Snapchat/13.5.0.44 (like Safari/8618.2.12.10.9, panda)',
  linkedinIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [LinkedInApp]/9.30.2311',
  lineIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari Line/14.10.0',
  wechatIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49(0x18003130) NetType/WIFI Language/en',
  pinterestIOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [Pinterest/iOS]',
};

for (const [label, ua] of Object.entries(IN_APP)) {
  test(`in-app browser ${label} gets the launcher, never the preview page`, async () => {
    const res = await get(`/w/${NAME}`, { ua, page: LEGACY_PAGE });
    assert.equal(res.status, 200, `${label} got ${res.status}`);
    assert.deepEqual(chain(res), FULL_CHAIN(), label);
  });
}

test('clients that go straight to Filebase do not wait for a page read', async () => {
  let reads = 0;
  const original = globalThis.fetch;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.startsWith('https://name.web3.storage/')) {
      return new Response(JSON.stringify({ value: `/ipfs/${CID}` }), { status: 200 });
    }
    reads++;
    return new Response(LEGACY_PAGE, { status: 200, headers: { 'content-type': 'text/html' } });
  };
  try {
    await worker.fetch(new Request(`https://fxfiles.top/w/${NAME}`, { headers: { 'user-agent': 'curl/8.4.0' } }), {});
    await worker.fetch(new Request(`https://fxfiles.top/w/${NAME}`, { method: 'HEAD', headers: { 'user-agent': BROWSER } }), {});
    assert.equal(reads, 0);
  } finally {
    globalThis.fetch = original;
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

test('a preview crawler whose page cannot be read is redirected to Filebase', async () => {
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

// Measured on a live site: its <img> pointed at a CID that is an HTML page, so
// the preview must move on to a candidate that really is an image.
test('a preview skips an image candidate that is not an image', async () => {
  const NOT_AN_IMAGE = 'bafkr4ifprbzw3laveupep757nt6scr662bs2letknzwsscot3c4umbtmui';
  const page = `<title>Event</title><img src="https://${NOT_AN_IMAGE}.ipfs.dweb.link/"><img src="https://${ASSET}.ipfs.dweb.link/">`;
  const body = await (await get(`/w/${NAME}`, { ua: 'Twitterbot/1.0', page, htmlCids: [NOT_AN_IMAGE] })).text();
  assert.ok(!body.includes(NOT_AN_IMAGE), body);
  assert.match(body, new RegExp(`og:image" content="https://ipfs\\.filebase\\.io/ipfs/${ASSET}"`));

  // and with no real image at all, the card is a plain summary
  const only = `<title>Event</title><img src="https://${NOT_AN_IMAGE}.ipfs.dweb.link/">`;
  const plain = await (await get(`/w/${NAME}`, { ua: 'Twitterbot/1.0', page: only, htmlCids: [NOT_AN_IMAGE] })).text();
  assert.ok(!plain.includes('og:image'), plain);
  assert.match(plain, /twitter:card" content="summary"/);
});

// A gateway hiccup is not proof. Dropping the image whenever a probe fails
// cost a live preview its picture (2026-09-23).
test('a candidate is kept unless it is PROVEN not to be an image', async () => {
  const page = `<title>Event</title><img src="https://${ASSET}.ipfs.dweb.link/">`;
  const body = await (await get(`/w/${NAME}`, { ua: 'Twitterbot/1.0', page, unhappyCids: [ASSET] })).text();
  assert.match(body, new RegExp(`og:image" content="https://ipfs\\.filebase\\.io/ipfs/${ASSET}"`));
  assert.match(body, /summary_large_image/);

  assert.equal(provenNotAnImage(200, 'text/html'), true);
  assert.equal(provenNotAnImage(206, 'image/jpeg'), false);
  assert.equal(provenNotAnImage(429, 'text/plain'), false);
  assert.equal(provenNotAnImage(500, ''), false);
  assert.equal(provenNotAnImage(404, 'text/plain'), false);
  assert.equal(provenNotAnImage(200, null), true);
});

test('extractPreview prefers declared tags and falls back sensibly', () => {
  assert.deepEqual(
    extractPreview(`<meta property="og:title" content="Declared"><title>Tag</title><meta property="og:image" content="../${ASSET}">`),
    { title: 'Declared', description: '', image: FB(ASSET, ''), images: [FB(ASSET, '')] },
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

test('pipeline versions and the chain they get', () => {
  assert.equal(pipelineVersion(LEGACY_PAGE), 0);
  assert.equal(pipelineVersion(V1_IMAGES_ONLY), 1);
  assert.equal(pipelineVersion(V2_PAGE), 2);
  assert.equal(hasNonImageRelativeRefs(V1_IMAGES_ONLY), false);
  assert.equal(hasNonImageRelativeRefs(V1_WITH_VIDEO), true);
  assert.equal(hasNonImageRelativeRefs(`<a href="../${ASSET}/">page</a>`), true);
  assert.equal(hasNonImageRelativeRefs(`<div style="background:url(../${ASSET})"></div>`), true);
  assert.equal(hasNonImageRelativeRefs(`<img src="../${ASSET}" srcset="../${ASSET} 2x">`), true);
  const full = ['inbrowser', 'orbitor', 'filebase'];
  assert.deepEqual(browserChain(null), full);
  assert.deepEqual(browserChain(LEGACY_PAGE), full);
  assert.deepEqual(browserChain(V1_IMAGES_ONLY), full);
  assert.deepEqual(browserChain(V2_PAGE), full);
  assert.deepEqual(browserChain(V1_WITH_VIDEO), ['orbitor', 'filebase']);
});

// ------------------------------------------------ CID / hostname hazards

// The hazard a subdomain gateway brings: the CID lands in the HOSTNAME, where
// case is lost and labels cap at 63 chars. Serving a mangled hostname would
// silently fetch a DIFFERENT cid, so these skip inbrowser.
test('a CIDv0 skips inbrowser and keeps its case', async () => {
  const v0 = 'QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG';
  const res = await get(`/w/${NAME}`, { value: `/ipfs/${v0}` });
  assert.deepEqual(chain(res), [ORB(v0), FB(v0)]);
  // even a legacy page, which would otherwise start at inbrowser
  assert.deepEqual(chain(await get(`/w/${NAME}`, { value: `/ipfs/${v0}`, page: LEGACY_PAGE })), [ORB(v0), FB(v0)]);
});

test('an over-63-char CID skips inbrowser too', async () => {
  const long = 'b' + 'a'.repeat(75);
  assert.deepEqual(chain(await get(`/w/${NAME}`, { value: `/ipfs/${long}` })), [ORB(long), FB(long)]);
});

test('a subpath is carried through every candidate', async () => {
  assert.deepEqual(chain(await get(`/w/${NAME}/about/page.html`)), FULL_CHAIN(CID, '/about/page.html'));
});

test('gw is stripped from the forwarded query, other params survive', async () => {
  for (const url of chain(await get(`/w/${NAME}?utm=x&gw=fx&b=2`))) {
    assert.ok(!url.includes('gw='), `gw leaked into ${url}`);
    assert.ok(url.includes('utm=x') && url.includes('b=2'), url);
  }
});

test('a query with no gw is forwarded untouched', async () => {
  assert.deepEqual(chain(await get(`/w/${NAME}?utm=x`)), FULL_CHAIN().map((u) => `${u}?utm=x`));
});

// A CID is interpolated straight into the destinations, so a hostile or
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
  assert.deepEqual(
    chain(await get(`/w/${NAME}`, { value: `/ipfs/${CID}/site/index.html` })),
    FULL_CHAIN(CID, '/site/index.html'),
  );
});

test('an inner path composes with the visitor subpath', async () => {
  assert.deepEqual(
    chain(await get(`/w/${NAME}/a.html`, { value: `/ipfs/${CID}/site` })),
    FULL_CHAIN(CID, '/site/a.html'),
  );
});

// `inner` is the one piece of a destination that is raw text from an upstream
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
 * load-bearing:
 *
 *  1. Every destination keeps its TRAILING SLASH. From `/ipfs/<page>/` the
 *     reference resolves to `/ipfs/<cid>`; from `/ipfs/<page>` it resolves to
 *     `/<cid>` and 404s (measured on orbitor too, 2026-09-30: both page forms
 *     serve the same bytes, but only the slashed one lets its logos load from
 *     orbitor itself).
 *  2. Browsers are SENT to a gateway, never served the site. If this Worker
 *     served the page itself, `../<cid>` would resolve back into the Worker.
 *     (The launcher and the preview page reference nothing relatively.)
 */
test('keeps the trailing slash — relative asset refs depend on it', async () => {
  const urls = chain(await get(`/w/${NAME}`));
  for (const url of urls) assert.ok(url.endsWith('/'), `no trailing slash: ${url}`);
  // and the reference a generated page carries resolves back onto each path gateway
  assert.equal(new URL(`../${ASSET}`, ORB()).href, ORB(ASSET, ''));
  assert.equal(new URL(`../${ASSET}`, FB()).href, FB(ASSET, ''));
  // the Filebase redirect for non-browsers keeps it too
  assert.ok(location(await get(`/w/${NAME}`, { ua: 'curl/8.4.0' })).endsWith('/'));
});

test('redirects and the launcher are short-cached and vary by client', async () => {
  for (const res of [await get(`/w/${NAME}`, { ua: 'curl/8.4.0' }), await get(`/w/${NAME}`)]) {
    assert.ok(res.status === 302 || res.launch, `unexpected ${res.status}`);
    assert.match(res.headers.get('cache-control'), /max-age=30/);
    assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
    assert.equal(res.headers.get('vary'), 'User-Agent');
  }
});

// The Location header is built by string interpolation, so prove the pieces
// that come from the caller cannot break out of it.
test('no CR/LF can reach the Location header', async () => {
  const res = await get(`/w/${NAME}/a%0d%0aX-Injected:%201`, { ua: 'curl/8.4.0' });
  const loc = location(res);
  assert.ok(!/[\r\n]/.test(loc), `raw CRLF in Location: ${JSON.stringify(loc)}`);
  assert.equal(res.headers.get('x-injected'), null);
});

test('a subpath cannot move any destination off a gateway host', async () => {
  // Either the request is refused outright or every destination is on a
  // gateway host — never anywhere else. `/a/../../evil` takes the first
  // branch: URL normalization rewrites it to /w/evil, whose "name" fails the
  // k51 check.
  const allowed = new Set(['ipfs.filebase.io', new URL(ORBITOR_ORIGIN).host, `${CID}.ipfs.inbrowser.link`]);
  for (const p of ['//evil.com', '/..%2f..%2fevil', '/a/../../evil', '/\\evil.com']) {
    for (const ua of [BROWSER, 'curl/8.4.0']) {
      const res = await get(`/w/${NAME}${p}`, { ua });
      const urls = chain(res) ?? (location(res) ? [location(res)] : []);
      if (urls.length === 0) {
        assert.ok(res.status >= 400, `no destination but status ${res.status} for ${p}`);
        continue;
      }
      for (const url of urls) assert.ok(allowed.has(new URL(url).host), `escaped via ${p}: ${url}`);
    }
  }
});

// ------------------------------------------------------------- the launcher page

test('the launcher is locked down: only its own script, style and the hosts it checks', async () => {
  const res = await get(`/w/${NAME}`);
  const csp = res.headers.get('content-security-policy');
  const sha = (text) => `'sha256-${createHash('sha256').update(text).digest('base64')}'`;
  assert.match(csp, /default-src 'none'/);
  assert.ok(csp.includes(`script-src ${sha(LAUNCHER_SCRIPT)}`), csp);
  assert.ok(csp.includes(`style-src ${sha(LAUNCHER_STYLE)}`), csp);
  const connect = csp.match(/connect-src ([^;]+)/)[1].split(' ').sort();
  const expected = [INBROWSER_SITE_SOURCE, ...[...INBROWSER_PROBE_URLS, ...INBROWSER_ROUTER_URLS].map((u) => new URL(u).origin), ORBITOR_ORIGIN].sort();
  assert.deepEqual(connect, expected);
  // the site's own inbrowser address, which the launcher probes, is covered
  // by that wildcard — and nothing else of inbrowser's is
  const siteHost = new URL(chain(res)[0]).host;
  assert.equal(`https://*.${siteHost.split('.').slice(1).join('.')}`, INBROWSER_SITE_SOURCE);
  for (const d of ["base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"]) assert.ok(csp.includes(d), d);
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');

  // the hashes pin the EXACT text the page carries
  const { html } = res.launch;
  assert.ok(html.includes(`<script>${LAUNCHER_SCRIPT}</script>`));
  assert.ok(html.includes(`<style>${LAUNCHER_STYLE}</style>`));
  // exactly one executable script, plus the data block
  assert.equal((html.match(/<script\b/g) ?? []).length, 2);
});

test('link input cannot break out of the launcher page', async () => {
  const res = await get(`/w/${NAME}?x=${encodeURIComponent('</script><script>alert(1)</script>')}&y=${encodeURIComponent('"><img src=x onerror=alert(2)>')}`);
  const { html } = res.launch;
  assert.equal((html.match(/<script\b/g) ?? []).length, 2);
  assert.ok(!/<img/i.test(html), html);
  assert.ok(!html.includes('alert(1)</script>'), html);
  // and every destination still carries the query, intact
  for (const url of chain(res)) {
    assert.equal(new URL(url).searchParams.get('x'), '</script><script>alert(1)</script>');
  }

  // the data-block encoder on its own
  const encoded = jsonForScriptBlock({ v: '</script><!-- & \u2028' });
  assert.ok(!/[<>&\u2028]/.test(encoded), encoded);
  assert.deepEqual(JSON.parse(encoded), { v: '</script><!-- & \u2028' });
});

test('without JavaScript the launcher goes straight to Filebase', async () => {
  const { html } = (await get(`/w/${NAME}`)).launch;
  assert.ok(html.includes(`<noscript><meta http-equiv="refresh" content="0;url=${FB()}"></noscript>`), html);
  // and the first and last destinations are also plain links
  assert.ok(html.includes(`href="${IB()}"`) && html.includes(`href="${FB()}"`));
});

// ------------------------------------------------ the launcher's decisions

/** inbrowser's own gate needs `Promise.withResolvers`; an older browser's
 *  Promise has everything else the launcher uses. */
function PromiseWithoutResolvers(executor) { return new Promise(executor); }
PromiseWithoutResolvers.resolve = (v) => Promise.resolve(v);
PromiseWithoutResolvers.reject = (e) => Promise.reject(e);
PromiseWithoutResolvers.all = (a) => Promise.all(a);

/** A site's inbrowser destination, and the one address of it the launcher
 *  probes: the origin's root — no path, no query. */
const IB_URL = `${IB(CID, '/about/')}?ref=abc`;
const SITE_PROBE = `https://${CID}.ipfs.inbrowser.link/`;
const PROBES = [SITE_PROBE, ...INBROWSER_PROBE_URLS, ...INBROWSER_ROUTER_URLS];

/**
 * Run the launcher's real script against a stand-in browser.
 *   net(url)   how the network answers a request: 'resolve' | 'reject' | 'hang'
 *   pageOk     whether orbitor answers the page with a success status
 *   sw         'ok' | 'none' (no service workers, e.g. iOS in-app) | 'denied'
 *              | 'stall' (getRegistrations never settles)
 * Resolves with where it went — 'IB' for the inbrowser destination.
 */
function runLauncher({
  net = () => 'resolve',
  pageOk = true,
  sw = 'ok',
  promise = Promise,
  stored,
  storageThrows = false,
  timeoutMs = 30,
  watchdogMs = 1000,
  now = 1_000_000_000,
  candidates = [
    { url: IB_URL, check: CHECK.INBROWSER },
    { url: 'ORB', check: CHECK.PAGE },
    { url: 'FB', check: CHECK.NONE },
  ],
} = {}) {
  return new Promise((resolve) => {
    const data = {
      candidates, inbrowserProbes: INBROWSER_PROBE_URLS, inbrowserRouters: INBROWSER_ROUTER_URLS, timeoutMs, watchdogMs,
      reachableTtlMs: REACHABLE_TTL_MS, blockedTtlMs: BLOCKED_TTL_MS,
    };
    const store = new Map(stored === undefined ? [] : [['fx_inbrowser_reachable', stored]]);
    const calls = [];
    const navigations = [];
    const navigator = sw === 'none' ? {} : {
      serviceWorker: {
        getRegistrations: () => {
          if (sw === 'denied') return Promise.reject(new Error('SecurityError: service workers are disabled'));
          if (sw === 'stall') return new Promise(() => {});
          return Promise.resolve([]);
        },
      },
    };
    const env = {
      document: { getElementById: (id) => (id === 'fx-launch' ? { textContent: JSON.stringify(data) } : null) },
      localStorage: {
        getItem: (k) => { if (storageThrows) throw new Error('denied'); return store.get(k) ?? null; },
        setItem: (k, v) => { if (storageThrows) throw new Error('denied'); store.set(k, v); },
      },
      location: {
        replace: (url) => {
          navigations.push(url);
          resolve({ url: url === IB_URL ? 'IB' : url, calls, navigations, remembered: store.get('fx_inbrowser_reachable') });
        },
      },
      fetch: (url, opts = {}) => {
        calls.push({ url, method: opts.method ?? 'GET', mode: opts.mode, redirect: opts.redirect });
        const answer = net(url);
        if (answer === 'reject') return Promise.reject(new TypeError('Failed to fetch'));
        if (answer === 'hang') return new Promise(() => {});
        return Promise.resolve(url === 'ORB' ? { ok: pageOk, status: pageOk ? 200 : 404 } : { type: 'opaque' });
      },
      navigator,
      Promise: promise,
      URL,
      setTimeout,
      clearTimeout,
      Date: { now: () => now },
    };
    new Function(...Object.keys(env), LAUNCHER_SCRIPT)(...Object.values(env));
  });
}

const probed = (r) => r.calls.filter((c) => PROBES.includes(c.url)).length;
const askedOrbitor = (r) => r.calls.some((c) => c.url === 'ORB');

test('launcher: all good -> inbrowser; orbitor is never contacted', async () => {
  const r = await runLauncher();
  assert.equal(r.url, 'IB');
  assert.deepEqual(r.calls.map((c) => c.url).sort(), [...PROBES].sort());
  // A no-cors fetch must follow redirects (Chrome refuses "manual"), and the
  // service hosts redirect their ROOTS to docs.ipfs.tech, which the page's
  // CSP refuses — so probing a root failed on every visit (measured in Chrome
  // 2026-09-30). Probes use no-cors with default redirects, at paths that
  // answer directly.
  for (const call of r.calls) {
    assert.equal(call.mode, 'no-cors', call.url);
    assert.ok(call.redirect === undefined || call.redirect === 'follow', `${call.url} redirect=${call.redirect}`);
  }
  for (const url of [...INBROWSER_PROBE_URLS, ...INBROWSER_ROUTER_URLS]) {
    assert.notEqual(new URL(url).pathname, '/', `${url}: a service host's root redirects off-policy`);
  }
  assert.equal(askedOrbitor(r), false, 'privacy: orbitor only when inbrowser is ruled out');
  assert.deepEqual(JSON.parse(r.remembered), { ok: true, at: 1_000_000_000 });
});

// The site's inbrowser address only hands over a service worker; the worker
// then fetches the site from other hosts, and THAT is what a filtered network
// blocks. Reaching the address alone must not be enough — nor the services
// alone: the visitor is sent to that exact address.
test('launcher: the site address or the content host blocked or dropped -> orbitor', async () => {
  for (const host of [`${CID}.ipfs.inbrowser.link`, 'trustless-gateway.net']) {
    for (const how of ['reject', 'hang']) {
      const r = await runLauncher({ timeoutMs: 20, net: (url) => (new URL(url, 'https://x.invalid').host === host ? how : 'resolve') });
      assert.equal(r.url, 'ORB', `${host} ${how}`);
      assert.equal(JSON.parse(r.remembered).ok, false);
    }
  }
});

// Measured in Chrome (2026-09-30), opening a site's inbrowser address directly:
// delegated-ipfs.dev UNRESOLVABLE -> the site still renders (4.3 s); silently
// DROPPED -> inbrowser's own 504 after 70 s. Its operator stops running it on
// 2026-09-30, so demanding an answer would skip a working inbrowser for all.
test('launcher: the router may fail, but not stall', async () => {
  const router = (how) => (url) => (new URL(url, 'https://x.invalid').host === 'delegated-ipfs.dev' ? how : 'resolve');
  const failed = await runLauncher({ timeoutMs: 20, net: router('reject') });
  assert.equal(failed.url, 'IB', 'a router that fails fast leaves inbrowser working');
  assert.equal(JSON.parse(failed.remembered).ok, true);
  const stalled = await runLauncher({ timeoutMs: 20, net: router('hang') });
  assert.equal(stalled.url, 'ORB', 'a router that stalls breaks inbrowser');
  assert.equal(JSON.parse(stalled.remembered).ok, false);
});

test('launcher: every host inbrowser needs is probed', () => {
  assert.deepEqual(
    PROBES.map((u) => new URL(u).host).sort(),
    [`${CID}.ipfs.inbrowser.link`, 'delegated-ipfs.dev', 'trustless-gateway.net'].sort(),
  );
});

test('launcher: the Worker-built destination is the address it probes', async () => {
  const res = await get(`/w/${NAME}/about/?ref=abc`);
  assert.equal(chain(res)[0], IB_URL);
  const r = await runLauncher({ candidates: res.launch.candidates });
  assert.equal(r.url, 'IB');
  assert.ok(r.calls.some((c) => c.url === SITE_PROBE), JSON.stringify(r.calls));
  assert.ok(!r.calls.some((c) => c.url.includes('about') || c.url.includes('ref=')), 'no path or query in a probe');
});

test("launcher: a browser that cannot run inbrowser skips it without probing", async () => {
  for (const [label, opts] of [
    ['no service workers (iOS in-app browsers)', { sw: 'none' }],
    ['service workers disabled by settings', { sw: 'denied' }],
    ['no Promise.withResolvers (older browser)', { promise: PromiseWithoutResolvers }],
  ]) {
    const r = await runLauncher(opts);
    assert.equal(r.url, 'ORB', label);
    assert.equal(probed(r), 0, `${label}: no network probe needed`);
    // a property of the browser, not the network: nothing remembered
    assert.equal(r.remembered, undefined, label);
  }
});

test('launcher: a browser that stalls instead of answering is capped like the network', async () => {
  const r = await runLauncher({ sw: 'stall', timeoutMs: 20 });
  assert.equal(r.url, 'ORB');
  assert.equal(probed(r), 0);
  assert.equal(r.remembered, undefined, 'a property of the browser, not the network');
});

test('launcher: the watchdog sends the visitor on even if a wait is somehow not capped', async () => {
  // Every wait is capped at timeoutMs; make that cap useless and let only the
  // watchdog stand between the visitor and a page that never moves.
  // (a cap ten times the watchdog is useless enough, and does not leave
  // minutes of timers behind for the test runner to wait out)
  const r = await runLauncher({ timeoutMs: 300, watchdogMs: 30, net: () => 'hang' });
  assert.equal(r.url, 'FB');
});

test('launcher: the visitor is sent exactly once, whatever finishes first', async () => {
  for (const opts of [{}, { sw: 'none' }, { net: () => 'reject' }, { timeoutMs: 20, net: () => 'hang' }]) {
    const r = await runLauncher({ ...opts, watchdogMs: 40 });
    await new Promise((done) => setTimeout(done, 120));
    assert.equal(r.navigations.length, 1, JSON.stringify(r.navigations));
  }
});

test('launcher: orbitor is proven by the page itself, with a cross-origin HEAD', async () => {
  const r = await runLauncher({ net: (url) => (url === 'ORB' ? 'resolve' : 'reject') });
  assert.equal(r.url, 'ORB');
  const call = r.calls.find((c) => c.url === 'ORB');
  assert.deepEqual([call.method, call.mode], ['HEAD', 'cors']);
});

test('launcher: orbitor not serving the page, refusing, or silent -> Filebase', async () => {
  const noInbrowser = { sw: 'none' };
  assert.equal((await runLauncher({ ...noInbrowser, pageOk: false })).url, 'FB');
  assert.equal((await runLauncher({ ...noInbrowser, net: (u) => (u === 'ORB' ? 'reject' : 'resolve') })).url, 'FB');
  assert.equal((await runLauncher({ ...noInbrowser, timeoutMs: 20, net: (u) => (u === 'ORB' ? 'hang' : 'resolve') })).url, 'FB');
  // everything blocked at once
  assert.equal((await runLauncher({ timeoutMs: 20, net: () => 'reject' })).url, 'FB');
});

test('launcher: a chain without inbrowser starts at orbitor', async () => {
  const r = await runLauncher({ candidates: [{ url: 'ORB', check: CHECK.PAGE }, { url: 'FB', check: CHECK.NONE }] });
  assert.equal(r.url, 'ORB');
  assert.equal(probed(r), 0);
});

test('launcher: a fresh network answer skips the probe', async () => {
  const now = 1_000_000_000;
  const ok = await runLauncher({ now, stored: JSON.stringify({ ok: true, at: now - 60_000 }) });
  assert.deepEqual([ok.url, probed(ok)], ['IB', 0]);
  const blocked = await runLauncher({ now, stored: JSON.stringify({ ok: false, at: now - 10 * 60_000 }) });
  assert.deepEqual([blocked.url, probed(blocked)], ['ORB', 0]);
  // capability is never taken from memory: a remembered "reachable" does not
  // send a browser without service workers to inbrowser
  const incapable = await runLauncher({ now, sw: 'none', stored: JSON.stringify({ ok: true, at: now - 60_000 }) });
  assert.equal(incapable.url, 'ORB');
});

test('launcher: "reachable" expires sooner than "blocked"', async () => {
  const now = 1_000_000_000;
  // 10 minutes old: past the reachable TTL, within the blocked TTL
  const staleOk = await runLauncher({ now, net: (u) => (u === 'ORB' ? 'resolve' : 'reject'), stored: JSON.stringify({ ok: true, at: now - 10 * 60_000 }) });
  assert.deepEqual([staleOk.url, probed(staleOk)], ['ORB', PROBES.length], 'a stale "reachable" must be re-checked');
  const staleBlocked = await runLauncher({ now, stored: JSON.stringify({ ok: false, at: now - 31 * 60_000 }) });
  assert.deepEqual([staleBlocked.url, probed(staleBlocked)], ['IB', PROBES.length]);
});

test('launcher: garbage, future-dated or unreadable storage never breaks it', async () => {
  const now = 1_000_000_000;
  for (const stored of ['not json', '{"ok":"yes","at":1}', JSON.stringify({ ok: true, at: now + 60_000 })]) {
    const r = await runLauncher({ now, stored });
    assert.deepEqual([r.url, probed(r)], ['IB', PROBES.length], stored);
  }
  const denied = await runLauncher({ storageThrows: true });
  assert.equal(denied.url, 'IB');
});
