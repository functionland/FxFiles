# v8 Bucket Migration — Premortem (per design phase)

**Method.** A premortem assumes the change has *already shipped and caused a
production disaster*, then works backward: *what was the failure the user saw →
what root cause produced it → what early signal would have caught it → what gate
prevents it.* This is stronger than a review because it forces us to imagine the
specific way each phase kills trust in a **backup app**, where the worst outcome
is not a crash but **silent data invisibility** ("my photos are gone").

This doc is a living gate. **Every phase's design is not "done" until its
premortem below is filled in and its gates are either closed or explicitly
accepted by the owner.**

Companion: `docs/v8-bucket-migration-plan.md` (the design) and the project
memory `project-fxfiles-v8-bucket-migration` (status + commits).

---

## 0. The single most dangerous event: the flag flip itself

**Failure story.** We flip `BucketVersionResolver.enabled = true` in an app
release. Within hours, a fraction of users report missing files / failed
uploads / broken shares. Because the flag is a **compile-time `static bool`**,
there is **no way to turn it off** without shipping another app release and
waiting days for store review + user update. Every affected user stays broken
for the whole window. For a backup app, that is the reputational worst case.

**Root cause.** The kill mechanism and the failure are on different clocks: the
failure is instant and fleet-wide; the remedy is an app-store release cycle.

**Early signal.** Upload-success-rate drop, "missing files" tickets, a spike in
pull-to-refresh (users self-rescuing a bad frozen cache).

**Gate (STRONG recommendation, not yet built).** Before the flip, make the flag
**remotely controllable** (a server/remote-config value the app reads, with the
`static bool` as the *default* when remote is unreachable), so there is a
**kill-switch** and the option of a **staged rollout** (1% → 10% → 100%). A
hardcoded flip is acceptable ONLY if every pre-flip gate below is closed AND the
owner explicitly accepts "no remote off-switch." Treat remote-gating as the
default plan.

**Secondary gate.** Ship **observability first**: per-bucket upload
success/failure counters and a "frozen legacy count vs live recount" check
(see P2/B1) must exist *before* the flip, or we are flying blind during the one
event where we most need eyes.

---

## 1. P0 — premise + durability + baseline harness  *(DONE)*

**Failure story.** We "proved" a fresh bucket sidesteps the gc damage, flipped
later, and discovered fresh-bucket uploads *also* rot — the premise was wrong
and the whole migration was built on sand.

**Root cause (ruled out).** The encrypted forest/index is strictly per-bucket
(`forest_dek = derive_path_key("forest:{bucket}")`); a fresh bucket starts with
an empty forest and cannot inherit another bucket's gc'd interior nodes.
Durability was the real risk: a fresh bucket's forest nodes must be *pinned*, or
the next `ipfs repo gc` re-rots the new bucket too.

**What closed it.** Phase-0 on-device probe round-tripped a fresh bucket on prod
(byte-match, small + chunked), and the probe's forest-node CIDs were confirmed
**cluster-pinned (`replication_factor_min=2`, 6 peers)** via the cluster
`/allocations` endpoint. Plus the server-side local-retain fix (PR #28) makes gc
safe going forward. **Premise + durability proven.**

**Residual gate.** None blocking. Re-run the durability check if the gateway's
pinning/gc config changes.

---

## 2. P1 — resolver + write-routing + read-only-legacy guard + flag  *(DONE, flag-off)*

**Failure story A (uploads still blocked).** Flag on; uploads for *one* content
type still throw "broken forest node." Goal 1 (unblock uploads) silently fails
for that category because some upload path never reached the v8 router.

**Root cause.** A write that does **not** flow through the single chokepoint
`SyncService.queueUpload → writeBucket`. If any code calls
`FulaApiService.uploadObject/createBucket` directly with a base bucket, it lands
on the damaged legacy bucket.

**Early signal.** Upload failures concentrated on one category post-flip.

**Gate / mitigation.** The **write-guard is the backstop**: every write method
(`createBucket`/`upload*`) calls `_guardLegacyWrite` first and throws *loudly*
on a managed-legacy target — so a missed routing path fails visibly (a thrown
error we can see) rather than silently writing to a rotten bucket. **Pre-flip
audit: enumerate every call-site of the guarded write methods and confirm each
either routes via `queueUpload` or is an intentional non-managed write.** (Done
for the known paths: queueUpload, retry→queueUpload, restore-from-persistence→
writeBucket. Re-audit before flip in case new call-sites were added.)

**Failure story B (guard blocks a legitimate write).** Flag on; a feature that
writes to a bucket whose name *happens* to collide with the managed set breaks
because the guard refuses it.

**Root cause.** `managedBaseBuckets` is an exact-match set
`{images,videos,audio,documents}`; only those four are guarded. A metadata
bucket like `dump-metadata` or `<base>-metadata` is **not** managed → not
guarded → not routed. Verified: metadata copy-forward is P6, deliberately
separate. **Gate:** keep the managed set to exactly the four content bases;
never add a metadata/website/share bucket to it.

---

## 3. P2 / 2b — merged read + frozen legacy cache + per-item routing  *(DONE, flag-off)*

### B1 — frozen-partial masking *(THE primary pre-flip gate)*

**Failure story.** A user opens Images once. The legacy listing comes back
**truncated but reported fresh** (`stale=false`) because the gc-damaged forest
returned only the entries it could still reach. We `freeze` that partial list.
From then on the user **permanently sees fewer photos than they have** — and the
only escape (pull-to-refresh) is an action they have no reason to take. In a
backup app this reads as "the backup lost my photos."

**Root cause.** The entire safety argument rests on **`stale=false` ⇒ complete,
authoritative listing.** That is *proven* for the empty case (a non-existent
bucket → empty forest → `Ok(())` → genuinely empty) but **not proven for a
partial read of a damaged bucket.**

**Why it's probably safe (but unproven).** The forest read path appears to be
**all-or-throw**: `_ensureForestLoaded` rethrows on a failed load, and the
client-side *404 forest-walk recovery* exists precisely *because* the normal
walk **throws** when it hits a gc'd/missing node rather than silently skipping
it. A throw → our `catch` → `legacyItems = []` **without freezing** → retries
next open. So the dangerous middle case (partial-but-`stale=false`) may not be
reachable. **But "may not" is not a gate.**

**Early signal.** A user's file count drops after the *first* open of a
category; "missing files" tickets that pull-to-refresh fixes.

**Gates (close at least one before flip):**
1. **Prove the invariant** on-device against the user's *real damaged* buckets:
   list each, confirm the count matches reality (cross-check a known total), and
   confirm a deliberately-unreachable read **throws** rather than returning a
   short list. (This is the on-device E2E we are about to run.)
2. **Freeze only `!stale && objects.isNotEmpty` for existing users**, treating
   fresh-empty via a separate, explicitly-trusted "new user has no legacy"
   signal — so a degraded short read is never enshrined.
3. **Freeze TTL** (e.g. self-expire after 24h): bounds the blast radius of any
   bad freeze to one day without requiring user action. Cheap belt-and-braces.
4. **Detection telemetry:** periodically recount legacy live and compare to the
   frozen count; alarm on shrink. (Also serves the flag-flip observability gate.)

### B-priv — cross-user cache leak on a shared device

**Failure story.** Two accounts use the app on one phone. User B opens Images
and sees User A's frozen listing (filenames = metadata leak).

**Root cause.** Cache key is `userId:bucket` with
`userId = sha256(publicKey)[:16]` (64 bits). A collision or a derivation bug
would cross the streams.

**Mitigation / residual.** 64 bits is collision-safe for the handful of accounts
on one device, and the Hive box is **encrypted** (`getHiveMetadataCipher`).
Residual gate: confirm `deriveUserId` is keyed on the *currently signed-in*
account at every call (it is — `AuthService.instance.getPublicKeyString`), and
that sign-out→sign-in re-derives. Low risk; note, don't block.

### B-dup — prefer-v8 dedupe hides a wanted legacy file

**Failure story.** A legacy file disappears from the list because a *different*
v8 file collided on the same key and overwrote it in the merge.

**Root cause (ruled out).** Merge is keyed on the **logical object key**
(`o.key`, the path/name), not a random storage key. A v8 object shadows a legacy
object **only** when they share the same logical key — i.e. it is a genuine
re-upload/new-version of that same file, which is exactly the desired "v8 wins."
Distinct files have distinct keys → both shown. Verified. No gate.

### B-flagoff — the "no-op when off" claim is false

**Failure story.** We ship 2b "flag-off, zero change," and every signed-in user
suddenly opens an encrypted Hive box on every category open — wasted I/O, a new
failure surface — for a feature that does nothing yet.

**Root cause (FIXED).** The cache `init()` was gated on `userId != null`, not on
the flag. **Fixed** (commit `145489e`): the whole cache/merge path is gated on
`enabled && isManagedBase`; flag-off falls through to the plain single-bucket
read and opens **no** box. **Gate:** the on-device flag-off E2E must confirm
parity with the pre-v8 build (no behavior change). Grep guard: every
`LegacyListingCache.instance` reference must be flag-gated.

---

## 4. P4 — legacy delete tombstones (client-side hides)  *(UPCOMING — highest-invariant-risk)*

**Failure story (the catastrophic one).** A user deletes a legacy file in the
app. We interpret "delete" as a real `deleteObject` on the legacy bucket. That
file was the target of a **share** (folder/file). The share froze
`(bucket, storage_key, DEK)` with **no gateway fallback**, so the recipient's
link is now **permanently broken** — and the bytes may be unrecoverable.

**Root cause.** Violating the **HARD INVARIANT**: *legacy objects must NEVER be
physically deleted/moved.* A delete in the v8 world must be a **client-side
tombstone HIDE** (subtract from the merged view), never a server delete.

**Failure story 2 (tombstone shadows a new file).** A user deletes legacy
`photo.jpg` (tombstone). Later they upload a *new* `photo.jpg` → routes to
`images-v8`. The tombstone (keyed only by `key`) hides the **new v8 file** too.
The user's fresh upload is invisible.

**Root cause.** Tombstone keyed on `key` alone instead of
`(sourceBucket==legacy, key)`.

**Early signal.** Broken shares after deletes; re-uploaded files not appearing.

**Gates (design P4 to satisfy *before* writing it):**
- Tombstones are **hide-only**; never call `deleteObject` on a managed legacy
  bucket. (The guard deliberately does NOT block `deleteObject`, so this is a
  *discipline* gate, not an enforced one — consider adding a managed-legacy
  delete guard with an explicit "tombstone instead" path.)
- A tombstone must be **scoped to the legacy source** so a later same-key v8
  upload is **not** hidden. Subtract tombstones *before* the prefer-v8 merge,
  matched on `(sourceBucket, key)`.
- Tombstone store must be **per-user, encrypted, and sync-coherent** across
  devices (or explicitly single-device with documented cross-device behavior).
- E2E on the **dedicated test account**: delete → share still resolves; delete
  then re-upload same name → new file visible.

---

## 5. P5 / P6 — crash-safe metadata copy-forward  *(UPCOMING — highest-corruption-risk)*

**Failure story.** Mid copy-forward of a metadata bucket (a single per-user JSON
manifest — shelf, share registry, NFT, mappings…), the app is killed (OOM, user
swipe, OS). We had already pointed reads at the half-written v8 manifest and
abandoned legacy. The user's metadata (shelf contents, share list) is **lost or
corrupted**.

**Root cause.** A non-atomic copy that abandons the legacy source before the v8
copy is verified complete.

**Early signal.** Empty/partial shelf or share list after an app kill during
migration; "my shelf is gone."

**Gates (the P6 state machine must guarantee):**
- **Legacy stays authoritative until v8 is read-back-verified.** Sequence:
  Discover → Import → Prepare(write v8) → **Verify (read v8 back, compare)** →
  Commit (flip the pointer) — and only then stop reading legacy.
- **Idempotent + resumable:** every step survives a crash and re-runs cleanly;
  no step has a "point of no return" before Verify.
- **One service per Claude session** (P6a–P6e) so each gets its own premortem +
  E2E; never migrate two metadata services in one change.
- **Concurrency:** two devices copying-forward the same manifest must not
  split-brain — define last-writer/merge with the local Hive mirror as the tie-
  breaker, and test it.

---

## 6. P7 — shelf threading  *(UPCOMING)*

**Failure story.** Shelf items (the `dump-metadata` id-keyed manifest) lose their
user-defined order or disappear after v8 threading.

**Root cause.** Shelf is a manifest-controller; mis-threading `ShelfItem.
sourceBucket` or the order field drops items.

**Gate.** Reuse the P6 copy-forward state machine; preserve the v2 `order`
field; E2E: reorder + delete + restore round-trips across the migration (we
already have shelf v2 tests — extend them to the v8 split).

---

## 7. P8 — folder / category / tag share across two buckets + portal  *(UPCOMING)*

**Failure story.** A user shares a folder. The recipient (via the public
`pinning-webui` portal) sees only **half** the folder — the legacy half or the
v8 half — because the share/portal resolves a **single bucket**, but the folder's
content is now split across `images` + `images-v8`. New files added to the
shared folder (which land in v8) **never appear** to the recipient.

**Root cause.** Folder/tag shares are **bucket-bound**; the portal resolves one
bucket. The v8 split breaks the "one logical folder = one bucket" assumption.

**Early signal.** Recipients reporting missing files in shared folders;
newly-added files not syncing to a share.

**Gates.** A **one-logical-folder-over-two-buckets** resolution in the share
layer **and** a matching change in the **separate `pinning-webui` repo** portal
(remember to rebuild its wasm — see project memory). Shares created *before* the
flip are legacy-only and remain valid (legacy frozen). E2E: create a share,
add a file (→ v8), confirm the recipient sees both halves.

---

## 8. P9 — website repoint  *(UPCOMING — low risk)*

**Failure story.** Repointing breaks a live published AI-website.

**Root cause (ruled out).** Website assets are **CID/IPNS-bound and bypass the
forest** entirely, so the v8 bucket split does not touch them. Verified SAFE.
Gate: smoke-test one live site after any website-related change.

---

## 9. Cross-cutting failure modes (apply to all phases)

- **No telemetry = blind flip.** Per-bucket upload success + frozen-vs-live
  count must exist before flip (see §0, B1).
- **Silent caps.** Any place that bounds work (a listing page size, a retry cap,
  a sampling) must `log` what it dropped — a silent truncation in a *backup*
  listing is indistinguishable from data loss.
- **New-user path** must never hard-error when a legacy bucket is absent
  (verified: non-existent bucket → fresh-empty, not a throw).
- **Rollback story.** For every phase, write down how to undo it if it bites in
  prod *without* an app-store release (remote flag, server-side, or
  pull-to-refresh). If the only rollback is "ship an update," that phase is not
  flip-ready.

---

## 10. Adversarial-review additions (Gemini + Cursor)

The premortem above was legacy-loss-centric. Adversarial review surfaced that
the **committed flag-off code symmetrically risks v8-loss and
legacy-throw-empty** — equally silent, with a *healthier-looking* legacy half —
plus several code-grounded threading gaps. **All are flag-off-safe today** (no
split/merge/freeze when off) and are therefore **must-fix-before-flip**, not live
bugs. File:line refs are the committed state.

### 10.1 The symmetry gap — v8-loss and legacy-throw-empty (Cursor, HIGH)

- **v8-half silently empty.** `listCategoryCached` maps a v8 list *failure* to
  empty with only a `debugPrint` (`category_listing.dart:199-202`) — the same as
  "v8 doesn't exist yet." If the user *has* v8 activity, a v8 timeout / upload
  write-lock / master blip **hides their NEW uploads** while frozen legacy looks
  healthy. *Gate:* a v8 failure must not equal "empty" when v8 activity exists
  for this user+category → surface stale/error; telemetry `v8_expected` vs
  `v8_shown`; E2E: upload → assert merged count rises.
- **Legacy-throw silent empty.** Legacy failure → `legacyItems = []` with no
  user-visible signal (`category_listing.dart:184-187`). For an *existing* user
  a transient legacy error silently drops their **entire history** for that
  session (worse than B1 — not even enshrined, just gone-until-retry). *Gate:*
  distinguish "new user (no bucket)" from "load failed"; the latter must be
  **loud** (banner/retry), never a silent empty-merge.

### 10.2 Legacy reads may MUTATE the frozen bucket (Cursor, CRITICAL)

`_ensureForestLoaded` calls the normal `loadForest` (`fula_api_service.dart:
407-411`), which can trigger a **v7→v8 auto-migrate write-back** on the damaged
legacy bucket → it throws (→ 10.1 legacy-empty) **and** violates "legacy is
frozen / never mutate." *Gate:* legacy listing MUST use a read-only / no-write-
back forest path; **prove on-device that listing a damaged legacy bucket attempts
no mutation.** Block flip until verified. (This is the very thing the on-device
E2E should check first.)

### 10.3 The freeze is only coherent if the SERVER seals legacy (Gemini, ARCHITECTURAL)

The client-side freeze assumes legacy is write-frozen. But an **old-app device**
(flag-off) or any non-updated client can still WRITE legacy. Device A (frozen)
then **never sees** Device B's new legacy file → silent divergence. *Gate:* a
purely client-side freeze of a **server-shared** bucket is not globally
coherent. Either (a) add a **server-side seal** (gateway rejects writes to
managed legacy buckets — turns the client guard into a true invariant), or
(b) explicitly document + accept "freeze is coherent only once all devices are
updated," and have the client re-validate the freeze on any multi-device signal.

### 10.4 Threading gaps beyond download/delete (Cursor, HIGH)

- **SyncState / linked-key desync.** Category reconciliation writes
  `SyncState.bucket = base` (`file_browser_screen.dart:728-734`) while uploads
  land in v8; `getLinkedRemoteKeysWithPaths` matches the **exact** base → v8
  states don't link → false "cloud-only" duplicates, and tag/delete/share
  resolution route to the wrong bucket. *Gate:* reconciliation must set
  `bucket = cloudFile.sourceBucket ?? base`; linked-key queries use
  `readBuckets(base)`.
- **Folder-share auto-update misses v8.** The upload-completion manifest refresh
  matches `s.bucket == uploadBucket` (`sharing_service.dart:1857-1861`); a
  post-flip v8 upload into a folder shared on legacy **never** triggers the
  refresh → recipients never see new files. *Gate:* map base↔v8 in share-matching
  (folds into P8), or disable auto-update until P8 with explicit acceptance.
- **Tag shares are a separate single-bucket manifest** (parallel to P8 folder
  shares) with the same half-loss. *Gate:* extend two-bucket resolution to tag
  shares or defer with a visible "N files in other bucket not shared" warning.
- **`deleteObject` is unguarded** (`fula_api_service.dart:854-858`); live delete
  UI paths bypass the P4 tombstone discipline → wrong-bucket silent no-op, or a
  real legacy delete on a share-backed object (catastrophic). *Gate:* a managed-
  legacy delete guard that routes to the tombstone path; delete UI uses
  `sourceBucket`.

**CONFIRMED on-device (2026-06-08, flag-ON diagnostic, account ehsan6sha, moto g85).**
v8 uploads route + succeed + merge correctly and the **category view shows correct
status** — but the **cloud explorer** (`_isCloudMode`, browsing `images-v8`) shows the
on-disk uploaded files as **"cloud only"** (no thumbnail). Root cause: the explorer's
matcher `_findLocalFileForCloudObject` is v8-blind — Strategy 1 needs an exact
`SyncState.bucket == 'images-v8'` match, and Strategy 2's directory fallback is dead
because `_categoryFromBucket('images-v8')` returns null (`file_browser_screen.dart:
940-949`). The **category view is correct because it is *local-file-driven*** (matches
`localFile.name` against the merged cloud map, bucket-agnostic), whereas the explorer is
*cloud-object-driven*. **Fix (in the 10.4 threading pass):** make `_categoryFromBucket`
strip the `-v8` suffix, AND make the explorer matcher resolve base↔v8 (match
`state.bucket ∈ readBuckets(base)`); also verify `SyncState.remoteKey` is populated on
upload (`queueUpload` sets `remotePath` but not `remoteKey`, sync_service.dart:440-447).
The **10.1 symmetry gap was ALSO confirmed live**: `documents` showed **empty** because its
legacy listing throws a stale-manifest error → treated as empty.

### 10.5 Cryptographic + temporal robustness (Gemini, MEDIUM-HIGH)

- **Key-rotation orphaning.** The frozen cache captures storage-keys/pointers at
  freeze time; a later DEK/master-key rotation or password change can leave those
  pointers tied to an old key state → "digital ghosts" (listed but
  undecryptable). *Gate:* version the frozen cache by key-id; invalidate/re-derive
  on rotation; test-decrypt a sample before trusting a freeze. (Ties to the
  "100% sure on encryption code" rule — needs owner sign-off.)
- **Clock-skew.** If the merge/sort or conflict-resolution ever keys on
  `lastModified`, a wrong device clock sorts v8 (new) *behind* legacy → "my new
  uploads vanished." *Gate:* v8 is **always newer** than legacy for sort/conflict,
  independent of timestamps. (Today the merge is prefer-v8 **by key**, not time —
  keep it that way; never switch to timestamp-based conflict resolution.)
- **Merge OOM / pagination.** Sorting+deduping two large lists in memory on every
  open/scroll can peg CPU / OOM for a multi-thousand-file account. *Gate:* a local
  indexed (e.g. SQLite) unified view or bounded/paged merge; measure with a
  large-account E2E.

### 10.6 Migration-state + multi-device (Cursor, MEDIUM)

- **`v8-create-verified` not built.** Routing keys on the flag alone; a user with
  no `images-v8` bucket (never uploaded / a failed create) gets upload failure or
  an empty v8 at flip. *Gate:* a per-user durable "v8 ready" state before routing;
  E2E: flip with zero v8 buckets → first upload still appears.
- **Per-device frozen divergence.** Device A freezes 4,982 items, Device B
  freezes 4,990 — different galleries forever (cache is local, not cloud-synced).
  *Gate:* cloud-anchor freeze completeness (rootCid + count + hash), or TTL +
  forced refresh on new-device sign-in. (Also the natural home for B1's
  completeness stamp and Gemini's "count vs high-water-mark" sanity check.)

### 10.7 Same-key, different-content prefer-v8 (Cursor, MEDIUM)

A re-upload of `vacation.jpg` with **new content** to v8 shadows the legacy
`vacation.jpg`. If the user wanted the *original*, prefer-v8 shows the wrong
photo. (B-dup only ruled out *distinct* keys.) *Gate:* implement the planned
content-hash-aware dedupe, or explicitly accept "same name = replacement" with a
UX indication; never silently prefer-v8 when hashes differ.

---

## 11. Consolidated pre-flip gate checklist

Do **not** set `BucketVersionResolver.enabled = true` until:

**Data-visibility (the trust-critical set):**
- [ ] **B1** — `stale=false ⇒ complete` proven for damaged buckets (on-device
      count check + unreachable-read-throws), and/or freeze-only-non-empty +
      freeze TTL + frozen-vs-live recount alarm.
- [ ] **10.1 symmetry** — v8 failure ≠ empty when v8 activity exists; legacy
      load failure is **loud**, never a silent empty-merge.
- [ ] **10.2 read-only legacy load** — listing a damaged legacy bucket attempts
      **no** mutation (no v7→v8 write-back), proven on-device.
- [ ] **10.3 seal** — server-side legacy write-seal, OR documented + accepted
      "all devices updated" coherence boundary.

**Routing / threading correctness:**
- [ ] **Write-path audit** — every guarded-write call-site routes or is an
      intentional non-managed write.
- [ ] **10.4 SyncState / linked-key / share-match / delete** all thread
      `sourceBucket` / `readBuckets(base)` (or are explicitly deferred + gated).
- [ ] **SyncTask** confirmed strict upload XOR download (restore re-route safe).
- [ ] **10.6 v8-ready state** — flip with zero v8 buckets still shows uploads.

**Operability:**
- [ ] **Kill switch** — flag remotely controllable (or owner accepts a hardcoded
      flip with all gates closed).
- [ ] **Observability** — per-bucket upload success + frozen-vs-live recount
      shipped *before* the flip.
- [ ] **Flag-off parity** confirmed on-device (no regression vs pre-v8 build).

**Robustness (verify-or-accept):**
- [ ] **10.5 key-rotation** frozen-cache invalidation; **clock-skew** never used
      for conflict/sort; **merge** bounded for large accounts.
- [ ] **10.7 same-key-different-content** policy implemented or accepted.
- [ ] Owner sign-off on the **cloud-explorer** showing `images` + `images-v8`
      as separate buckets post-flip; and on **non-merge single-bucket views**
      (tag browser, folder-manifest rebuild) for managed categories.

P4–P9 each carry their own E2E gate on the **dedicated test account** and must
have their premortem section above filled in and closed before that phase ships.
