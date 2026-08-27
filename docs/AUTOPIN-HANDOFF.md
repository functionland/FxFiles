# Auto-pin pairing hand-off spec (v1.1)

Contract between **FxFiles** (mobile, desktop, files.fx.land) and **FxBlox** (mobile app or blox.fx.land).

## Outbound (FxFiles → FxBlox)

Mobile deep link (unchanged): `fxblox://autopin-pair?token=<t>&endpoint=<e>&returnUrl=<r>`
Web (v1.1, **fragment**): `https://blox.fx.land/autopin-pair#token=<t>&endpoint=<e>&returnUrl=<r>`

The web carrier puts the parameters in the URL **fragment** so the bearer `token` never reaches the
blox.fx.land server / CDN access logs, is not sent in a `Referer` header, and is not synced as part of
browser history. The custom-scheme link is routed by the OS (no server), so it keeps the query form.

**Receiver (FxBlox-web) rule:** read `location.hash` first; the v1 query form
(`https://blox.fx.land/autopin-pair?token=…`) remains **accepted as a fallback** for older senders.
FxBlox-web should `history.replaceState`-strip the fragment once the params are in memory and serve the
page with `<meta name="referrer" content="no-referrer">`.

| Param | Value | Validation on the FxBlox side |
|---|---|---|
| `token` | URL-encoded cloud.fx.land JWT | non-empty; ≤ 8 KiB |
| `endpoint` | URL-encoded pinning/IPFS API base, e.g. `https://api.cloud.fx.land` | `https:` URL |
| `returnUrl` | URL-encoded **template** containing the literal placeholders `$secret`, `$hardwareId`, `$bloxPeerId`, `$bloxName` | scheme is `https:` (files.fx.land) or `fxfiles:`; all four placeholders present |

The three values are `encodeURIComponent`-style encoded (`Uri.encodeComponent` on the FxFiles side) and
joined as `key=value&key=value`, identically for the query (native) and the fragment (web); the receiver
decodes them the same way (`URLSearchParams` on the hash string works).

## Return (FxBlox → FxFiles)

FxBlox substitutes the placeholders and navigates (user click) to the resulting URL. Recommended template (fragment
form so the bearer secret never reaches a server):

`https://files.fx.land/autopin-complete#secret=$secret&hardwareId=$hardwareId&bloxPeerId=$bloxPeerId&bloxName=$bloxName`

Substituted values MUST be `encodeURIComponent`-ed (a raw `+` would be decoded as a space by the receivers).

`files.fx.land/autopin-complete/` is a static forwarder: on mobile it tries `fxfiles://autopin-complete?…`, otherwise
offers "Continue in web app" → `https://files.fx.land/app/#/autopin-complete?…`.

Legacy template still accepted: `fxfiles://autopin-complete?secret=$secret&hardwareId=$hardwareId&bloxPeerId=$bloxPeerId&bloxName=$bloxName`.

## Versioning

- **v1** — web outbound as a query (`?token=…`). Still accepted by receivers as a fallback.
- **v1.1** (this document) — web outbound moved to the fragment (`#token=…`); return leg unchanged.

A future change adds `&v=2` to the outbound params; receivers must ignore unknown params.

## FxFiles implementation map (this repo)

- Builders + return parser: `lib/core/services/blox_pairing_links.dart` (`buildBloxWebPairUrl` → fragment,
  `buildBloxNativePairUrl` → query, `kAutopinReturnTemplate`, `parseAutopinCompleteParams`).
- Native sender / receiver: `lib/features/settings/screens/blox_pairing_screen.dart`,
  `lib/core/services/deep_link_service.dart`.
- Web receiver: `lib/web/services/web_autopin_return*.dart`, `lib/web/screens/web_blox_pairing_screen.dart`.
- Forwarder: `site/autopin-complete/index.html`.
