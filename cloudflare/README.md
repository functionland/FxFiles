# FxFiles stable-link resolver (Cloudflare Worker)

A ~40-line **stateless** Worker that is the fast, pretty front door for the
app's stable per-website links. It resolves a group's IPNS name to its current
CID and 302-redirects to the immutable IPFS gateway URL.

```
GET https://fxfiles.top/w/<ipnsName>            -> 302 https://<cid>.ipfs.dweb.link/
GET https://fxfiles.top/w/<ipnsName>/page.html  -> 302 https://<cid>.ipfs.dweb.link/page.html
```

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
- Assumes CIDv1 (subdomain gateway). The app's default gateway template is the
  same `https://{cid}.ipfs.dweb.link/`. To use a different gateway, change
  `GATEWAY_HOST` in `ipns-resolver-worker.js`.
- The Worker rejects paths whose name isn't a plausible `k51…` IPNS name, so it
  can't be abused as an open redirector.
