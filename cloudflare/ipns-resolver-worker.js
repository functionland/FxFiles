/**
 * FxFiles stable-link resolver — a STATELESS Cloudflare Worker that is the
 * fast, pretty front door over each website group's IPNS name.
 *
 *   GET https://fxfiles.top/w/<ipnsName>[/<subpath>]
 *      -> resolve <ipnsName> to its current CID via w3name's plain HTTP API
 *      -> 302 to https://<cid>.ipfs.dweb.link/<subpath>
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
 *  - Not an open redirector: only ever redirects to a derived dweb.link URL,
 *    and rejects anything that isn't a plausible `k51…` IPNS name.
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
    const ipnsFallback =
      `https://${name}.${IPNS_GATEWAY_HOST}${subpath}${url.search}`;

    try {
      const res = await fetch(`${W3NAME_ENDPOINT}/name/${name}`, {
        cf: { cacheTtl: REDIRECT_CACHE_SECONDS, cacheEverything: true },
      });
      if (res.ok) {
        const data = await res.json();
        const value = data && data.value; // e.g. "/ipfs/<cid>"
        if (typeof value === 'string' && value.startsWith('/ipfs/')) {
          const cid = value.slice('/ipfs/'.length).split('/')[0];
          if (cid) {
            return redirect(
              `https://${cid}.${GATEWAY_HOST}${subpath}${url.search}`,
            );
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
