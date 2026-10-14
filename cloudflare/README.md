# FxFiles stable-link resolver (Cloudflare Worker)

A **stateless** Worker that is the fast, pretty front door for the app's stable
per-website links. It resolves a group's IPNS name to its current CID and sends
the visitor to an immutable IPFS gateway URL.

```
GET https://fxfiles.top/w/<ipnsName>            browser  -> 200 launcher page (below)
GET https://fxfiles.top/w/<ipnsName>/page.html  browser  -> 200 launcher page, same chain for page.html
GET https://fxfiles.top/w/<ipnsName>            crawler  -> 200 Open Graph preview page (HEAD answers the same)
GET https://fxfiles.top/w/<ipnsName>            anything else, any other HEAD, or a
                                                browser request that is not a page load
                                                -> 302 https://ipfs.filebase.io/ipfs/<cid>/
```

A "page load" is a request whose `Sec-Fetch-Dest` is `document`, `iframe` or
`frame`, or a browser that sends no `Sec-Fetch-Dest`. An `<img>`, a `<video>`,
a `fetch()` or a download of a link gets the file itself from Filebase rather
than the launcher page. Redirects and the launcher carry
`Vary: User-Agent, Sec-Fetch-Dest`.

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
     resolving within 2.5 s. Settings that block site data leave the API present but
     refusing ("The user denied permission to use Service Worker"), and
     `navigator.cookieEnabled` still says `true` then, so it is not used
     (measured in Chrome, 2026-09-30). iOS in-app browsers (WKWebView) have no
     service workers; the Worker leaves inbrowser out of their chain up front
     (see "Crawlers and other clients").
  2. *Its service worker can fetch the site from this network:* the site's own
     address `https://<cid>.ipfs.inbrowser.link/` only hands over the worker.
     The worker then fetches content from `trustless-gateway.net` and asks
     `delegated-ipfs.dev` for providers. All three are probed at once
     (`no-cors`, 2.5 s cap), but they are not equally needed. Opening a
     site's inbrowser address with one host made unreachable showed this
     (Chrome, 2026-09-30):

     | Host made unreachable | inbrowser |
     |---|---|
     | `trustless-gateway.net` doesn't resolve | its own 504 after 70 s |
     | `delegated-ipfs.dev` doesn't resolve | **the site renders** (4.3 s) |
     | `delegated-ipfs.dev` silently dropped | its own 504 after 70 s |

     So the site's address and `trustless-gateway.net` must **answer**, while
     the router only has to **not stall**: failing fast is fine. That matters
     now, because its operator (IPFS Shipyard) stops running it on 2026-09-30.
     Demanding an answer would send every visitor past a working inbrowser
     once it goes.
     The service hosts are probed at API paths that answer directly
     (`/ipfs/bafkqaaa?format=raw` gives 403, still an answer;
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

Every wait is capped, and a watchdog sends the visitor to the last resort
after 10 s whatever the browser does. The slowest legitimate path is three
capped waits, 7.5 s. The visitor is sent exactly once.

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
| delegated-ipfs.dev doesn't resolve | inbrowser, site rendered | 0.4 s |
| inbrowser and orbitor blocked | Filebase | 0.4 s; 0.06 s once remembered |
| Site data blocked (no service workers) | orbitor, else Filebase | 2.9 s |
| JavaScript off | Filebase | 0.5 s |

### Where inbrowser gets a site's bytes (server-side dependency)

The launcher can only check that inbrowser's hosts are reachable. Whether a
**particular site** then loads there depends on where inbrowser's service worker
can fetch it from, and that is decided outside this Worker:

- `trustless-gateway.net` serves only inbrowser, and as of 2026-10-14 its
  backend answers browser requests with Cloudflare 521/522, even for the IPFS
  hello-world CID. (A request without inbrowser's Origin still gets a fast 403,
  which is all the launcher's probe can see.)
- So inbrowser fetches over libp2p (bitswap) from the providers that
  `delegated-ipfs.dev` returns, but only those with a **direct browser
  transport**: WebTransport with certhash, WebRTC-direct, or secure WebSockets.
  Relay-circuit addresses through `relay.fula.network` did not work.
- Our pinning server (`1.pools.functionyard.fula.network`, kubo peer
  `12D3KooWCHyz…`) pins every site. Its kubo config sets `Addresses.Announce` by
  hand, and until 2026-10-14 that list held only TCP and QUIC, so browsers never
  learned its WebTransport listener. 4 of 6 recently visited sites then had no
  browser-reachable provider and showed inbrowser's "502 Unable to stream
  content". The fix added
  `/dns4/1.pools.functionyard.fula.network/udp/4001/quic-v1/webtransport` and
  `/ip4/5.252.53.186/udp/4001/quic-v1/webtransport` to `Addresses.Announce`.
  go-libp2p appends the current certhashes. After that, all four sites rendered
  in Chrome.
- **If that list is ever rewritten, keep the WebTransport entries.** The `/ip4`
  entry hard-codes the server's address. Check with
  `curl https://delegated-ipfs.dev/routing/v1/peers/12D3KooWCHyzESdF9yzy4a7yWFVs4wYaDdLuXf6NGCvBThZvjkAR`:
  it must list a `/webtransport/certhash/…` address.
- A site also needs a current provider record on the DHT. The server's kubo
  re-announces all of its keys every 22 h (sweep provider). After an outage, a
  site can be missing until its region comes round again;
  `ipfs routing provide <cid>` announces it at once.

- The server also offers secure WebSockets, for browsers without WebTransport
  (Safari). Its AutoTLS certificate (`*.k51qzi5uqu5dh3lm….libp2p.direct`)
  expired on 2026-05-19 and could not renew: the ACME client kept asking
  Let's Encrypt to replace the expired certificate, and Let's Encrypt answers
  404 for a certificate it no longer tracks. AutoTLS also waits for a public
  `/ip4` TCP address, and kubo applies `Addresses.Announce` after AutoTLS, so
  the hand-set list hid both. On 2026-10-14 the old certificate folder
  (`p2p-forge-certs`) was moved aside, and `AutoTLS.Enabled` was set to `true`
  (otherwise kubo waits an hour before registering). Two entries were added to
  `Addresses.Announce`: `/ip4/5.252.53.186/tcp/4001` and
  `/dns4/5-252-53-186.k51qzi5uqu5dh3lmhvesbg0uniavlp7q76i3x34gggli66aqvdf183gzsoxcem.libp2p.direct/tcp/4001/tls/ws`.
  A new certificate was issued within minutes of the restart, valid until
  2027-01-12, and a WebSocket from Chrome to that address now connects. The
  same `curl` check must list a `/tls/ws` address. Both new entries hard-code
  the server's IP.
- **Renewal is unproven.** It should happen on its own about a month before
  expiry, but why the old certificate failed to renew *before* it expired is
  unknown. Around 2026-12-15, check that the served certificate has moved past
  2027-01-12:
  `openssl s_client -connect 5.252.53.186:4001 -servername 5-252-53-186.k51qzi5uqu5dh3lmhvesbg0uniavlp7q76i3x34gggli66aqvdf183gzsoxcem.libp2p.direct </dev/null | openssl x509 -noout -enddate`.
  If it hasn't, look for `autotls` errors in the kubo log (`docker logs ipfs_host`).

Still open: the launcher treats a failing `delegated-ipfs.dev` as harmless,
which is no longer true while `trustless-gateway.net` serves nothing.

**Security.** The script is a constant; per-link destinations travel in a
non-executable `<script type="application/json">` block, so the page is served
under `default-src 'none'` with the script and style pinned by hash and
`connect-src` limited to the probed hosts. Every destination is built by the
Worker from the fixed `GATEWAYS` allowlist and a charset-checked CID. The page
never builds a URL from input. The site's inbrowser address is probed at its
root, so no path or query leaves the page. Orbitor is only contacted once
inbrowser is ruled out.

The visitor's `#fragment` (for example `#contact`) never reaches the Worker,
so the launcher appends it to wherever it sends them, and to its manual links.
Two cases cannot carry it: a text fragment (`#:~:text=`), which browsers hide
from scripts, and the `<noscript>` refresh.

The launcher may be framed (no `frame-ancestors`): a link embedded in another
page's iframe gets the launcher, which then sends the frame on. Framing it gives
nothing away; it holds no data and its links go to the same site.

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
  Discord, …) get a 200 page of Open Graph tags built from the site. A
  crawler's `HEAD` gets the same answer as its `GET` (an unfurler may `HEAD`
  first and follow a redirect), but without probing images. The page
  uses its declared `og:` tags; otherwise its `<title>`, the meta description
  or first real paragraph, and the first image. The image is re-pointed at
  Filebase, since the host a legacy page names may be dead. Every value is
  decoded, capped and escaped, and the page is served under
  `Content-Security-Policy: default-src 'none'`.
- **In-app browsers** (Instagram, Facebook, WhatsApp, …) are browsers and get
  the launcher. On iOS they are WKWebView, where a site the app does not own
  gets no service workers, so the Worker recognises them (an app token plus
  `iPhone`/`iPad`/`iPod`) and sends a chain without inbrowser, without reading
  the page first. That read only decides whether inbrowser stays in the chain,
  and it kept them waiting up to 6 s. On Android, in-app browsers can run
  service workers and the launcher's own check decides. The crawler list holds crawler tokens only:
  an in-app browser often carries its app's name (`Snapchat/…`, `Line/…`,
  `[Pinterest/iOS]`), and matching those once handed people the preview page
  instead of the site.
- **Every other non-browser client** (search engines, curl, libraries), any
  other `HEAD`, and a browser request that is not a page load are redirected to
  the path-style Filebase URL. Nothing can be checked for them, and inbrowser
  answers non-browsers with 403.

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
- Responses carry `Vary: User-Agent` (redirects and the launcher also
  `Sec-Fetch-Dest`): the answer depends on the client and on whether the
  request is a page load.
- The Worker rejects paths whose name isn't a plausible `k51…` IPNS name, and
  charset-checks the CID before interpolating it, so it can't be abused as an
  open redirector.
- When w3name is unreachable the Worker returns a plain **502**. It used to
  redirect to `{name}.ipns.dweb.link`, which never resolved (w3name does not
  publish to the DHT) and is now a dead host — redirecting there only turned our
  error into a more confusing one.
