/**
 * FxFiles stable-link resolver — a STATELESS Cloudflare Worker that is the
 * fast, pretty front door over each website group's IPNS name.
 *
 *   GET https://fxfiles.top/w/<ipnsName>[/<subpath>][?gw=filebase|fx]
 *      -> resolve <ipnsName> to its current CID via w3name's plain HTTP API
 *      -> 302 to that gateway's URL for the CID, e.g.
 *         https://ipfs.filebase.io/ipfs/<cid>/<subpath>       (gw=filebase, default)
 *         https://ipfs.cloud.fx.land/gateway/<cid>/<subpath>  (gw=fx)
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
 * `dweb` IS DELIBERATELY ABSENT. The IPFS Foundation switched dweb.link off for
 * good on 2026-09-21. Links minted while it was the default carry an explicit
 * `?gw=dweb`, and an explicit key would normally beat the default — but that
 * "choice" was manufactured by the default rather than made by anyone, so
 * honouring it would send those links to a dead host. Dropping the key makes
 * them fall back here instead, which is the whole point.
 *
 * Both remaining gateways are PATH-style (`https://host/ipfs/<cid>/<path>`), so
 * there is no subdomain-safety problem to handle. A subdomain gateway would need
 * that guard back: a case-sensitive CIDv0 (`Qm…`) or a CID over the 63-character
 * DNS label limit silently corrupts as a hostname, but is fine in a path.
 */
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

/** Default when `?gw=` is absent — keeps every already-shared link working. */
const DEFAULT_GATEWAY = 'filebase';

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
    const gateway = Object.hasOwn(GATEWAYS, gwKey ?? '')
      ? GATEWAYS[gwKey]
      : GATEWAYS[DEFAULT_GATEWAY];

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
            return redirect(`${gateway.cid(cid, path)}${query}`);
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
    },
  });
}
