# FxFiles stable-link resolver (Cloudflare Worker)

A **stateless** Worker that is the fast, pretty front door for the app's stable
per-website links. It resolves a group's IPNS name to its current CID and sends
the visitor to an immutable IPFS gateway URL.

```
GET https://fxfiles.top/w/<ipnsName>            -> 302 https://<cid>.ipfs.inbrowser.link/
GET https://fxfiles.top/w/<ipnsName>/page.html  -> 302 https://<cid>.ipfs.inbrowser.link/page.html
```

## Choosing a gateway (`?gw=`)

An optional `?gw=` selects which gateway a browser lands on:

```
GET /w/<ipnsName>                 -> 302 https://<cid>.ipfs.inbrowser.link/   (default)
GET /w/<ipnsName>?gw=filebase     -> 302 https://ipfs.filebase.io/ipfs/<cid>/
GET /w/<ipnsName>?gw=fx           -> 302 https://ipfs.cloud.fx.land/gateway/<cid>/
```

The app appends this automatically from the gateway chosen in Settings, so a
user who switches gets working links without re-minting anything.

### The page decides when it has to (no republish)

A published page is immutable, so where it can render is fixed when it is
published. The Worker reads the entry page (edge-cached for a year — the bytes
never change) and overrides `?gw=` when the page cannot render there
(`chooseGateway` in `site-page.js`):

| Page | Browser lands on | Why |
|---|---|---|
| Published before relative assets (no `data-fx-try`) | inbrowser, always | Every asset is an absolute `dweb.link` URL. dweb.link answers 429 and is off from 2026-09-21; inbrowser's service worker intercepts those URLs and serves them (measured: images, video, documents). |
| Relative assets, images only (`data-fx-try`, no `data-fx-v`) | inbrowser | Its fallback rescues images there, and inbrowser runs the inline scripts and Google Forms embeds Filebase's CSP blocks. |
| Relative assets plus video / links / CSS backgrounds | filebase | Those references only resolve on a path gateway. |
| Declares `data-fx-v="2"` or later | as asked | The page rewrites its own references on subdomain gateways. |
| Could not be read in time | as asked, but `filebase` becomes inbrowser | Filebase just failed to serve it. |

### Crawlers and other clients

inbrowser is a **service-worker gateway**: without a browser it answers 403 or
a bootstrap page. So:

- **Link-preview crawlers** (Facebook, X, LinkedIn, WhatsApp, Slack, Telegram,
  Discord, …) get a 200 page of Open Graph tags built from the site: its
  declared `og:` tags, else `<title>`, the meta description or first real
  paragraph, and the first image — re-pointed at Filebase, since the host a
  legacy page names may be dead. Every value is decoded, capped and escaped,
  and the page is served under `Content-Security-Policy: default-src 'none'`.
- **In-app browsers of social apps** (Instagram, Facebook, Messenger, Threads,
  TikTok, Snapchat, LinkedIn, LINE, WeChat, Pinterest) are redirected to the
  path-style Filebase URL. On iOS they are WKWebView, which has no service
  workers, so inbrowser.link would show its "Service Worker Required" page
  instead of the site. On Filebase every page renders — a pre-relative-assets
  site without its dweb.link images there. Telegram's in-app browser sends a
  plain Safari user agent and cannot be recognised.
  The crawler list holds crawler tokens only: an in-app browser often carries
  its app's name (`Snapchat/…`, `Line/…`, `[Pinterest/iOS]`), and matching those
  once handed people the preview page instead of the site.
- **Every other non-browser client** (search engines, curl, libraries) is
  redirected to the path-style Filebase URL.

### dweb.link is retired — do not re-add it

The IPFS Foundation **shut dweb.link down permanently on 2026-09-21**
(gatewaychanges.ipfs.io). The HTTP 429s seen beforehand, with a `Retry-After` of
around half an hour, were its announced escalating pauses — not load.

`dweb` is therefore absent from `GATEWAYS`, and that is deliberate in a way
worth spelling out: links minted while dweb was the default carry an **explicit**
`?gw=dweb`, and an explicit key normally beats the default. But that "choice"
was manufactured by the default rather than made by anyone, so honouring it
would send those links to a dead host. Dropping the key makes them fall back to
the default instead. The app makes the matching move — `IpfsGatewayHelper`
lists the dweb template in `retiredTemplates`, which migrates any user still
holding it onto the current default at startup.

`GATEWAYS` in the Worker is a **fixed allowlist**, and that is load-bearing:
this is a link anyone can share, so accepting a caller-supplied destination
host would turn it into an open redirector. The app therefore sends `?gw=` only
for a *preset*; a user's custom gateway template governs their own asset URLs
but is not honoured here, and such links fall back to `DEFAULT_GATEWAY`. An
unknown or absent key falls back the same way rather than erroring, so a typo
still resolves. Adding a gateway means adding an entry to `GATEWAYS` here **and**
to `_frontDoorKeys` in `lib/core/services/ipfs_gateway_helper.dart` — a key on
one side that the other does not know is silently ignored.

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

- Redirect is **302** (never 301) with `Cache-Control: max-age=30`, so a
  regeneration propagates within ~30s while still allowing edge caching.
- inbrowser is **subdomain-style**, so the CID lands in a hostname: a CIDv0
  (`Qm…`, base58 and case-sensitive) or a CID over the 63-character DNS label
  limit would silently corrupt there, and is served from Filebase instead.
- Responses carry `Vary: User-Agent` — the answer depends on the client.
- The Worker rejects paths whose name isn't a plausible `k51…` IPNS name, and
  charset-checks the CID before interpolating it, so it can't be abused as an
  open redirector.
- When w3name is unreachable the Worker returns a plain **502**. It used to
  redirect to `{name}.ipns.dweb.link`, which never resolved (w3name does not
  publish to the DHT) and is now a dead host — redirecting there only turned our
  error into a more confusing one.
