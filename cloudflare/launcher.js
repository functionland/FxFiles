/**
 * The page fxfiles.top answers a BROWSER with, instead of a bare redirect: it
 * works out, in the visitor's own browser, which gateway will actually show
 * the site, and goes there. Order (owner's decision, 2026-09-30):
 *
 *   inbrowser  ->  orbitor (eu.orbitor.dev)  ->  Filebase
 *
 * Why in the browser: the Worker runs on Cloudflare's edge, not on the
 * visitor's network or in their browser, so it cannot see a wifi that filters
 * a gateway (measured: this very network resets connections to orbitor.dev
 * and rewrites its DNS, while inbrowser answers in 60 ms), nor a browser that
 * cannot run a service worker.
 *
 * inbrowser is chosen only when BOTH hold:
 *  1. this browser can run it — inbrowser's own entry checks
 *     (ipfs/service-worker-gateway src/lib/is-browser-supported.ts and
 *     src/index.tsx: Promise.withResolvers, non-special-scheme URL parsing,
 *     `serviceWorker` in navigator), plus service workers actually being
 *     permitted: settings that block site data leave the API present but
 *     refusing. iOS in-app browsers (WKWebView) fail here — no special case.
 *  2. its service worker can fetch the site from this network. The site's own
 *     inbrowser address (<cid>.ipfs.inbrowser.link — its wildcard DNS and
 *     certificate) only hands the browser that worker; the worker then fetches
 *     the content from trustless-gateway.net (HTTPS) and asks delegated-ipfs.dev
 *     for providers (src/config, src/sw/lib/verified-fetch.ts). The first two
 *     must answer (a 403 still proves a host is reachable —
 *     trustless-gateway.net refuses anyone but that worker); the router must
 *     only not stall. See INBROWSER_PROBE_URLS for the measurements behind
 *     that and for why each is probed where it is. The site's address is
 *     probed at its root: no path or query leaves the page, and a worker
 *     already installed there does not answer for another page's fetch.
 * orbitor is chosen when the site's page itself loads there: its status is
 * read (orbitor allows cross-origin reads), not merely the host's reachability.
 * Filebase is the last resort and is not checked.
 *
 * Security posture:
 *  - The SCRIPT is a constant; the per-link destinations travel in a
 *    non-executable JSON block, so the CSP pins the script by hash under
 *    `default-src 'none'`.
 *  - Every destination is computed by the Worker (fixed gateways + a
 *    charset-checked CID); the page never builds a URL from input.
 *  - Storage: one yes/no and a timestamp on fxfiles.top. No identifiers.
 *  - Privacy: orbitor is only contacted when inbrowser is ruled out, and the
 *    inbrowser probe names only the site's CID (as the destination does).
 *
 * Pure (no runtime bindings) so it is testable under `node --test`.
 */
import { escapeHtml } from './site-page.js';

/**
 * What inbrowser's service worker needs from the network, measured in Chrome
 * by opening a site's inbrowser address with one host made unreachable
 * (2026-09-30):
 *
 *   trustless-gateway.net unresolvable   -> 504 after 70 s: it must ANSWER
 *   delegated-ipfs.dev unresolvable      -> the site renders (4.3 s)
 *   delegated-ipfs.dev silently dropped  -> 504 after 70 s: it must not STALL
 *
 * The router only has to fail fast, not answer — which matters now: its
 * operator (IPFS Shipyard) stops running it on 2026-09-30, and demanding an
 * answer would have sent every visitor past a working inbrowser once it goes.
 *
 * Each is probed at an address that answers DIRECTLY. Both hosts redirect
 * their root to docs.ipfs.tech, which this page's CSP rightly refuses, and a
 * no-cors fetch must follow redirects (Chrome: "Request mode is 'no-cors' but
 * the redirect mode is not 'follow'"), so probing a root failed on every visit.
 * These are the very requests the worker makes: a raw-block fetch (403 for
 * anyone but that worker — still an answer) and the routing API. `bafkqaaa`
 * is the identity CID of empty content: it names neither visitor nor site.
 */
export const INBROWSER_PROBE_URLS = [
  'https://trustless-gateway.net/ipfs/bafkqaaa?format=raw',
];

/** Must settle — answer OR fail — within the cap; only a stall is fatal. */
export const INBROWSER_ROUTER_URLS = [
  'https://delegated-ipfs.dev/routing/v1/providers/bafkqaaa',
];

/** Where every site's own inbrowser address lives (CSP source). */
export const INBROWSER_SITE_SOURCE = 'https://*.ipfs.inbrowser.link';

export const ORBITOR_ORIGIN = 'https://eu.orbitor.dev';

/** Per check. A filtered network usually refuses at once (DNS or TLS); this
 *  caps the one that silently drops or stalls the connection instead
 *  (measured on this network: orbitor.dev connections reset ~19 s in). */
export const CHECK_TIMEOUT_MS = 2500;

/** The longest a visitor can stay on the launcher, whatever the browser does.
 *  The slowest legitimate path is three capped waits (inbrowser capability,
 *  inbrowser probes, orbitor) = 7.5 s; this only fires if something that was
 *  supposed to be capped was not. */
export const WATCHDOG_MS = 4 * CHECK_TIMEOUT_MS;

/** How long inbrowser's NETWORK answer is remembered. "Reachable" is kept for
 *  less time: acting on a stale "reachable" after moving to a filtered network
 *  strands the visitor, while a stale "blocked" only costs them inbrowser. */
export const REACHABLE_TTL_MS = 5 * 60 * 1000;
export const BLOCKED_TTL_MS = 30 * 60 * 1000;

/** What each candidate needs to be proven before the visitor is sent there. */
export const CHECK = Object.freeze({
  INBROWSER: 'inbrowser',
  PAGE: 'page',
  NONE: 'none',
});

export const LAUNCHER_SCRIPT = `(function () {
  var data = JSON.parse(document.getElementById('fx-launch').textContent);
  var KEY = 'fx_inbrowser_reachable';
  var now = Date.now();

  var gone = false;
  function go(url) {
    if (gone) return;
    gone = true;
    location.replace(url);
  }

  function within(promise, ms) {
    return new Promise(function (resolve) {
      var done = false;
      var timer = setTimeout(function () { if (!done) { done = true; resolve(false); } }, ms);
      promise.then(function (value) {
        if (!done) { done = true; clearTimeout(timer); resolve(!!value); }
      }, function () {
        if (!done) { done = true; clearTimeout(timer); resolve(false); }
      });
    });
  }

  function recall() {
    try {
      var seen = JSON.parse(localStorage.getItem(KEY) || 'null');
      if (seen && typeof seen.ok === 'boolean' && typeof seen.at === 'number') {
        var age = now - seen.at;
        if (age >= 0 && age < (seen.ok ? data.reachableTtlMs : data.blockedTtlMs)) return seen.ok;
      }
    } catch (e) {}
    return null;
  }

  function remember(ok) {
    try { localStorage.setItem(KEY, JSON.stringify({ ok: ok, at: now })); } catch (e) {}
  }

  function yes() { return true; }

  function probe(url) {
    return fetch(url, { mode: 'no-cors', cache: 'no-store', credentials: 'omit' });
  }

  function canRunInbrowser() {
    try {
      if (!('withResolvers' in Promise)) return Promise.resolve(false);
      if (new URL('ipfs://host').hostname !== 'host') return Promise.resolve(false);
      if (!('serviceWorker' in navigator) || !navigator.serviceWorker) return Promise.resolve(false);
      // Capped like every other wait: a browser that stalls here instead of
      // answering must not keep the visitor on this page.
      return within(navigator.serviceWorker.getRegistrations(), data.timeoutMs);
    } catch (e) {
      return Promise.resolve(false);
    }
  }

  function checkInbrowser(url) {
    return canRunInbrowser().then(function (capable) {
      if (!capable) return false;
      var seen = recall();
      if (seen !== null) return seen;
      var answered = [new URL(url).origin + '/'].concat(data.inbrowserProbes).map(probe);
      var settled = data.inbrowserRouters.map(function (url) {
        return probe(url).then(yes, yes);
      });
      return within(Promise.all(answered.concat(settled)), data.timeoutMs).then(function (ok) {
        remember(ok);
        return ok;
      });
    });
  }

  function checkPage(url) {
    return within(fetch(url, {
      method: 'HEAD',
      mode: 'cors',
      cache: 'no-store',
      credentials: 'omit'
    }).then(function (res) { return res.ok; }), data.timeoutMs);
  }

  var index = 0;
  function next() {
    var candidate = data.candidates[index++];
    if (!candidate) return;
    if (candidate.check === 'none' || index === data.candidates.length) {
      go(candidate.url);
      return;
    }
    var check = candidate.check === 'inbrowser' ? checkInbrowser(candidate.url) : checkPage(candidate.url);
    check.then(function (ok) {
      if (ok) go(candidate.url);
      else next();
    }, next);
  }

  var last = data.candidates[data.candidates.length - 1].url;
  // Every wait above is capped, so this never fires in a working browser. It
  // is the promise that the visitor leaves this page whatever a browser does.
  setTimeout(function () { go(last); }, data.watchdogMs);
  try {
    next();
  } catch (e) {
    go(last);
  }
})();`;

export const LAUNCHER_STYLE = `body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;background:#fff;color:#1f2328}
main{text-align:center;padding:24px}
p{margin:0 0 8px}
.links{font-size:14px;color:#57606a}
a{color:#0969da}
@media (prefers-color-scheme:dark){body{background:#0d1117;color:#e6edf3}.links{color:#9198a1}a{color:#4493f8}}`;

/**
 * JSON for an HTML data block: every character that could end the element or
 * be read as markup is escaped, so no value can close the block early.
 */
export function jsonForScriptBlock(value) {
  return JSON.stringify(value)
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

/**
 * The launcher page. [candidates] are `{ url, check }` in the order to try;
 * the last one is where the visitor goes when nothing before it is proven.
 */
export function buildLauncherHtml(candidates) {
  if (!candidates.length) throw new Error('no candidates');
  const last = candidates[candidates.length - 1].url;
  const first = candidates[0].url;
  const data = {
    candidates,
    inbrowserProbes: INBROWSER_PROBE_URLS,
    inbrowserRouters: INBROWSER_ROUTER_URLS,
    timeoutMs: CHECK_TIMEOUT_MS,
    watchdogMs: WATCHDOG_MS,
    reachableTtlMs: REACHABLE_TTL_MS,
    blockedTtlMs: BLOCKED_TTL_MS,
  };
  return [
    '<!doctype html>',
    '<html lang="en"><head><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<meta name="robots" content="noindex">',
    '<title>Opening website…</title>',
    // Nothing can be checked without JavaScript, and inbrowser cannot run
    // without it at all: go to the last resort, reachable almost everywhere.
    `<noscript><meta http-equiv="refresh" content="0;url=${escapeHtml(last)}"></noscript>`,
    `<style>${LAUNCHER_STYLE}</style>`,
    '</head><body><main>',
    '<p>Opening website…</p>',
    `<p class="links"><a href="${escapeHtml(first)}">Open</a> · <a href="${escapeHtml(last)}">Open the backup copy</a></p>`,
    '</main>',
    `<script type="application/json" id="fx-launch">${jsonForScriptBlock(data)}</script>`,
    `<script>${LAUNCHER_SCRIPT}</script>`,
    '</body></html>',
  ].join('\n');
}

async function sha256Base64(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  let binary = '';
  for (const byte of new Uint8Array(digest)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

let policyPromise = null;

/**
 * The launcher's Content-Security-Policy: nothing but its own script and
 * style (by hash) and the hosts it checks. Computed once.
 */
export function launcherCsp() {
  const hosts = [
    INBROWSER_SITE_SOURCE,
    ...[...INBROWSER_PROBE_URLS, ...INBROWSER_ROUTER_URLS].map((u) => new URL(u).origin),
    ORBITOR_ORIGIN,
  ];
  policyPromise ??= Promise.all([sha256Base64(LAUNCHER_SCRIPT), sha256Base64(LAUNCHER_STYLE)]).then(
    ([scriptHash, styleHash]) =>
      [
        "default-src 'none'",
        `script-src 'sha256-${scriptHash}'`,
        `style-src 'sha256-${styleHash}'`,
        `connect-src ${hosts.join(' ')}`,
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
      ].join('; '),
  );
  return policyPromise;
}
