/**
 * FxFiles stable-link resolver — a STATELESS Cloudflare Worker that is the
 * fast, pretty front door over each website group's IPNS name.
 *
 *   GET https://fxfiles.top/w/<ipnsName>[/<subpath>][?gw=dweb|filebase]
 *      -> resolve <ipnsName> to its current CID via w3name's plain HTTP API
 *      -> 302 to that gateway's URL for the CID, e.g.
 *         https://<cid>.ipfs.dweb.link/<subpath>          (gw=dweb, default)
 *         https://ipfs.filebase.io/ipfs/<cid>/<subpath>   (gw=filebase)
 *
 * Why this design:
 *  - The app never talks to Cloudflare and holds NO credential here. The IPNS
 *    name is the source of truth; this Worker only *reads* the public w3name
 *    record and redirects. Anyone can redeploy it; losing it loses nothing.
 *  - Resolving through w3name's HTTP API is fast (no DHT wait) and lands on the
 *    immutable per-CID URL, which gateways cache aggressively.
 *  - If w3name is slow/unavailable, we fall back to the raw IPNS gateway URL.
 *    NOTE (measured 2026-05-30): that fallback only resolves if the record is
 *    ALSO published to the IPFS DHT — w3name does NOT do that, so today a bare
 *    {name}.ipns.dweb.link does NOT resolve on a plain gateway (it 500s). So
 *    name->CID resolution currently depends on this Worker reading w3name (both
 *    non-fx). The CONTENT (CID) IS fully public-reachable via IPFS gateways
 *    (verified 200). Net: the link survives fx being down, but not Cloudflare +
 *    w3name both being down. See README for the optional DHT-publish step that
 *    makes any gateway work.
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
 * Cloudflare's own IPFS gateway was decommissioned in Aug 2024 — irrelevant
 * here; this Worker `fetch()`es the IPFS Foundation gateways (dweb.link/ipfs.io).
 */

const GATEWAY_HOST = 'ipfs.dweb.link';
const IPNS_GATEWAY_HOST = 'ipns.dweb.link';
const W3NAME_ENDPOINT = 'https://name.web3.storage';
const REDIRECT_CACHE_SECONDS = 30; // keep short so regenerations propagate fast
const MAX_NAME_LEN = 80; // base36 `k51…` libp2p-key names are ~62 chars
/** CIDv1 base32 (`bafy…`) and CIDv0 base58 (`Qm…`) are both alphanumeric. */
const CID_RE = /^[A-Za-z0-9]{40,120}$/;
/** CR, LF and friends — anything that could split a header value. */
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;

/**
 * Can this CID be a DNS label, i.e. is the subdomain gateway shape usable?
 *
 * Two ways it cannot, both of which silently corrupt the CID rather than
 * failing loudly:
 *   - CIDv0 (`Qm…`) is base58 and CASE-SENSITIVE, but hostnames are not — the
 *     resolver lowercases the label and the gateway receives a different CID.
 *   - A DNS label caps at 63 characters (RFC 1035). CIDv1-base32 over SHA-256
 *     is 59, but a larger hash function would overrun it.
 * Either way the answer is the same: use the gateway's path form, which
 * preserves case and has no length limit.
 */
const SUBDOMAIN_SAFE_CID = /^[a-z0-9]{1,63}$/;

/**
 * Gateways this Worker may redirect to, selected with `?gw=<key>`.
 *
 * A FIXED ALLOWLIST, deliberately — the app lets a user set any IPFS gateway
 * template they like for their own asset URLs, but that value must never reach
 * here. Honouring arbitrary input would turn a link anyone can share into an
 * open redirector, which is exactly the property the checks below exist to
 * protect. Unknown or missing `gw` falls back to the default.
 *
 * `cid` builds the immutable per-CID URL in whichever shape the gateway wants:
 *   subdomain — https://<cid>.ipfs.dweb.link/<path>
 *   path      — https://ipfs.filebase.io/ipfs/<cid>/<path>
 */
const GATEWAYS = {
  dweb: {
    cid: (cid, path) =>
      SUBDOMAIN_SAFE_CID.test(cid)
        ? `https://${cid}.${GATEWAY_HOST}${path}`
        : `https://dweb.link/ipfs/${cid}${path}`,
  },
  filebase: {
    // dweb.link starts returning 429 once a site sees real traffic; Filebase
    // served the same CID fine at the same moment (measured 2026-09-12).
    // Path-style, so it needs no subdomain-safety dance.
    cid: (cid, path) => `https://ipfs.filebase.io/ipfs/${cid}${path}`,
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
const DEFAULT_GATEWAY = 'dweb';

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

    // Unknown keys fall back rather than erroring: a link with a typo should
    // still resolve, just on the default gateway.
    //
    // hasOwn, NOT a bare `GATEWAYS[gwKey] ||` — gwKey is caller-controlled and
    // a plain object literal inherits from Object.prototype, so `?gw=toString`
    // and `?gw=__proto__` would hand back a TRUTHY inherited value whose `.cid`
    // is undefined. That throws inside the try below and drops the request on
    // the IPNS fallback, which (see the note at the top) does not resolve. The
    // typo would break the link instead of quietly using the default.
    const gateway = Object.hasOwn(GATEWAYS, gwKey ?? '')
      ? GATEWAYS[gwKey]
      : GATEWAYS[DEFAULT_GATEWAY];

    // The happy path below never uses an IPNS gateway: w3name resolves the
    // name here and we redirect to the immutable /ipfs/<cid>, which every
    // gateway serves. This fallback only runs when w3name is unreachable, and
    // per the note at the top it does not resolve anyway (the record is not on
    // the DHT). Left on dweb because it is the only host that would even try.
    const ipnsFallback =
      `https://${name}.${IPNS_GATEWAY_HOST}${subpath}${query}`;

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
      // fall through to the IPNS gateway fallback
    }

    return redirect(ipnsFallback);
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
