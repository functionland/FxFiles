/**
 * FxFiles stable-link resolver — a STATELESS Cloudflare Worker that is the
 * fast, pretty front door over each website group's IPNS name.
 *
 *   GET https://fxfiles.top/w/<ipnsName>[/<subpath>][?gw=inbrowser|filebase|fx]
 *      -> resolve <ipnsName> to its current CID via w3name's plain HTTP API
 *      -> for a BROWSER, 302 to the gateway that can render that page:
 *         https://<cid>.ipfs.inbrowser.link/<subpath>         (default)
 *         https://ipfs.filebase.io/ipfs/<cid>/<subpath>       (gw=filebase)
 *         https://ipfs.cloud.fx.land/gateway/<cid>/<subpath>  (gw=fx)
 *         — overridden when the page itself cannot render on the one asked
 *         for (see chooseGateway in site-page.js)
 *      -> for a LINK-PREVIEW CRAWLER, 200 with Open Graph tags built from the
 *         page (a crawler cannot run inbrowser's service worker)
 *      -> for any OTHER client, 302 to the path-style Filebase URL
 *
 * Why this design:
 *  - The app never talks to Cloudflare and holds NO credential here. The IPNS
 *    name is the source of truth; this Worker only *reads* the public w3name
 *    record and redirects. Anyone can redeploy it; losing it loses nothing.
 *  - Resolving through w3name's HTTP API is fast (no DHT wait) and lands on the
 *    immutable per-CID URL, which gateways cache aggressively.
 *  - When w3name is unreachable we return a plain 502 rather than redirecting
 *    anywhere. There used to be a fallback to {name}.ipns.dweb.link; it never
 *    actually resolved (w3name does not publish to the DHT, so a bare name 500s
 *    on a plain gateway — measured 2026-05-30) and that host is switched off for
 *    good on 2026-09-21 anyway. So name->CID resolution depends on this Worker
 *    reading w3name, both non-fx. The CONTENT (CID) stays fully public-reachable
 *    via any IPFS gateway. Net: a link survives fx being down, but not
 *    Cloudflare + w3name both being down. See README for the optional
 *    DHT-publish step that would make any gateway resolve the name directly.
 *
 * Abuse posture (it MUST stay publicly reachable so links + previews work):
 *  - Not an open redirector: the destination host comes from a FIXED allowlist
 *    (see GATEWAYS) keyed by `?gw=`, never from caller-supplied text, and the
 *    path is a CID this Worker resolved itself. A user's custom gateway
 *    template is honoured for their own asset URLs in the app, but is
 *    deliberately NOT accepted here. Anything that isn't a plausible `k51…`
 *    IPNS name is rejected outright.
 *  - GET/HEAD only; implausible/oversized names get a cheap 400 before any
 *    upstream call.
 *  - Optional per-IP rate limit via the built-in Workers rate-limiting binding
 *    (only active if `RW_LIMITER` is configured in wrangler.toml). Pair with a
 *    dashboard WAF Rate Limiting Rule on `/w/*` for global enforcement.
 *
 * Gateway churn is the norm, which is why the destination is a one-line change
 * here rather than a property of published content: Cloudflare retired its IPFS
 * gateway in Aug 2024, and the IPFS Foundation retires dweb.link on 2026-09-21.
 */

import { buildPreviewHtml, chooseGateway, PATH_GATEWAY_BASE } from './site-page.js';

const W3NAME_ENDPOINT = 'https://name.web3.storage';
const REDIRECT_CACHE_SECONDS = 30; // keep short so regenerations propagate fast
const MAX_NAME_LEN = 80; // base36 `k51…` libp2p-key names are ~62 chars
/** CIDv1 base32 (`bafy…`) and CIDv0 base58 (`Qm…`) are both alphanumeric. */
const CID_RE = /^[A-Za-z0-9]{40,120}$/;
/** CR, LF and friends — anything that could split a header value. */
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;

/**
 * Gateways this Worker may redirect to, selected with `?gw=<key>`.
 *
 * A FIXED ALLOWLIST, deliberately — the app lets a user set any IPFS gateway
 * template they like for their own asset URLs, but that value must never reach
 * here. Honouring arbitrary input would turn a link anyone can share into an
 * open redirector, which is exactly the property the checks below exist to
 * protect. Unknown or missing `gw` falls back to the default.
 *
 * `dweb` is gone: the IPFS Foundation retires dweb.link on 2026-09-21, and it
 * already redirects to its successor `inbrowser`, which is listed instead.
 *
 * Note `inbrowser` is SUBDOMAIN-style, which is why SUBDOMAIN_SAFE_CID exists
 * again — a case-sensitive CIDv0 (`Qm…`) or a CID past the 63-character DNS
 * label limit corrupts silently as a hostname. Such a CID falls back to the
 * default rather than being served a mangled one.
 */
const SUBDOMAIN_SAFE_CID = /^[a-z0-9]{1,63}$/;

const GATEWAYS = {
  filebase: {
    // Served the same CID fine at the moment dweb.link was 429ing it
    // (measured 2026-09-12).
    cid: (cid, path) => `https://ipfs.filebase.io/ipfs/${cid}${path}`,
  },
  fx: {
    // Ours. Verified 2026-09-12 to serve these CIDs with correct content types.
    cid: (cid, path) => `https://ipfs.cloud.fx.land/gateway/${cid}${path}`,
  },
  inbrowser: {
    // dweb.link's successor: a service-worker gateway, and BROWSER-ONLY — a
    // request without a browser User-Agent is refused with 403 (measured
    // 2026-09-12), so a link sent here renders for a person but gets no
    // preview card from a crawler.
    subdomain: true,
    cid: (cid, path) => `https://${cid}.ipfs.inbrowser.link${path}`,
  },
};

/**
 * Join the path an IPNS record points INTO with the one the visitor asked for.
 *
 * A record's value is usually a bare `/ipfs/<cid>`, which is all this app ever
 * publishes — but the format allows `/ipfs/<cid>/site/index.html`, and dropping
 * that suffix would silently serve the wrong page for any name that uses one.
 */
function joinPath(inner, subpath) {
  if (!inner) return subpath;
  // A bare `/` from the visitor means "whatever the record points at", so hand
  // back the record's own path untouched — appending a slash would ask the
  // gateway for `/site/index.html/`, which is not the same resource as the
  // file. A directory needs no slash either; gateways redirect to add it.
  return subpath === '/' ? inner : `${inner}${subpath}`;
}

/**
 * Default when `?gw=` is absent or unknown.
 *
 * inbrowser, not filebase (changed 2026-09-16): Filebase answers every page
 * with `Content-Security-Policy: default-src 'self'`, which blocks a site's
 * inline scripts and its Google Forms contact embed, and the sites published
 * before relative assets name dweb.link for every image — which only
 * inbrowser's service worker still serves. inbrowser sends no CSP.
 */
const DEFAULT_GATEWAY = 'inbrowser';

/**
 * Path-style gateway for everything a service-worker gateway cannot serve: a
 * CID that is not a valid DNS label, and any client that is not a browser
 * (inbrowser answers those with 403 or its bootstrap page).
 */
const PATH_GATEWAY = 'filebase';

/** Where the Worker READS a page to decide how to serve it. Path-style and
 *  reachable without a browser; the bytes are immutable, so they are cached at
 *  the edge for a year and read at most once per location. */
const PAGE_READ_BASE = PATH_GATEWAY_BASE;
// A cold Filebase read of a page took 3.9 s (measured 2026-09-16); after that
// it is served from the edge cache. A crawler is given longer: it waits, and a
// missed read costs the link its preview.
const PAGE_READ_TIMEOUT_MS = 6000;
const PAGE_READ_TIMEOUT_CRAWLER_MS = 9000;
const PAGE_READ_MAX_BYTES = 512 * 1024;
const PAGE_CACHE_SECONDS = 31536000;

/**
 * Link-preview crawlers. They get a small page of Open Graph tags built from
 * the site instead of a redirect — a crawler cannot run inbrowser's service
 * worker, and a site that never declared og: tags would otherwise have no
 * preview at all.
 */
const PREVIEW_BOT_RE =
  /facebookexternalhit|facebookcatalog|facebot|twitterbot|linkedinbot|slackbot|discordbot|whatsapp|telegrambot|pinterest|redditbot|applebot|skypeuripreview|vkshare|embedly|iframely|mastodon|bluesky|cardyb|snapchat|viber|kakaotalk|zalo|tumblr|line\//i;

/** Any other non-browser client (search engines, fetch libraries, curl):
 *  redirected to the path gateway, which serves them. */
const NON_BROWSER_RE =
  /bot\b|bot\/|crawl|spider|slurp|curl\/|wget\/|python|java\/|go-http|node-fetch|axios|okhttp|http-client|libwww|headless/i;

export default {
  async fetch(request, env) {
    // Read-only endpoint — only GET/HEAD make sense.
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', {
        status: 405,
        headers: { Allow: 'GET, HEAD' },
      });
    }

    const url = new URL(request.url);

    // Expect /w/<ipnsName>[/<subpath>]
    const match = url.pathname.match(/^\/w\/([^/]+)(\/.*)?$/);
    if (!match) {
      return new Response('FxFiles link resolver. Use /w/<ipns-name>.', {
        status: 404,
        headers: { 'content-type': 'text/plain; charset=utf-8' },
      });
    }

    const name = match[1];

    // Reject anything that isn't a plausible IPNS name (base36 `k51…`) — cheap,
    // and keeps this from being abused as an open redirector or a w3name flood.
    if (name.length > MAX_NAME_LEN || !/^k[0-9a-z]+$/.test(name)) {
      return new Response('Invalid IPNS name.', { status: 400 });
    }

    // Optional, loose per-IP rate limit (only if the binding is configured).
    if (env && env.RW_LIMITER) {
      const ip = request.headers.get('cf-connecting-ip') || 'unknown';
      try {
        const { success } = await env.RW_LIMITER.limit({ key: ip });
        if (!success) {
          return new Response('Rate limited. Try again shortly.', {
            status: 429,
            headers: { 'Retry-After': '10' },
          });
        }
      } catch (_) {
        // Limiter unavailable — fail open (availability over strictness).
      }
    }

    const subpath = match[2] || '/';

    // `gw` is ours, not the gateway's — strip it before forwarding so the
    // upstream never sees a stray query param it does not understand.
    const forwarded = new URLSearchParams(url.search);
    const gwKey = forwarded.get('gw');
    forwarded.delete('gw');
    const query = forwarded.toString() ? `?${forwarded}` : '';

    // Unknown keys fall back rather than erroring: a link with a typo — or a
    // retired key like `gw=dweb` — should still resolve, just on the default.
    //
    // hasOwn, NOT a bare `GATEWAYS[gwKey] ||` — gwKey is caller-controlled and
    // a plain object literal inherits from Object.prototype, so `?gw=toString`
    // and `?gw=__proto__` would hand back a TRUTHY inherited value whose `.cid`
    // is undefined. That throws inside the try below and the request ends as a
    // 502, so the typo would break the link instead of using the default.
    const requestedKey = Object.hasOwn(GATEWAYS, gwKey ?? '')
      ? gwKey
      : DEFAULT_GATEWAY;
    const userAgent = request.headers.get('user-agent') || '';

    // NOTE: there is no IPNS-gateway fallback any more. It pointed at
    // ipns.dweb.link, which (a) never resolved anyway — w3name does not publish
    // to the DHT, so a bare name 500s on a plain gateway — and (b) is being
    // switched off entirely on 2026-09-21. Redirecting a visitor to a host that
    // is guaranteed to fail just turns our error into someone else's confusing
    // one, so when w3name is unreachable we now say so plainly instead.

    try {
      const res = await fetch(`${W3NAME_ENDPOINT}/name/${name}`, {
        cf: { cacheTtl: REDIRECT_CACHE_SECONDS, cacheEverything: true },
      });
      if (res.ok) {
        const data = await res.json();
        const value = data && data.value; // e.g. "/ipfs/<cid>"
        if (typeof value === 'string' && value.startsWith('/ipfs/')) {
          const rest = value.slice('/ipfs/'.length);
          const slash = rest.indexOf('/');
          const cid = slash === -1 ? rest : rest.slice(0, slash);
          const inner = slash === -1 ? '' : rest.slice(slash);
          // Charset-check the CID before it is interpolated. For the
          // subdomain shape it lands in the AUTHORITY (`https://<cid>.ipfs…`),
          // where a `@`, a backslash or a dot would re-point the host — so a
          // hostile or compromised w3name answer must not be able to put one
          // there. Real CIDs are base32 (`bafy…`) or base58 (`Qm…`): both are
          // alphanumeric, so this rejects nothing legitimate.
          // `inner` is raw text from the record and ends up inside a header
          // value. The CID above already terminates the authority, so it
          // cannot move the host — but a control character could split the
          // Location header. The Workers `Headers` class would throw on that
          // (caught below, so the link would break rather than leak), and a
          // header split is not something to leave to a runtime check.
          if (cid && CID_RE.test(cid) && !CONTROL_CHARS.test(inner)) {
            const path = joinPath(inner, subpath);
            const pathTarget = `${GATEWAYS[PATH_GATEWAY].cid(cid, path)}${query}`;

            // Only the site's entry page is read: it is what carries the
            // pipeline markers and the preview metadata. A subpath is served
            // as asked.
            const isPreviewBot = PREVIEW_BOT_RE.test(userAgent);
            const page = path === '/'
              ? await readPage(cid, isPreviewBot ? PAGE_READ_TIMEOUT_CRAWLER_MS : PAGE_READ_TIMEOUT_MS)
              : null;

            if (isPreviewBot) {
              return typeof page === 'string'
                ? previewResponse(page, `https://${url.host}/w/${name}`, pathTarget)
                : redirect(pathTarget);
            }
            if (!/mozilla\//i.test(userAgent) || NON_BROWSER_RE.test(userAgent)) {
              return redirect(pathTarget);
            }

            // A file that is not a page has no pipeline to account for.
            const gateway = GATEWAYS[
              page === NOT_HTML ? requestedKey : chooseGateway(page, requestedKey)
            ];
            // A subdomain gateway puts the CID in the HOSTNAME, where a
            // case-sensitive CIDv0 or an over-long CID is silently mangled
            // into a different (wrong) CID. Serve those from the path-style
            // gateway rather than a URL that cannot work.
            const usable =
              gateway.subdomain && !SUBDOMAIN_SAFE_CID.test(cid)
                ? GATEWAYS[PATH_GATEWAY]
                : gateway;
            return redirect(`${usable.cid(cid, path)}${query}`);
          }
        }
      }
    } catch (_) {
      // fall through to the plain error below
    }

    // Reached when w3name is unreachable, returns a non-OK, or hands back a
    // value that is not a usable `/ipfs/<cid>`. 502, because the failure is
    // upstream of us and the visitor's link is probably fine.
    return new Response(
      'Could not resolve this FxFiles link right now. The IPNS name service ' +
        'is unreachable — please try again shortly.',
      {
        status: 502,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'Cache-Control': 'no-store',
          'Retry-After': '30',
        },
      },
    );
  },
};

function redirect(location) {
  return new Response(null, {
    status: 302, // 302, NOT 301 — the target changes on every regeneration
    headers: {
      Location: location,
      'Cache-Control': `public, max-age=${REDIRECT_CACHE_SECONDS}`,
      'Referrer-Policy': 'no-referrer',
      // the target depends on the client (browser, crawler, other)
      Vary: 'User-Agent',
    },
  });
}

/** readPage's answer for an entry that was read fine but is not a page. */
const NOT_HTML = Symbol('not-html');

/**
 * Read a published page. Returns its HTML; NOT_HTML when the entry is some
 * other file; null when it could not be read in time. Neither non-string
 * answer is an error for the caller.
 */
async function readPage(cid, timeoutMs) {
  try {
    const res = await fetch(`${PAGE_READ_BASE}${cid}`, {
      cf: { cacheTtl: PAGE_CACHE_SECONDS, cacheEverything: true },
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    if (!/text\/html/i.test(res.headers.get('content-type') || '')) {
      await res.body?.cancel();
      return NOT_HTML;
    }
    // Bounded: the markers and the preview metadata sit at the top of a page,
    // so a huge page is read only as far as the cap.
    const reader = res.body.getReader();
    const chunks = [];
    let size = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      size += value.byteLength;
      if (size >= PAGE_READ_MAX_BYTES) {
        await reader.cancel();
        break;
      }
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return new TextDecoder().decode(bytes);
  } catch (_) {
    return null;
  }
}

/**
 * The page a link-preview crawler gets (see buildPreviewHtml). Served under
 * `default-src 'none'`: it needs no subresource, so nothing taken from the
 * site can load or run anything.
 */
function previewResponse(html, link, target) {
  return new Response(buildPreviewHtml(html, link, target), {
    status: 200,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'content-security-policy': "default-src 'none'",
      'x-content-type-options': 'nosniff',
      'cache-control': `public, max-age=${REDIRECT_CACHE_SECONDS}`,
      'referrer-policy': 'no-referrer',
      vary: 'User-Agent',
    },
  });
}
