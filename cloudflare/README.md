# FxFiles stable-link resolver (Cloudflare Worker)

A **stateless** Worker that is the fast, pretty front door for the app's stable
per-website links. It resolves a group's IPNS name to its current CID and sends
the visitor to an immutable IPFS gateway URL.

```
GET https://fxfiles.top/w/<ipnsName>            browser  -> 200 launcher page (below)
GET https://fxfiles.top/w/<ipnsName>/page.html  browser  -> 200 launcher page, same chain for page.html
GET https://fxfiles.top/w/<ipnsName>            crawler  -> 200 Open Graph preview page
GET https://fxfiles.top/w/<ipnsName>            anything else, or HEAD -> 302 https://ipfs.filebase.io/ipfs/<cid>/
```

## Browsers: the launcher chain

A browser gets a small launcher page (`launcher.js`) that decides, **in the
visitor's own browser**, which gateway will actually show the site, and goes
there with `location.replace`. The order, for every site and every browser:

```
inbrowser  ->  orbitor (eu.orbitor.dev)  ->  Filebase
https://<cid>.ipfs.inbrowser.link/   https://eu.orbitor.dev/ipfs/<cid>/   https://ipfs.filebase.io/ipfs/<cid>/
```

It runs in the browser because the Worker cannot see what matters: it runs on
Cloudflare's edge, not on the visitor's network, so it cannot tell that a wifi
filters a gateway, nor that a browser cannot run a service worker.

- **inbrowser** is chosen only when both hold:
  1. *This browser can run it:* inbrowser's own entry checks
     (`Promise.withResolvers`, non-special-scheme URL parsing, `serviceWorker`
     in `navigator`), plus `navigator.serviceWorker.getRegistrations()`
     resolving. Settings that block site data leave the API present but
     refusing ("The user denied permission to use Service Worker"), and
     `navigator.cookieEnabled` still says `true` then, so it is not used
     (measured in Chrome, 2026-09-30). iOS in-app browsers (WKWebView) have no
     service workers and fail here, with no special case.
  2. *Its service worker can fetch the site from this network:* the site's own
     address `https://<cid>.ipfs.inbrowser.link/` only hands over the worker.
     The worker then fetches content from `trustless-gateway.net` and finds
     providers through `delegated-ipfs.dev`. All three are probed at once
     (`no-cors`, 2.5 s cap). The service hosts are probed at API paths that
     answer directly (`/ipfs/bafkqaaa?format=raw` gives 403, still an answer;
     `/routing/v1/providers/bafkqaaa` gives 200). Their roots redirect to
     docs.ipfs.tech, which the launcher's CSP refuses, and a `no-cors` fetch
     must follow redirects, so probing a root failed on every visit.
- **orbitor** is chosen when the site's page itself loads there: a
  cross-origin `HEAD` of the page (orbitor sends
  `Access-Control-Allow-Origin: *`) must return a success status within 2.5 s.
  Orbitor has no CSP, so inline scripts and Google Forms embeds work, but some
  networks filter it (measured: DNS rewritten, connections reset).
- **Filebase** is the last resort and is not checked. Its CSP blocks inline
  scripts and embeds, so it is never first. Without JavaScript the launcher's
  `<noscript>` refresh goes straight there.

The network answer for inbrowser is remembered on fxfiles.top: "reachable" for
5 minutes, "blocked" for 30. A stale "reachable" after moving to a filtered
network would strand the visitor, while a stale "blocked" only costs them
inbrowser. Capability is re-checked on every visit, never remembered.

Measured in real Chrome against real gateways (2026-09-30):

| Situation | Lands on | Time |
|---|---|---|
| Everything reachable | inbrowser | 0.55 s; 0.06 s once remembered |
| trustless-gateway.net blocked | orbitor, else Filebase | 2.9 s (orbitor filtered on the test network) |
| delegated-ipfs.dev silently dropped | orbitor, else Filebase | 5.4 s (both caps) |
| inbrowser and orbitor blocked | Filebase | 0.4 s; 0.06 s once remembered |
| Site data blocked (no service workers) | orbitor, else Filebase | 2.9 s |
| JavaScript off | Filebase | 0.5 s |

**Security.** The script is a constant; per-link destinations travel in a
non-executable `<script type="application/json">` block, so the page is served
under `default-src 'none'` with the script and style pinned by hash and
`connect-src` limited to the probed hosts. Every destination is built by the
Worker from the fixed `GATEWAYS` allowlist and a charset-checked CID. The page
never builds a URL from input. The site's inbrowser address is probed at its
root, so no path or query leaves the page. Orbitor is only contacted once
inbrowser is ruled out.

### `?gw=` is ignored

Links the app minted carry `?gw=` (for example `?gw=filebase`). The Worker
strips it and every browser follows the same chain. Honouring it would send
links minted under a Filebase default to the one gateway that breaks forms and
inline scripts. Filebase is still reached automatically whenever nothing before
it works.

### One exception: pages that cannot render on inbrowser (no republish)

A published page is immutable, so where it can render is fixed when it is
published. The Worker reads the entry page (`browserChain` in `site-page.js`).
A **version-1** page (relative `../<cid>` assets with `data-fx-try`, no
`data-fx-v`) that references anything relatively besides plain `<img src>` (a
video, a download, a subpage, a CSS background) starts at **orbitor**. On a
subdomain gateway those references resolve inside the page's own CID and 404,
and that pipeline's fallback only rescues images.

Every other page starts at inbrowser, including sites published before relative
assets. Only inbrowser's service worker still serves their absolute `dweb.link`
images (dweb.link was shut down on 2026-09-21). A page that cannot be read
in time gets the full chain.

The page is read from **Filebase and the fx gateway at once**. The first to
answer with HTML wins, and the result is edge-cached for a year (the bytes never
change), with a longer timeout plus one retry for crawlers. Two sources, because
one is not reliable enough: Filebase took 26–30 s for a live site's page while
fx served the identical bytes in 1.8 s (measured 2026-09-23). This is the
Worker reading on its own behalf. A published site still loads from whichever
gateway the visitor lands on, so there is **no runtime dependency on fx**.

### Crawlers and other clients

- **Link-preview crawlers** (Facebook, X, LinkedIn, WhatsApp, Slack, Telegram,
  Discord, …) get a 200 page of Open Graph tags built from the site. The page
  uses its declared `og:` tags; otherwise its `<title>`, the meta description
  or first real paragraph, and the first image. The image is re-pointed at
  Filebase, since the host a legacy page names may be dead. Every value is
  decoded, capped and escaped, and the page is served under
  `Content-Security-Policy: default-src 'none'`.
- **In-app browsers** (Instagram, Facebook, WhatsApp, …) are browsers and get
  the launcher. Where they have no service workers (iOS WKWebView), the
  capability check skips inbrowser. The crawler list holds crawler tokens only:
  an in-app browser often carries its app's name (`Snapchat/…`, `Line/…`,
  `[Pinterest/iOS]`), and matching those once handed people the preview page
  instead of the site.
- **Every other non-browser client** (search engines, curl, libraries), and
  any `HEAD`, is redirected to the path-style Filebase URL. Nothing can be
  checked for them, and inbrowser answers non-browsers with 403.

### dweb.link is retired — do not re-add it

The IPFS Foundation **shut dweb.link down permanently on 2026-09-21**
(gatewaychanges.ipfs.io). The HTTP 429s seen beforehand, with a `Retry-After` of
around half an hour, were its announced escalating pauses, not load. The app
makes the matching move: `IpfsGatewayHelper` lists the dweb template in
`retiredTemplates`, which migrates any user still holding it onto the current
default at startup.

`GATEWAYS` in the Worker is a **fixed allowlist**, and that is load-bearing:
this is a link anyone can share, so accepting a caller-supplied destination
host would turn it into an open redirector. Adding a gateway means adding an
entry to `GATEWAYS`, a place in `browserChain`, and its origin to the
launcher's CSP (`launcherCsp`) if the launcher must check it.

## Resilience — what actually depends on what (measured 2026-05-30)

- **No secrets, no state, no app credential.** The app never calls Cloudflare;
  it only publishes the signed IPNS record to w3name (with a key it holds
  locally). This Worker just *reads* the public w3name record and redirects, and
  anyone can redeploy it from this file.
- **Name → CID resolution depends on this Worker + w3name.** Both are non-fx and
  highly available, but they *are* the dependency. Publishing to w3name stores
  the record in w3name's HTTP API (which this Worker reads) — it does **not**
  put it on the public IPFS **DHT**, so a bare `https://<ipnsName>.ipns.dweb.link/`
  does **not** resolve on a plain gateway today (verified: it 500s). The Worker's
  fallback to that URL only becomes useful once the record is DHT-published (see
  the next section).
- **Content (the CID) IS fully decentralized.** The blox ipfs-cluster announces
  it to the public network — verified retrievable via `dweb.link` (HTTP 200).
- **Net:** the shared link survives **fx** being down. It does **not** survive
  **Cloudflare + w3name both** being down (until the optional step below).

## Optional: full any-gateway resilience (DHT publish)

To make `<ipnsName>.ipns.dweb.link` resolve on *any* gateway with no dependency
on this Worker or w3name, the signed IPNS record must also be on the IPFS **DHT**.
The natural place is the blox cluster / `fula-api`, which already runs IPFS nodes
that announce content: the app hands the (already-signed) record to a small
backend endpoint at publish time, and a node does the DHT announce. Publishing-
time backend involvement is fine (fx is up at generation time); *resolution* then
stays fully decentralized. Not implemented yet — tracked as a follow-up.

## Deploy

```bash
cd cloudflare
npx wrangler login          # one-time, authorizes your Cloudflare account
npx wrangler deploy         # publishes the Worker
```

`wrangler.toml` is preconfigured for the `fxfiles.top` zone with the route
`fxfiles.top/w/*`. For that route to attach, the **apex `fxfiles.top` needs a
proxied (orange-cloud) DNS record** — if you don't already have one, add a dummy
`AAAA  fxfiles.top  100::` (proxied) in the Cloudflare DNS dashboard, then
redeploy. (Cleaner alternative: a subdomain Custom Domain — see the commented
block in `wrangler.toml` — which auto-creates DNS.)

Without any route you can still test at
`https://fxfiles-link-resolver.<your-subdomain>.workers.dev/w/<name>`.

## Wire it to the app

The app builds each group's front-door URL as `{base}{ipnsName}` where `{base}`
defaults to `https://fxfiles.top/w/` (constant `IpnsPointerService.defaultWorkerBase`).
If you deploy to a different host, set the secure-storage key
`SecureStorageKeys.websiteLinkWorkerBaseUrl` to your base (e.g.
`https://fxfiles-link-resolver.<subdomain>.workers.dev/w/`). Pointers store their
`frontDoorUrl` at mint time, so a base change only affects newly-minted groups.

## Notes

- The launcher page and every redirect carry `Cache-Control: max-age=30` (a
  redirect is **302**, never 301), so a regeneration propagates within ~30s
  while still allowing edge caching.
- inbrowser is **subdomain-style**, so the CID lands in a hostname: a CIDv0
  (`Qm…`, base58 and case-sensitive) or a CID over the 63-character DNS label
  limit would silently corrupt there, and skips inbrowser (orbitor, then Filebase).
- Responses carry `Vary: User-Agent` — the answer depends on the client.
- The Worker rejects paths whose name isn't a plausible `k51…` IPNS name, and
  charset-checks the CID before interpolating it, so it can't be abused as an
  open redirector.
- When w3name is unreachable the Worker returns a plain **502**. It used to
  redirect to `{name}.ipns.dweb.link`, which never resolved (w3name does not
  publish to the DHT) and is now a dead host — redirecting there only turned our
  error into a more confusing one.
