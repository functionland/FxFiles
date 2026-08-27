# Auto-pin pairing hand-off spec (v1)

Contract between **FxFiles** (mobile, desktop, files.fx.land) and **FxBlox** (mobile app or blox.fx.land).

## Outbound (FxFiles → FxBlox)

Mobile deep link (unchanged): `fxblox://autopin-pair?token=<t>&endpoint=<e>&returnUrl=<r>`
Web: `https://blox.fx.land/autopin-pair?token=<t>&endpoint=<e>&returnUrl=<r>`

| Param | Value | Validation on the FxBlox side |
|---|---|---|
| `token` | URL-encoded cloud.fx.land JWT | non-empty; ≤ 8 KiB |
| `endpoint` | URL-encoded pinning/IPFS API base, e.g. `https://api.cloud.fx.land` | `https:` URL |
| `returnUrl` | URL-encoded **template** containing the literal placeholders `$secret`, `$hardwareId`, `$bloxPeerId`, `$bloxName` | scheme is `https:` (files.fx.land) or `fxfiles:`; all four placeholders present |

## Return (FxBlox → FxFiles)

FxBlox substitutes the placeholders and navigates (user click) to the resulting URL. Recommended template (fragment
form so the bearer secret never reaches a server):

`https://files.fx.land/autopin-complete#secret=$secret&hardwareId=$hardwareId&bloxPeerId=$bloxPeerId&bloxName=$bloxName`

`files.fx.land/autopin-complete/` is a static forwarder: on mobile it tries `fxfiles://autopin-complete?…`, otherwise
offers "Continue in web app" → `https://files.fx.land/app/#/autopin-complete?…`.

Legacy template still accepted: `fxfiles://autopin-complete?secret=$secret&hardwareId=$hardwareId&bloxPeerId=$bloxPeerId&bloxName=$bloxName`.

## Versioning

`v1` is implied. A future change adds `&v=2` to the outbound URL; receivers must ignore unknown params.
