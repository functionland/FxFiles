# FxFiles → fula-api → pinning-service: Security & Durability Audit

**Date:** 2026-06-10
**Auditor:** Claude (Fable 5), with independent review by Gemini (Google). Cursor and Codex advisors were rate-limited and did not contribute.
**Scope:** `E:\GitHub\FxFiles` (Flutter client), `E:\GitHub\fula-api` (Rust S3-over-IPFS gateway + embedded `fula-client`/`fula-crypto`), `E:\GitHub\pinning-service` (Go IPFS Pinning Service API).
**Method:** Read-only source review. Findings below are backed by `file:line` evidence. No code in any target repo was modified.

**Two audit goals:**
1. **Confidentiality** — uploaded data must not let an attacker read another user's files/data.
2. **Durability** — a user's uploaded data must never be lost or become inaccessible.

---

## Executive summary

**Goal 1 (Confidentiality): Mostly sound, with one serious flaw in the default sign-in mode.**
The architecture is genuinely end-to-end encrypted: FxFiles **always** encrypts file content client-side before upload (no plaintext path exists), and the server is explicitly designed assuming blocks are opaque ciphertext. Per-user tenant isolation on the S3 path is correctly enforced. **However**, the *default* sign-in mode for legacy Google/Apple users ("Mode A") derives the master encryption key from the user's OAuth identity with **no user-held secret** — the key's entire strength rests on the OAuth `sub` identifier, which the system itself treats as a non-secret and routes through multiple services. Combined with a publicly-walkable per-user index and a by-CID block-read endpoint, disclosure of a target's `sub` (via the issuer, a relying party, or logs) yields **full offline decryption of that user's content**. Mode B/C (seed-based) fix this and are the right direction, but Mode A remains the default with no migration.

**Goal 2 (Durability): Strong engineering, with residual single-node and cross-service risks.**
fula-api has mature GC-safety: a fresh block is locally pinned (fatally) and durably queued before the upload is acknowledged, and a background **verifier** re-drives under-replicated cluster pins, guarded by replica-under-counting, a 300 s settle window, and a circuit breaker. Multiple recovery layers exist for index loss. The residual risks are (a) an acknowledged-but-not-yet-replicated write lives only on the master until replication completes (single-node-loss window), (b) the Go pinning-service has **no per-CID reference counting**, so any user who learns a CID can force a cluster-wide unpin, and (c) once `auto_drop` is re-enabled, a dropped block leaves the verifier's safety net.

**Single most important caveat:** The component that actually verifies OAuth tokens and seed proofs and mints JWTs is an **external "token issuer" service that is NOT in any audited repo** (confirmed at `fula-api/crates/fula-crypto/src/effective_user_id.rs:10-13`). The correctness of authentication — audience checks, replay protection, that a user can only get a token for their own identity — could not be verified here and must be audited separately. fula-api itself does **not** re-check token audience/issuer/expiry.

---

## Findings (severity-rated)

| # | Finding | Goal | Severity |
|---|---------|------|----------|
| F1 | **Mode A** master key derived from OAuth identity with no user secret; sole protection is the non-secret OAuth `sub`. Default for legacy users. | Confidentiality | **High → Critical** (for Mode A users) |
| F2 | Per-user index published (IPNS + on-chain) is walkable to enumerate content CIDs; `GET /api/v1/blocks/{cid}` serves any pinned block to any authenticated user. Enables F1; also a standing metadata leak (file counts/sizes/timing) even for Mode B/C. | Confidentiality | **Medium** (High as F1 enabler) |
| F3 | fula-api validates JWTs with no audience/issuer/expiry check; tokens never expire by design; single shared `JWT_SECRET`; identity verification delegated to an unaudited external issuer. No token revocation path. | Confidentiality / Integrity | **High** |
| F4 | Share-read endpoint `/admin/fetch/{bucket}/{*key}` does no share-token check and no owner scoping (first match across all tenants); all authorization delegated to an external web viewer. Loopback-gated. | Confidentiality | **Medium** (latent High) |
| F5 | Historical PII leak: pre-v0.4.2 per-object `owner_id` stored the raw JWT sub (plaintext email for legacy users) in publicly-walkable tree leaves, published via IPNS + on-chain. PII sweep remediates current state; **on-chain events are permanent**. | Confidentiality / Privacy | **Medium → High** (affected legacy users) |
| F6 | Go pinning-service has **no per-CID reference counting**: any user's `DELETE /pins` unpins that CID cluster-wide. A user who learns a victim's CID can pin-then-delete to force an unpin. Composes with F2 (CID enumeration) and F8 (auto_drop). | Durability | **Medium → High** |
| F7 | Acknowledgment (HTTP 200) is returned after master-local GC-safety but **before** cluster replication. A 200'd-but-unreplicated write exists only on the master; master disk loss before replication = permanent loss. Window grows during backlog drains. | Durability | **Medium** |
| F8 | `auto_drop=true` (the code default) drops the master's only complete copy once cluster status reports ≥ min_repl holders. Relies on cluster status accuracy. Well-guarded for transient errors (under-count + settle + breaker); residual is a sustained cluster-status lie. Currently run `false` (replicate-only). | Durability | **Medium** |
| F9 | Best-effort backlog enqueue: if enqueue fails after a (fatal) local pin, a block can be locally-pinned-but-never-replicated unless the optional startup backfill re-scans it. Circuit-breaker / "possible data loss" conditions log but do not page. | Durability / Ops | **Low → Medium** |
| F10 | Forest/index root is the highest-leverage accessibility target (its loss = total account inaccessibility) but is replicated at the same factor as leaf content. Mitigated by multiple recovery layers. | Durability | **Low → Medium** (hardening) |

---

## What is working well (credit where due)

- **Mandatory client-side encryption.** `fula_api_service.dart` always constructs an `EncryptionConfig` with a required 32-byte `secretKey` and `ObfuscationMode.flatNamespace`; there is no code path that creates an unencrypted client, and uploads are gated on `FulaApiService.isConfigured` which requires a non-null key. Encryption keys/seeds are never logged (only length) and never sent to the server.
- **Correct S3 tenant isolation.** Buckets are namespaced `{BLAKE3("fula:user_id:"||sub)[..16]}:{bucket}`; every object/bucket handler opens via `open_bucket_for_user(&session.hashed_user_id, ...)`. `resolve_keys` checks `bucket_exists_for_user`; storage keys are caller-derived secrets.
- **Mode B/C** (seed/passphrase) properly mix a high-entropy user secret into key derivation — the correct fix for F1.
- **Mature durability**: fatal local-retain before ack, durable redb pin queue with backoff, verifier re-drive, replica under-counting + 300 s settle + circuit breaker, `retain_with_leaves` for large files, and multiple index-recovery paths (`recover_bucket_index`, `resolve_keys`, `block_by_cid`, client forest-walk).
- **PII-safety care**: logs use hashed user IDs; the rate limiter is keyed on the hash; the PII sweep exists and is carefully crash-safe.
- **Safe operational posture**: running `auto_drop=false` (replicate-only) during the backlog drain is the right call.

---

## Goal 1 — Confidentiality (cross-tenant exposure)

### The keystone: the security model **explicitly** rests on client-side encryption

The server is designed assuming every block is opaque ciphertext, and it deliberately does not treat CIDs as secret:

- `block_by_cid.rs:9` — *"A cross-user fetch leaks nothing anyway (blocks are encrypted client-side), so this is defense-in-depth."* `GET /api/v1/blocks/{cid}` returns **any** pinned block to **any** authenticated user (it only checks the CID is pinned on the platform, not that the caller owns it).
- `admin.rs:1043-1048` — *"anyone with the global users-index CID can walk down to a bucket's Prolly Tree and read every object's … in plaintext."*

This is a defensible design **only if** (a) content is always encrypted and (b) the key is strong. (a) holds (confirmed below). (b) fails for Mode A.

### F1 — Mode A key derivation has no user secret *(High → Critical for Mode A users)*

**Mechanism.** `auth_service.dart:628` builds the key-derivation input as:

```dart
final input = '${_currentUser!.provider.name}:${_currentUser!.id}:$email';   // "google:<oauth_sub>:<email>"
_encryptionKey = await fula.deriveKey(context: 'fula-files-v1', input: utf8.encode(input));  // Argon2id
```

`provider` ∈ {google, apple} and `email` are not secret. The only entropy is the OAuth `sub`. OAuth treats `sub` as an **identifier, not a credential**: it is embedded in every ID token, seen by this system's external issuer service, and (for Google) returned identically to relying parties. It is high-entropy (~70 bits) so it cannot be brute-forced from the email alone — but it is **not defended as a secret**.

**The encryption keypair is derived from this key.** FxFiles passes *only* the 32-byte secret across the FFI boundary; it stores/syncs **no** separate content keypair (confirmed by grep — the only stored keypairs are disposable share-link keys, per-group website IPNS keys, and the Mode B/C signing seed). The SDK exposes `derivePublicKeyFromSecret` (`collaboration_service.dart:181`), and the same deterministic-derivation pattern is visible in-repo (`nft_wallet_service.dart:16`: `nftPrivateKey = HMAC-SHA256("nft-wallet", encryptionKey)`). Mode A also supports cross-device restore from OAuth credentials alone — only possible if the keypair is re-derivable from the credential-derived secret. **Therefore: deriving the Mode A secret yields the X25519 private key that unwraps every per-file DEK.** (The exact SDK derivation is closed-source; this conclusion is corroborated four independent ways but not read directly.)

**End-to-end attack (targeted, Mode A victim):**
1. Obtain the victim's OAuth `sub` — from the external issuer (which sees every sub), a breached/malicious Google relying party, or logs/caches. (`email` is known; `provider` is trivial.)
2. Compute `hashed_user_id = BLAKE3("fula:user_id:"||sub)` (`state.rs:17-24`).
3. Locate the victim's published bucket root CID in the per-user index (published via IPNS + on-chain, F2).
4. Walk the (plaintext-structured) Prolly Tree to enumerate per-object content CIDs.
5. Fetch ciphertext via the public IPFS DHT or `GET /api/v1/blocks/{cid}` (F2).
6. Run Argon2id locally over `provider:sub:email` → master secret → derive X25519 key → unwrap DEKs → **decrypt**.

The only non-trivial step is (1). Because the sub is the *sole* protection and the system routes it through multiple services, this is a categorical weakness for an E2EE system's default mode. **Not** exploitable by "anyone who knows your email," but fully exploitable on sub-disclosure.

**Recommendation:** Treat Mode A as deprecated. Migrate users to Mode B/C (seed-mixed) and/or require a user secret. At minimum, document the residual ("sub disclosure ⇒ content decryptable") and prioritize migration. This is consistent with the team's own F-A1/F-A3 redesign.

### F2 — Public CID enumeration + open by-CID block read *(Medium; High as F1 enabler)*

Even with perfect content encryption (Mode B/C), the following metadata is exposed to anyone who can map a user → their published index entry: number of files, per-object ciphertext sizes, and upload/modification timing (IPNS updates, on-chain anchors). The by-CID endpoint (`block_by_cid.rs:29-75`) and public IPFS DHT make ciphertext retrievable once CIDs are enumerated. For Mode B/C this is "only" a metadata/traffic-analysis leak; for Mode A it completes the F1 content break.

**Recommendation:** Scope `GET /api/v1/blocks/{cid}` to CIDs the caller owns (or to a recovery-token flow) rather than any-authenticated-user; consider not publishing per-user roots in a way that is trivially linkable to an identity hash derived from the email.

### F3 — Token revocation does not reach the data path; no expiry/audience binding *(High)*

`middleware.rs:79` calls `validate_token(&token, secret)` — the **default** config — so `auth.rs:82` disables `exp`, and issuer/audience are never set (the `with_issuer`/`with_audience` builders at `auth.rs:57-65` exist but are unused). Consequences:

- **Revocation exists at the pinning-service but NOT at fula-api.** The Go pinning-service validates the bearer token by a **database session lookup** (`middleware.go:71` → `GetUserIDFromToken`), and `DELETE /auth/token` → `DeleteSession` (`user_api_controller.go:41`, `postgres_service.go:817`) immediately invalidates it there — so revoking a key/session does cut off **pin-management** access (and the docs advertise "API keys … can be revoked at any time"). **However, fula-api — the S3 gateway that actually stores and serves the encrypted file data — validates the JWT *cryptographically* (HS256), with no session lookup and no `exp`.** Because `claims_to_session` (`auth.rs:112-114`) recomputes `expires_at = now()+1h` on every request for a token that carries no `exp`, a no-`exp` token never expires. So **deleting the session does not stop a captured JWT from reading/listing/deleting/overwriting that user's objects on fula-api** — the only remedy at the data path is rotating `JWT_SECRET` (which invalidates everyone). The revocation UX may therefore give false confidence that "deleting the key" cut off access to the files, when it did not.
- **No audience binding.** The moment any second service signs with the same `JWT_SECRET` for a different purpose, those tokens are valid against fula-api (token confusion).
- **Single shared secret + external issuer.** A `JWT_SECRET` leak lets anyone mint a token for any `sub`. OAuth/seed verification and minting live in an unaudited external service (`effective_user_id.rs:10-13`).

Even under F1's caveat (a stolen token can't *decrypt* without the key), a forever-valid, non-revocable-at-the-gateway token can **delete/overwrite** a user's files (composes with durability).

**Recommendation:** Make fula-api honor revocation — e.g., check a session/`jti` denylist (the pinning-service already has the session table), or issue short-lived JWTs with refresh so revocation takes effect within the token lifetime. Also enforce `exp`, and set + validate `aud`/`iss`. Audit the external issuer separately (audience/issuer checks, seed-proof replay/nonce).

### F4 — Share-read endpoint has no intrinsic authorization *(Medium; latent High)*

`admin_fetch_object` (`admin.rs:878-1029`) is loopback-only + admin-JWT, but it (a) performs **no** share-token validation (doc comment: *"Does not validate share_id"*) and (b) calls `find_object_in_bucket(bucket_name, key)` which searches **all** tenants and returns the first match — no owner scoping. In practice the keys are random per-file storage keys (FlatNamespace), so first-match collisions are unlikely and a wrong-tenant object would fail to decrypt anyway; but the endpoint is a fully-trusted cross-tenant data tap whose safety depends entirely on (1) the loopback boundary and (2) a correct, unaudited external web-viewer enforcing share authorization. Any SSRF or co-located request-forgery that reaches loopback becomes an arbitrary-tenant ciphertext read.

**Recommendation:** Pass and validate a share token (binding owner + path scope) inside this handler; scope the lookup to the share's owner; don't rely solely on loopback + an external service.

### F5 — Historical PII (email) leak, partly irreversible *(Medium → High for affected users)*

Documented at `admin.rs:1035-1128`: before v0.4.2, per-object `owner_id` was set to the raw JWT sub — **plaintext email** for legacy users — and stored in publicly-walkable, pinned, IPNS-published, **on-chain-anchored** tree leaves. The PII sweep (`pii_sweep`) rewrites current state to the hashed form, but old root CIDs persist until cluster GC, IPNS records expire in ~36 h, and **chain `Published` events are permanent** — affected users' emails remain resolvable in the contract event log. There is no chain-side remediation short of contract redeploy.

**Recommendation:** Run the sweep + cluster pin removal for all affected buckets; document the residual on-chain exposure and notify/transition affected legacy users; ensure no future identity-linked plaintext is anchored on-chain.

---

## Goal 2 — Durability (data must not be lost or inaccessible)

### Acknowledgment semantics (what a 200 guarantees)

On `put_object` success, in order: block written to local store → **fatal** local-retain pin (`local_retain.rs:274-299`; PUT 5xx's if the pin fails) → registry persisted → cluster-pin request enqueued to a **durable** redb queue → (large files) `retain_with_leaves` pins each leaf locally. So a 200 guarantees the block is **GC-safe on the master** and **durably queued for replication** — but **not yet replicated**.

A background verifier (`local_retain.rs:484-645`, spawned `server.rs`) sweeps the backlog (256 CIDs/cycle, 8 concurrent), and per CID either **re-drives** the cluster pin if under-replicated, or **drops** the master copy once ≥ min_repl non-master holders report `"pinned"`. The drop is conservatively gated: replica count **under-counts** (only confirmed `"pinned"`, excludes the master — `local_retain.rs:90-101`), requires a **300 s settle** window of stable replication, and is suppressed while the cluster-status **circuit breaker** is open (`decide()`, `local_retain.rs:152-171`).

### F7 — Single-node-loss window *(Medium)*

Because 200 is returned before replication, every acknowledged-but-unreplicated block exists **only on the master**. If the master's disk is lost before the verifier completes replication, those writes are gone. This is an inherent ack-then-replicate tradeoff; it is mitigated (the block is GC-safe locally, and the verifier actively drives replication), but the exposure equals the current count of unreplicated backlog entries — which can be **large during a backlog drain**. The "stuck backlog" warning fires only after 1 h (`STUCK_AGE_WARN_SECS`).

**Recommendation:** Monitor backlog depth as a first-class durability SLI; alert on growth. Consider an option to gate 200 on ≥1 remote holder for high-value writes (e.g., forest/index roots).

### F6 — Cross-tenant unpin: no per-CID refcount *(Medium → High)*

**Verified against source (not a false positive).** `DELETE /pins/{id}` (`api_pins_service_postgres.go:139-176`) does check ownership — but only of the **requestid** (`pinOwnerMatches`, line 158), i.e. that you own the pin *record* you are deleting. It then calls `unpinFromCluster(cid)` (line 166), which calls `s.ipfsClusterAPI.Unpin(ctx, cid)` **directly** (line 544) with no further check. Pins *are* tracked per-user in the Postgres `pins` table (rows per `(user_id, cid, requestid)`), and `MarkPinAsDeleted` (line 171) soft-deletes only the caller's own row — but that per-user DB tracking **does not gate the cluster unpin**, and ipfs-cluster pins are keyed by CID only (no per-user/per-bucket cluster pin). So the unpin is global-per-CID regardless of other users' still-`pinned` rows for the same CID. A grep of the whole repo found **no** reference-count / "is this CID still pinned by anyone else?" query anywhere in the unpin path.

**Attack:** the attacker `POST /pins {cid: X}` for a victim CID X they learned (F2's public index enumeration hands them the list for Mode A victims; CIDs also leak via share links / public DHT) — this creates the attacker's *own* pin row for X. They then `DELETE` their own requestid: the ownership check passes (they own that record), and `unpinFromCluster(X)` removes X from the cluster even though the victim's `(victim, X)` row is still `pinned`. Next cluster GC reclaims X → victim's data is gone. (Note: it is not even strictly cross-tenant — deleting any one of multiple pin records for a CID unpins it for all references.)

**Mitigations today:** fula-api uses random per-file DEKs, so cross-user *content* CID collisions are rare (the attacker must specifically target a known victim CID, not collide by accident); and fula-api's local-retain verifier would re-drive a maliciously-unpinned CID **if it is still tracked** in the backlog — which, with `auto_drop=false` (current posture), it is, and the master keeps a local copy throughout, so today the impact is a transient self-healing unpin for fula-api-stored data. That protection disappears for CIDs fula-api no longer tracks (dropped under `auto_drop=true`, F8) or never tracked. That "if" is the gap.

**Recommendation:** Add per-CID reference counting (or owner-scoped cluster-pin metadata) in the pinning-service; never issue a cluster unpin while another owner references the CID.

### F8 — `auto_drop=true` removes the safety net *(Medium)*

The code default is `auto_drop=true` (`local_retain.rs:225`). On drop, the CID is **removed from the backlog** (`local_retain.rs:603`), so the verifier no longer tracks or re-drives it. Therefore, once steady-state `auto_drop=true` resumes, a block that was legitimately dropped (deemed replicated) and is **later** maliciously unpinned (F6) or lost has **no** local safety net and can be GC'd to zero copies. The drop guard (under-count + settle + breaker) defends well against the *transient phantom-pinned* failure that caused the prior incident, but not against a sustained cluster-status inaccuracy or a post-drop unpin.

**Recommendation:** Keep `auto_drop=false` until the backlog is fully drained and replication is independently verified. When enabling, consider gating drop on a positive, independent block-fetch from ≥ min_repl non-master peers (not just self-reported status), and re-enable only with F6 fixed.

### F9 — Stranded single-copy + silent breaker *(Low → Medium)*

`retain()` pins locally (fatal) then enqueues **best-effort** (`local_retain.rs:279-281`); a crash or enqueue failure between the two leaves a block locally pinned (GC-safe) but **never queued for replication** — a single-copy-forever block the verifier never sees, unless the **optional** startup backfill (`refs local`, skippable on large stores) re-scans it. Separately, the circuit breaker and the "POSSIBLE DATA LOSS" condition (`local_retain.rs:621-627`) only log; they do not page.

**Recommendation:** Add a periodic reconciliation scan (local-pinned-but-not-queued → enqueue) independent of startup; promote the breaker-open and "possible data loss" conditions to alerting.

### F10 — Forest/index root durability *(Low → Medium, hardening)*

Losing or unpinning the forest/index root renders an account's entire listing inaccessible even if every content block survives — it is the single highest-leverage durability/accessibility target. It currently receives the same local-retain + cluster-pin + verifier protection as leaf content (no elevated replication), but is backed by several recovery layers (`recover_bucket_index`, `resolve_keys` + `block_by_cid` by-CID walk, client forest-walk). Risk is therefore contained, but concentrated.

**Recommendation:** Give forest/index roots a higher replication factor and explicit unpin protection; keep the recovery paths tested (an automated end-to-end recovery test before any `auto_drop=true` rollout).

---

## Out of scope / could not verify

- **External token issuer.** OAuth (Google/Apple) verification, seed proof-of-knowledge (Ed25519 challenge/nonce), and JWT minting are in a separate service not in these repos (`effective_user_id.rs:10-13`). Whether it checks OAuth `aud`/`iss`, prevents seed-registration replay, and only issues a token for the caller's own identity is **unverified** and is the linchpin of authentication. **Audit it separately.**
- **fula-client / fula-crypto SDK internals** (compiled into `fula_flutter.dll`; pub.dev `fula_client-0.6.6` is the Dart binding). The HPKE-keypair-from-secret derivation (central to F1) is inferred from four independent signals but not read from source. Recommend a direct review of the SDK's key hierarchy.
- **pinning-service deployed code vs. repo.** PR #28 / `c4ab2ad` (verifier/re-drive/auto_drop/settle) lives in **fula-api** (`local_retain.rs`), confirmed in fula-api git — **not** in `E:\GitHub\pinning-service` (the Go service has none of it). The durability story is fula-api's; the Go pinning-service is a thinner pin-tracker (and the F6 refcount gap is real there).

## Recommended priority order

1. **F1 + F3** — deprecate/migrate Mode A; enforce token `exp`/`aud`/`iss` + revocation; audit the external issuer. *(Confidentiality + integrity foundation.)*
2. **F6 + F8** — add per-CID refcounting in the pinning-service; keep `auto_drop=false` until drained and F6 fixed. *(Prevents cross-tenant data destruction.)*
3. **F2 + F4** — owner-scope the by-CID and share-fetch reads; validate share tokens server-side. *(Removes the enumeration/tap primitives.)*
4. **F5** — complete the PII sweep + cluster pin removal; address/notify on the permanent on-chain email exposure.
5. **F7 + F9 + F10** — backlog-depth alerting, reconciliation scan, elevated index-root replication.
