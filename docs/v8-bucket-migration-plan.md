# v8 Bucket Migration — client-side plan to unblock uploads & keep browsing fast

**Status:** design, reviewed by advisors (built-in + Gemini + Codex). Not yet implemented.
**Author context:** GC on the Fula gateway damaged some buckets' encrypted forest index; reads still work (slow) but any forest *mutation* (upload/delete/rename) throws on a gc'd interior node. The server fix (local-retain + index-node pinning) is deployed, so **new** buckets won't re-rot.

---

## 1. Goals (and how this plan achieves them)

**Goal 1 — Unblock uploads without more recovery work.**
Route all new uploads to fresh sibling buckets (`images` → `images-v8`). A fresh bucket has a genuinely *empty* forest, so the read-modify-write that currently throws on a gc'd interior node never happens → uploads succeed. *Validated in gateway/SDK source (per-bucket forest; the codebase's own recovery comment: "Building a fresh tree also sidesteps the broken root's read-modify-write"). Must still be proven live — see Phase 0.*

**Goal 2 — Keep category browsing fast.**
Legacy buckets are now **frozen** (no new writes ever). So fetch each slow legacy listing **once**, freeze it in a local cache, and in steady state only query the fast fresh v8 bucket + read the frozen cache from disk. Opening "Images" = one fast v8 list + an instant disk read, instead of a slow recovery-walk every time.

Both goals are delivered by **Phase 1** (content categories). Phases 2–4 extend the same idea to metadata/shelf and harden correctness.

---

## 2. Validated premise (why this works)

- The encrypted forest/index is **strictly per-bucket** (`forest_dek = derive_path_key("forest:{bucket}")`, per-bucket index key + cache + manifest). No single per-user forest spans buckets.
- The shared per-user structures (users-index, bucket registry) are **not read from gc-damaged blocks on the upload path** while the master is up (users-index is cold-start-only; the registry is an in-memory map persisted by full-rewrite).
- A fresh bucket loads **zero** pre-existing blocks → no missing-node failure possible.
- Fresh buckets are born in the **walkable-v8** forest format (content-addressed, self-verifying nodes) → *more* recoverable from any future gc than the old legacy buckets.

**Three caveats (all handled in the plan):**
1. Holds only while the **master gateway is up** at first write → gate migration on reachability.
2. The v8 bucket must be **created explicitly** before first upload (no auto-create-on-PUT).
3. v8 durability depends on its **client-forest (Tree-2) nodes** being pinned/replicated. **CODE-CONFIRMED (2026-06-08 source trace):** the SDK writes forest nodes via the *same* S3 `PUT /{bucket}/{key}` path as file objects (key prefix `__fula_forest_v7_nodes/…`), and the gateway's `put_object` handler pins every body via local-retain (`object.rs:412-424`) **+** a durable per-object cluster pin labelled `v8-node:{bucket}` (`object.rs:356-404`) — so forest nodes are gc-safe by the deployed fix. Phase 0 confirms it empirically (probe upload → server-side pinset check). **Not a band-aid.**
4. Loading a legacy bucket can trigger a **v7→v8 auto-migrate write-back** (a forest write) that fails on a damaged forest → the legacy read must be strictly read-only / tolerate that failure.

---

## 3. Architecture

### 3.1 Central bucket-version resolver
One module owns all name mapping (no scattered string concatenation):
- `writeBucket(base)` → `${base}-v8`
- `readBuckets(base)` → `[base (legacy, cached), ${base}-v8 (live)]`
- Generalizes to v9+ (append to read-set, bump write target). The server fix should make v9 unnecessary, but the seam is free.

Three bucket *kinds*, three migration patterns:

### 3.2 Content categories — `images`, `videos`, `audio`, `documents`
"**Frozen legacy cache + live v8**" read-merge:
- **Writes** → v8 (created+verified first).
- **Reads** → `union(legacy_cache, live_v8)`, deduped, sorted.
- **Legacy cache** is fetched once and frozen — but only when *provably complete* (see §4.1).
- `FulaObject` gains **`sourceBucket`** so each merged object routes its later download/delete/share/thumbnail to the right bucket. (`fromMap`/deserialize defaults `sourceBucket` to the legacy base for backward-compat with existing serialized objects.)

### 3.3 Metadata buckets — `tag-metadata`, `face-metadata`, `playlists`, `fula-metadata`, `website-metadata`
"**Crash-safe copy-forward**" (NOT read-merge — merging two single-manifests is incoherent). These are single JSON manifests, also mirrored to an authoritative on-device Hive box. See §4.2 for the verified sequence.

### 3.4 Shelf — `dump` / `dump-thumbs` (+ `dump-metadata`)
The shelf is special: it already has an explicit **manifest** (`dump-metadata`, with order + the 2-phase delete you recently shipped) that enumerates its items. So treat the manifest as the **controller**:
- Copy-forward `dump-metadata` → `dump-metadata-v8` (metadata pattern).
- The manifest tracks each item's **`sourceBucket`** (legacy `dump` vs `dump-v8`).
- New captures → `dump-v8` / `dump-thumbs-v8`.
- Delete + reorder live **in the manifest** (cloud, cross-device) — no separate local tombstone layer for the shelf, and no content re-upload. This avoids both the generic-merge complexity and Gemini's "reorder a legacy item" paradox.

---

## 4. The hard parts (from advisor review)

### 4.1 Legacy cache must distinguish COMPLETE from PARTIAL (Codex + Gemini + built-in)
Root-CID alone is insufficient: during server recovery the root CID changes, and a transient listing may be partial. Cache record:
```
{ userId, bucket, rootCid, itemCount, listingHash, fetchedAt, completeness }
```
Rules:
- **Freeze only a verified-complete listing** — all pages fetched, no timeout, and itemCount ≥ the Phase-0 expected count.
- **Never replace a known-complete cache with a smaller/incomplete/failed one.**
- Root-CID change → mark *stale*, refresh with **backoff / on explicit foreground refresh**, never eager per-open thrash.
- Treat an **empty** listing from a known-non-empty damaged bucket as *suspicious*, not authoritative.
- Once frozen-complete, stop revalidating (Goal 2 steady-state).

### 4.2 Metadata copy-forward must be crash-safe & verified (Codex + Gemini)
**Legacy stays source-of-truth until v8 is read back and verified — not merely written.** Per-bucket sequence:
1. **Discover** — read legacy manifest, v8 manifest (if any), local Hive. Classify each as `missing / read_ok / decrypt_failed / parse_failed / empty_valid`. **Never** interpret unavailable/decrypt-failed legacy as "empty." Mutate nothing.
2. **Import** — merge legacy → local Hive with additive/conservative rules (never delete legacy-only entries). Persist `legacy_imported_for_hash`.
3. **Prepare** — build the complete v8 manifest from authoritative local state.
4. **Verify** — write v8, then **re-read + decrypt + parse + count-check** it. Store `v8_verified_hash`.
5. **Commit** — only now mark done and switch metadata sync target to v8. Keep legacy readable as fallback for ≥1 app version.

### 4.3 Deletes need CLOUD tombstones for cross-device correctness (Gemini + Codex)
A delete on a legacy item can't mutate the immutable damaged bucket, so it's a *hide*. Local-only hide → the item reappears on a second device / after reinstall (the "ghost file"). So:
- Legacy deletes for **content categories** are recorded in a **cloud tombstone manifest** (a section in `fula-metadata-v8`: `{bucket, key, sourceRootCid, deletedAt, deviceId}`), subtracted from every device's merged view.
- A short-lived **local** tombstone is only the pending layer before the cloud tombstone syncs.
- The **shelf** records deletes in `dump-metadata-v8` (its own authoritative model) — not a separate layer.

### 4.4 Key collisions: content-hash-aware dedup (Codex)
`remoteKey` is path-based, so the same path can exist in legacy *and* v8 (re-upload). Carry **content hash/CID + size + modifiedAt** on `FulaObject` alongside `key` + `sourceBucket`:
- same key **+ same hash** → safe dedupe, prefer v8.
- same key **+ different hash** → identity collision; do **not** silently treat as the same object / silently inherit a legacy tag onto a different v8 file. Surface v8 but keep the reference policy explicit ("key overwrite = replacement" is acceptable *only if* FxFiles already treats it that way).

### 4.5 Per-bucket, per-phase durable state machine (Codex)
Not a global boolean; never infer completion from "bucket exists." Namespaced by user/gateway identity.
- **Content:** `not_started → v8_create_started → v8_create_verified → legacy_cache_started → legacy_cache_verified → active`. Uploads route to v8 after `v8_create_verified` (they do **not** need the legacy cache).
- **Metadata:** `not_started → legacy_read_verified → local_import_done → v8_write_started → v8_write_verified → active_v8`.
- Resumable: a partial run (some buckets migrated, app killed) resumes cleanly; create is idempotent; a failed cache build never caches an empty legacy view.

### 4.6 Misc hardening
- **Strict read-only legacy load** — disable / tolerate the v7→v8 auto-migrate write-back on legacy reads (§2 caveat 4).
- **Isolate** the merge/dedupe/sort for large libraries (50k+ images) to avoid UI jank (list returns the whole bucket).
- `FulaObject.sourceBucket` defaults to legacy on deserialize (backward-compat).

---

## 5. Side-effects catalog (caught & dispositioned)

| # | Side effect | Disposition |
|---|---|---|
| 1 | Sync re-uploading everything to v8 | **Safe** — sync dedup keyed by *local path* (`getSyncState(file.path)`), unchanged by bucket switch. Only new files go to v8. |
| 2 | Merged-view download/delete/share routes to wrong bucket | `FulaObject.sourceBucket` threads the real bucket to every consumer. |
| 3 | Tags/faces store key-only, no bucket | Resolve against merged list; content-hash-aware on collision (§4.4). |
| 4 | Legacy deletes fail (forest RMW) | Cloud tombstone manifest (§4.3). |
| 5 | Multi-device "ghost" deletes | Cloud tombstones, not local-only (§4.3). |
| 6 | Metadata copy-forward data loss (reinstall/cleared Hive/interrupted write) | Crash-safe verified sequence; legacy authoritative until verified (§4.2). |
| 7 | Legacy cache caches a *partial* listing permanently | Completeness-verified freeze; never downgrade (§4.1). |
| 8 | Root-CID thrash during server recovery | Freeze-when-complete + backoff refresh (§4.1). |
| 9 | Shelf reorder/delete across legacy+v8 | Manifest-controller with per-item sourceBucket (§3.4). |
| 10 | Storage/quota counts | Sum across `readBuckets` (legacy cache count + live v8). |
| 11 | Search across categories | Route through the merged list, never raw legacy list. |
| 12 | Collaboration files (store explicit `bucket`) | New shared files use v8; existing refs read legacy (still readable). |
| 13 | Share tokens encode bucket+key | New shares encode v8; resolver keeps legacy lookups indefinitely. |
| 14 | Background-sync race during migration | Gate migration step; route by resolver at queue time (atomic per file). |
| 15 | v7→v8 auto-migrate write-back breaks legacy read | Read-only legacy load (§4.6). |
| 16 | Per-tap legacy *downloads* still slow | Accepted — only *listing* is cached; Goal 2 is about category-open speed, not per-old-file open. |

---

## 5b. Feature consistency under the v8 split (code-investigated)

Verified in the FxFiles app + the Rust SDK. Verdict per feature:

| Feature | Reference model | Verdict | Change needed |
|---|---|---|---|
| **File share** — "current" & "latest" | Token wraps the file's DEK + `path_scope = storage_key`; **bucket is NOT in the token** (carried client-side). The app uploads with a **random per-upload storage_key**, so a re-upload never moves the old object. | **SAFE / neutral.** Both modes are immutable snapshots; "latest" never actually followed re-uploads (even pre-v8). New version → v8 (new key); the old share keeps serving the legacy object. | None for correctness. v8 uploads set `SyncState.bucket=…-v8` (already happens), so *future* single-file shares capture v8. |
| **Folder / category / tag share** | Server-side manifest scoped to **one majority-vote bucket**; "latest" = owner re-publishes that manifest; entries `{name, storageKey, size, token}` with a **single outer bucket**. | **BUCKET-BOUND — desyncs.** New `-v8` items are invisible (refresh trigger gated on `s.bucket==bucket`, single-bucket listing, minority dropped). Already-listed entries still resolve. | Treat `images`+`images-v8` as one logical folder: relax the refresh-trigger gate, enumerate both buckets + merge, drop the majority-vote, add a **per-entry bucket** to the manifest. ⚠️ The share **portal (pinning-webui, separate repo)** must also fetch per-entry-bucket. |
| **Website** | Site pinned → root **CID**; stable link = **IPNS (k51→w3name→CID)** + Cloudflare; asset URLs in the HTML are **CID** gateway URLs. Assets uploaded **unencrypted via direct S3 PUT** (no forest write). | **SAFE (CID/IPNS-bound).** Existing links keep resolving. Assets bypass the forest → likely **don't even hit the upload block** → migrating `website-assets` is **optional**. | Optional: repoint the one hardcoded `_assetBucket` → `website-assets-v8`. `website-metadata` → copy-forward. |
| **Collaboration** | `CollaborationFile.bucket` recorded **per file** from the file's current sync-state bucket; download/list resolves **per-item**; manifest in `fula-metadata`, link self-encodes its bucket. | **SAFE (already bucket-aware).** Mixed legacy+v8 groups resolve file-by-file; new files auto-capture `…-v8`. | None. (Manifest → copy-forward.) |
| **Shelf** | `dump-metadata` manifest: items by **id**, `order` is id-keyed; each item has `remoteKey`+`thumbnailRemoteKey` but **no bucket** (implicit to the `dump`/`dump-thumbs` constants). | **BUCKET-BOUND — needs work**, but `order`/reorder/delete are **id-keyed** so they already work across a mix once cloud ops route correctly. | Add `ShelfItem.sourceBucket` (Hive field 19, default `'dump'`) threaded to **6 spots**: item upload, thumb upload, thumb download, both delete calls, **and the `ShelfPendingDeleteEntry` tombstone**. `order`/manifest unchanged; `dump-metadata` → copy-forward. |
| **Metadata buckets** (tag/face/playlists/fula-metadata/website-metadata) | Single per-user JSON manifest, mirrored to authoritative local Hive. | Handled by **copy-forward** (§3.3, §4.2). | Crash-safe verified copy-forward. |

### ⚠️ HARD INVARIANT (surfaced by the share investigation)
**Legacy objects must NEVER be physically deleted or moved.** Every single-file share and every already-listed folder-share entry froze `(bucket, storage_key, DEK)` with **no gateway fallback** — if the legacy object disappears, the share breaks unrecoverably. This is *already* consistent with this plan (legacy is frozen/read-only; a "delete" is a client-side **tombstone hide**, not a real deletion). Two consequences:
- **Never add a "clean up / delete legacy after mirroring" step** — it would break every existing share. If legacy content must ever truly move, build a per-share bucket resolver *first*.
- A tombstone-hide does **not** revoke a share of that item (the object still serves). To actually stop sharing, use **revoke** (shareId-based, unaffected by v8). One-line UX note for the delete flow.

---

## 6. Execution plan — Claude-Code-sized phases with live E2E gates

### 6.1 Claude-Code execution model
Each phase = **one Claude Code session**, shaped to the context window (not a calendar): *read a bounded set of files → make the edits → unit-test → run the live E2E gate → commit the checkpoint.* If a phase's file surface would overflow one context, split at the marked seam (⮑). The cumulative E2E suite (6.2) is the regression backstop **across** sessions, so a later session can't silently break an earlier guarantee.

### 6.2 Live E2E strategy (your account, production gateway)
Every phase is gated by an end-to-end run against **production using your real userid + encryption key** — proving the new behavior *and* no regression ("no side effects").
- **Credentials — via the device session, never in chat/files.** The existing harness (`integration_test/helpers/test_harness.dart`) reuses the FxFiles session already signed in on the device (read from `SecureStorage` by `TestHarness.bootSignedIn`); **the encryption key never leaves the device and I never handle it at all.** You sign in once per device: your **real account** for Phases 0–3, the **dedicated test account** for Phases 4–7. Output is pass/fail + non-sensitive keys/CIDs.
- **Harness.** Flutter **integration tests** under `integration_test/scenarios/`, built on the existing `TestHarness.bootSignedIn` + `TestBucket` helpers (they already run against prod `s3.cloud.fx.land` and exercise the real `FulaApiService` path). Run: `flutter test integration_test/scenarios/<name>_test.dart -d <device>`. (Phase 0 harness already written: `scenario_p0_v8_premise_test.dart`, `scenario_p0_baseline_test.dart`.)
- **Test-data isolation.** All E2E **writes** use a reserved key prefix `__e2e/<runId>/…` in the real `…-v8` buckets (or dedicated `*-v8` probe buckets). Legacy reads are **strictly read-only**. The harness **cleans up its own v8 test objects** and **never deletes anything in a legacy bucket** (HARD INVARIANT).
- **⚠️ Account safety (destructive Phases 4–7) — REQUIRED, not optional.** The `__e2e/` prefix isolates *content* writes, but **metadata buckets are a single per-user manifest** (`.fula/tags/{userId}.json` — can't prefix-isolate a document), and Phases 5–6's "clear local Hive → restore from v8" would overwrite/wipe your **real** tags/faces/playlists on your primary account. Both external advisors call using the primary account here *reckless*. → **DECIDED: a dedicated test account** for Phases 4–7 (zero blast radius to your real tags/faces/playlists/shelf — the "clear Hive → restore" tests run against throwaway data). Content phases 1–3 run on your real account with the `__e2e/` prefix.
- **Baseline oracles (Phase 0).** Per-legacy-bucket item counts; a few `(key → expected hash)` samples; one known existing share that resolves. Later phases assert against these.
- **Cumulative regression.** Each phase appends its assertions; every run re-executes all prior ones.

### 6.3 Phases
Each: **Scope** (bounded files) · **Deliverable** (measurable) · **E2E gate** (what the live test proves) · checkpoint = commit.

**Phase 0 — E2E harness + live premise proof + baseline.**
- Scope: new `tool/e2e/`; creds wiring; **no app changes**.
- Deliverable: reusable creds-driven harness; **live proof a fresh-bucket create→upload→list→download round-trips** on prod; baseline oracles recorded.
- E2E gate: harness exits 0; fresh-bucket byte-match; **+ DURABILITY CHECK (THE #1 risk): after the v8 upload, enumerate the SDK-written client-forest (Tree-2) root + interior node CIDs — not just the file-block CIDs — and confirm they are in the cluster pinset / locally pinned.** Repeat after several writes (interior nodes change). If production can't expose forest-node CIDs / pinset membership, run on a **staging gateway where `ipfs repo gc` can be triggered**, then verify list/download/upload/delete all survive an actual gc. *Load-bearing: if forest nodes aren't pinned, v8 re-rots on the next gc and the whole migration is a temporary band-aid.* Baseline written. *Project gate — if the round-trip OR the durability check fails, stop and rethink (server-side pinning of client-forest nodes would be needed first).*

**Phase 1 — Resolver + write-routing (content categories) + v8 creation.**
- Scope: new `bucket_version_resolver.dart`; content-category upload sites (`folder_watch_service.dart:320/421`); explicit v8 create+verify by **list-after-write** (idempotent, not assumed from create success), master-up gated; minimal `v8_create_verified` state; a hard **read-only-legacy guard** (any write targeting a legacy bucket throws a dev-visible error → prevents new data leaking into damaged buckets); a **feature flag** so v8-write only activates after this phase verifies (half-shipped state stays consistent).
- Deliverable: **new content uploads land in `…-v8`**; legacy untouched; no code path can write to a legacy bucket.
- E2E gate: upload a `__e2e` file via the real upload path → assert it's in `images-v8` not `images`; a known legacy file still lists+downloads (regression). *(Goal 1 mechanically met.)*

**Phase 2 — `FulaObject.sourceBucket` + live merged read.** ⮑ *(split possible: 2a model+merge, 2b thread consumers)*
- Scope: `fula_object.dart` (+`sourceBucket`, deserialize-defaults-legacy); a `listCategory()` merge (legacy-live ∪ v8-live, dedupe prefer-v8); thread `sourceBucket` to download/delete/share/thumbnail call sites.
- Deliverable: **category view shows legacy+v8 merged; each item routes its ops to the right bucket.**
- E2E gate: merged list contains a new v8 item AND a known legacy item; download each → byte-match (correct routing); duplicate key → prefer-v8. *(Goal 1 user-visible.)*

**Phase 3 — Completeness-verified legacy cache (Goal 2).**
- Scope: legacy-listing cache box keyed `(userId,bucket,rootCid)`; completeness gate (all-pages + count≥baseline); strictly read-only legacy load (no v7→v8 write-back); freeze + backoff; Isolate for large merges. The merged read is a **virtual view**: `(legacy_cache ∪ v8_live) − tombstones`, computed live — so the frozen cache stays the *raw* legacy listing and the tombstone set (P4) subtracts at read time (no cache rewrite when an item is hidden). **Build the tombstone-subtraction seam now** (empty set until P4) so P4 doesn't force a cache/merge rewrite. *(P3↔P4 may swap order; the virtual-view seam removes the dependency.)*
- Deliverable: **steady-state category open stops querying the slow legacy bucket**; never freezes a partial listing.
- E2E gate: 1st open populates cache; 2nd open → no legacy forest fetch (instrumented) + count≥baseline; injected-partial → asserts NOT frozen; after freeze, restart/legacy-unavailable still serves the exact frozen set. *(Goal 2 met.)*

**Phase 4 — Legacy delete tombstones (local → cloud).** ⮑ *(4a local, 4b cloud-manifest)*
- Scope: tombstone box + merge subtraction; delete-legacy UX → tombstone; cloud tombstone section in `fula-metadata-v8` + cross-device pull.
- Deliverable: **hiding a legacy item persists locally and propagates across devices**; legacy object physically retained.
- E2E gate: hide known legacy item → restart → still hidden; write cloud tombstone → second harness run (device-B sim) → hidden there; assert legacy object still present.

**Phase 5 — Crash-safe copy-forward primitive + state machine.**
- Scope: reusable `MetadataCopyForward` (Discover→Import→Prepare→Verify→Commit) + per-bucket/per-phase durable state.
- Deliverable: **verified, resumable copy-forward** (legacy authoritative until v8 read-back-verified).
- E2E gate: drive on a synthetic manifest → kill mid-write → resume → no loss; decrypt-fail legacy → NOT treated as empty.

**Phase 6 — Apply copy-forward to metadata services — ONE SERVICE PER SESSION** (**P6a tags · P6b faces · P6c playlists · P6d fula-metadata [shares+collab] · P6e website-metadata**). Both advisors flag "5 services in one session" as the top context-overflow + data-loss risk → each is its own gated session reusing the Phase-5 primitive.
- Scope (per service): wire the service to the Phase-5 helper; switch cloud target to `…-v8` only post-verify.
- Deliverable (per service): **migrates with no loss across a simulated reinstall.**
- E2E gate (per service, on the test account): write `__e2e` entry → confirm in `…-v8` → clear the **isolated** Hive box → restore from v8 → assert **semantic equality vs a precomputed baseline** (not just "app starts"); legacy manifest still readable; a crash injected after Prepare/before Verify leaves the old manifest authoritative.

**Phase 7 — Shelf `sourceBucket` threading.**
- Scope: `ShelfItem.sourceBucket` (Hive field 19, default `'dump'`); thread to 6 spots (item+thumb upload, thumb download, both deletes, `ShelfPendingDeleteEntry`); `dump-metadata` copy-forward.
- Deliverable: **new captures → `dump-v8`; old items load/thumbnail/delete; reorder works across the mix.**
- E2E gate: capture `__e2e` item → in `dump-v8` + thumb in `dump-thumbs-v8`; load+thumb a known legacy item; reorder across mix → order correct; delete v8 item → tombstone targets v8.

**Phase 8 — Folder/tag share multi-bucket (app side).**
- Scope: relax refresh-trigger bucket gate; enumerate both buckets in manifest builders; drop majority-vote; per-entry bucket in manifest.
- Deliverable: **a folder/tag share includes v8 items**, per-entry bucket emitted.
- E2E gate: folder share spanning a legacy + a v8 `__e2e` item → manifest has both with correct per-entry buckets; an existing single-file share still resolves. ⚠️ **Portal (`pinning-webui`) per-entry-bucket fetch is a separate-repo follow-up** for full recipient-side resolution.

**Phase 9 — (optional) Website asset repoint.**
- Scope: `_assetBucket` → resolver.
- Deliverable: new generations write to `website-assets-v8`; existing IPNS links still resolve.
- E2E gate: publish `__e2e` site → assets in v8 + IPNS→CID resolves; a known existing site link still resolves. **Collaboration: no phase needed** (already per-file bucket-aware).

**Goal checkpoints:** Goal 1 (uploads unblocked) is *mechanically* met at **Phase 1**, *user-visible* at **Phase 2**. Goal 2 (steady-state fast) is met at **Phase 3**. Phases 4–9 extend "for everything" + harden correctness/consistency.

---

## 7. Decisions

**Settled:**
- **Shelf** = manifest-controller (§3.4 / P7) — no content re-upload.
- **Durability verification** = gated at **Phase 0** (enumerate v8 forest-node CIDs → confirm pinned; staging-GC test if prod can't expose the pinset).
- **Test isolation** = **dedicated test account** for the destructive metadata phases P4–P7; real account + `__e2e/` prefix for P0–P3 (content).
- **Sequencing** = the P0→P9 Claude-sized phases (§6.3); Goal 1 by P1/P2, Goal 2 by P3.

**Still open (non-blocking, decide before P1 — it's the resolver constant):**
1. **Suffix name** — `-v8` (apt: fresh buckets *are* born in the walkable-v8 forest format, but it collides with the SDK's "forest v8" in logs/debugging) vs. a bucket-level `-r2` / `-ext`. *Lean `-v8` unless you want the disambiguation.*

---

## 8. Advisor synthesis

- **Built-in:** prove premise live first; legacy deletes also fail → tombstone layer; root-CID-keyed cache; read-only legacy load.
- **Gemini:** cross-device tombstones (ghost-file), copy-forward must verify before abandoning legacy (reinstall trap), freeze cache when count matches expected (recovery thrash), force-migrate shelf, Isolate large merges, naming is confusing.
- **Codex:** crash-safe metadata sequence (legacy authoritative until verified); cache needs a completeness signal (never enshrine partial); content-hash-aware collision resolution; cloud tombstones for cross-device delete; per-bucket-per-phase durable state machine.
- **Cursor:** unavailable (free-tier usage cap) — not consulted this round.

All three available reviewers agree: **Goal 1 achieved** (fresh bucket bypasses the forest-RMW failure), **Goal 2 achieved** (given completeness-verified cache freezing). The required upgrades are correctness hardening, not architecture changes.
