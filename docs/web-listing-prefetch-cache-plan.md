# Web Listing Cache + Background Prefetch — Design Plan

Status: advisor-reviewed (Gemini + Copilot, 2026-06-12 — see §10/§11), awaiting owner approval
Scope: web shell only (`lib/web/**` + additive core seams). Native screens keep their
existing flows; any shared-file change must be behavior-identical natively.

## 1. Problem

Opening any category or feature screen on files.fx.land/app/ takes seconds, every time.

Where the time actually goes today (from the code, to be measured in P0):

| Path | Cost driver |
|---|---|
| Category open (`web_bucket_screen._load` → `FulaApiService.listObjectsCached(bucket)`) | **Live-first**: always a full network listing with a 10 s timeout and a 500 ms-delayed retry. The persisted cache (`ObjectCacheService`) is consulted **only after two live failures** — it is an offline fallback, never a fast path. |
| First listing per bucket per session | `listObjects` → `_ensureForestLoaded(bucket)`: downloads + decrypts the bucket's encryption forest through wasm (multiple round trips). Memoized in `_loadedForests` for the session; **every page reload starts cold**. |
| Feature screens (Tags / Websites / NFTs / Shelf / Playlists / Automate) | Every open calls `load(force: true)` → `downloadMetadataMerged` fetches the **[v8, legacy] manifest pair** (2 GETs + 2 wasm decrypts + the metadata-buckets' forest loads). The NFTs screen forces TWO services (tags + nfts) — up to 4 forest loads per open. |
| Web-specific penalty | No block cache / gateway race on web (wasm-inert features) — all reads go to the master gateway. |
| Cache storage | `ObjectCacheService` persists into SecureStorage = WebCrypto-wrapped **localStorage (~5 MB quota)** on web. Thousands-of-objects listings as JSON will hit the quota, and a full quota breaks **auth-token writes** too. |

So the UX problem is structural: nothing is ever rendered from cache, and the most
expensive step (forest load) is repaid on every reload.

## 2. Goals / non-goals

Goals (v1):
1. Warm opens render **instantly from cache** (target < 200 ms to first painted list), then
   revalidate in the background and patch the view.
2. After sign-in, a **background prefetcher** warms the categories + feature manifests the
   user is most likely to open — without competing with anything the user is doing.
3. Foreground actions (opening a screen, downloading, uploading) **always preempt**
   background work for bandwidth and for the wasm client's locks.
4. Cache is **per-user, encrypted at rest, bounded in size, and wiped on sign-out**.

Non-goals (v1):
- No server-side changes. A cheap server freshness probe (forest-root ETag) is designed as
  a **V2 seam** (§7) but v1 is client-only.
- No offline mode. Cache improves perceived latency; the source of truth stays the cloud.
- No native-app changes. (Native already has its own block cache + different storage tiers.)

## 3. Prior art → our equivalents

The patterns below are the standard ones used by Drive / OneDrive / Dropbox web clients;
each maps to a concrete mechanism here:

| Industry pattern | Our equivalent |
|---|---|
| **Stale-while-revalidate** (render cached copy, refresh behind it; Drive's web list views, HTTP RFC 5861) | L2 cache read → immediate render → live fetch → diff-patch the view + rewrite cache |
| **Delta / changes API** (Drive `changes.list` page tokens, OneDrive `/delta` links) | The fula forest root is content-addressed: same root CID ⇒ nothing changed. V2 server probe = HEAD-style "current forest root" check; v1 approximates with TTL tiers + write-through (§7) |
| **Sync engine with priority + preemption** (OneDrive Files On-Demand hydration, Drive offline sync) | `WebPrefetchScheduler`: priority queue, concurrency 1, pauses while any foreground op is in flight (§6) |
| **Request coalescing / single-flight** (every CDN/client cache) | One in-flight future per (bucket, prefix); prefetch and a user open of the same bucket share it |
| **Per-account cache namespaces, purged on switch** (all of them) | Owner-hash scoping (existing `BucketCacheService` pattern) + proactive wipe of any other owner's box at sign-in |
| **Quota-bounded LRU metadata cache** | Hive/IndexedDB box, per-entry caps + total budget + LRU eviction (§8) |

## 4. Architecture overview

Three pillars, built in that order — each is independently shippable:

```
A. SWR read path        →  removes the per-open wait (biggest win, no contention risk)
B. Prefetch scheduler   →  makes even the FIRST open warm
C. Cache lifecycle      →  correctness: identity, invalidation, bounds, logout
```

New files (web shell):
- `lib/web/services/web_listing_cache.dart` — L2 cache (categories + feature manifests)
- `lib/web/services/web_prefetch_scheduler.dart` — background warmer
- `lib/web/services/web_foreground_activity.dart` — tiny counter the scheduler watches

One additive core seam:
- `FulaApiService.listObjectsSWR(...)` (or a web-side wrapper; decided in P1) exposing
  cached-then-live semantics WITHOUT changing `listObjectsCached` (native callers keep
  today's behavior exactly).

## 5. Cache design (pillar A + C)

### 5.1 Storage

Hive box `web_listing_cache_v1` (IndexedDB) — NOT SecureStorage (5 MB localStorage wall;
a full quota would also break credential writes). Two record kinds, same envelope:

```
key:   "<ownerHash>|cat|<bucket>"            (category listings)
       "<ownerHash>|man|<bucket>|<objectKey>" (feature manifest blobs, post-decrypt JSON)
value: AES-GCM( jsonEncode({
         v: 1,                       // schema version — bump invalidates
         fetchedAt: iso8601,
         lastAccess: iso8601,        // for LRU
         payload: [...]              // FulaObject JSONs / manifest JSON
       }) )
```

- **Encrypted at rest**: filenames are user content in an E2E product; IndexedDB is plain
  disk. Key = HKDF(session KEK, info: 'web-listing-cache-v1'), AES-GCM with random nonce
  per write — **via `crypto.subtle` (Web Crypto), not wasm/Dart** (both advisors: system
  crypto is the fast path; wasm AES of a 50 KB listing can cost 100–200 ms on low-end
  mobile). P1 gate: decrypt of a 5 k-object entry < 100 ms on a low-end phone, else move
  decrypt off the open path (idle pre-decrypt into L1). On sign-out the KEK is gone ⇒
  even a missed wipe is unreadable.
- **Honest threat model** (advisor question): the KEK itself lives in the same browser
  profile (WebCrypto-wrapped localStorage), so cache encryption does NOT survive a full
  profile clone — it protects against the realistic lesser cases (disk/backup tooling
  reading IndexedDB files in plaintext, cross-user residue after eviction bugs) and keeps
  posture parity with native (which caches listings in platform secure storage). Per-entry
  key-wrapping was considered and rejected: it adds no security while the KEK shares the
  profile.
- **L1 memory layer** (Gemini): a session `Map` above Hive — back-navigation and widget
  rebuilds must not re-read + re-decrypt IndexedDB. L2 is read once per (key, session),
  then L1 serves until invalidated.
- **Owner scoping**: `ownerHash` = sha256(derivationEmail) — the existing
  `BucketCacheService` identity. Read path treats owner mismatch as a miss.
- `fetchedAt`/`lastAccess` live OUTSIDE the ciphertext? **No** — keep them inside (don't
  leak access patterns); LRU bookkeeping uses a tiny plaintext sidecar map
  `{key → lastAccessEpoch}` that contains no user data beyond the already-visible key names.

### 5.2 Read path (SWR)

`web_bucket_screen._load` becomes:

1. `cache.read(bucket)` → if hit: render immediately, badge the list with the existing
   stale-banner component when `fetchedAt` is old (reuses the `stale:` UI already built).
2. In parallel, start the live fetch through the **single-flight map** (if the prefetcher
   is already fetching this bucket, await the same future).
3. On live success: diff against rendered list; `setState` the fresh list; rewrite cache.
4. On live failure: keep the cached render + show the existing offline/stale banner.
   (Today's behavior — error screen only when there is no cache either.)

Feature services get the same treatment: `WebTagService.load(force: true)` call sites in
screens change to `load()` with SWR semantics — `load()` returns the cached manifest
snapshot instantly when present and revalidates behind it; the explicit Refresh buttons
keep `force: true` (which now ALSO bypasses the single-flight share and the TTL).

`downloadMetadataMerged`'s [v8, legacy] pair: the **legacy half is frozen** after one
successful fetch (legacy metadata buckets are immutable post-migration — same logic as
`listCategoryCached`'s frozen legacy cache, file `category_listing.dart`). Steady-state
revalidation then touches only the v8 manifest: 1 GET instead of 2, half the forest loads.

### 5.3 Freshness tiers (v1, client-only)

Revised per advisor round — the original 24 h silent window is too long for a
multi-device sync product ("where is my file?" tickets when device B changed things):

| Cache age | Behavior on open |
|---|---|
| < 2 min | Render cache, **skip revalidate** (a navigation bounce shouldn't re-list) |
| 2 min – 1 h | Render cache + silent background revalidate (SWR proper) |
| > 1 h | Render cache + stale banner + revalidate |
| Miss | Today's behavior: spinner + live fetch (then cache) |

Plus a **"Synced X min ago" subheader** whenever age > 15 min, updating when the
revalidate lands — staleness is visible instead of silent. (Gemini proposed a 1 h silent
ceiling, Copilot 2 h; we take 1 h with the synced-ago line as the compensating cue.)

**Connection-regain revalidation** (Copilot's best value/complexity pick): a
`window 'online'` listener + resume-from-background hook queues a revalidate of the
frecency-top buckets through the same single-flight map — catches cross-device changes
exactly when they're most likely to have happened.

Tunables in one constants file; P0 measurements may adjust them.

## 6. Prefetch scheduler (pillar B)

### 6.1 Queue and priorities

Built once after sign-in/restore completes AND the home screen has rendered AND a 2 s
idle delay has passed (don't fight the boot path):

1. **Frecency order**: categories the user opened most recently/most often first — a tiny
   usage log (`<ownerHash>|usage` entry, counts + last-open timestamps, updated on every
   screen open). Cold start (no log): Images, Documents, Videos, Audio, Downloads,
   Archives (app-wide popularity default).
2. Then feature manifests: tags (cheapest, powers chips in categories too), shelf,
   websites + pointers, nfts, playlists, shares.
3. Each queue item = ONE bucket listing or ONE manifest fetch — small, abortable units.

### 6.2 Preemption ("never compete with the user")

`WebForegroundActivity` — a global counter with a broadcast stream:
- incremented/decremented around every **user-initiated** network op: screen loads,
  downloads (`saveBytesAsDownload` fetch path), uploads, share accepts, collab ops.
  Call sites: the web screens' `_load()`s + upload/download controllers (≈ a dozen sites,
  one-line wrap each: `ForegroundActivity.run(() => ...)`).
- The scheduler:
  - takes the next task only when `count == 0` **and** `MasterHealthService` says healthy;
  - **concurrency 1** — at most one background listing in flight, ever;
  - checks the counter at the **network/wasm boundary**: after the fetch completes but
    before handing bytes to wasm decrypt (Gemini: don't burn CPU on a background decrypt
    while the user is waiting on a different screen); an in-flight wasm call is not
    killable, so preemption granularity = one bucket task (bounded: one forest + one
    list). Each task is **atomic** for cache purposes: fetch + decrypt + cache write
    commit together or not at all (no partial entries — Copilot);
  - when foreground activity starts mid-task, finishes the current task, then waits for
    `count == 0` + a 1 s settle before resuming;
  - failed tasks are **poison-marked for 5 min** (no immediate retry loops), with capped
    exponential backoff (1 s → 4 s → 16 s → drop until next session), and a hard stop
    after N consecutive failures (master likely down);
  - checks `navigator.storage.estimate()` once at scheduler start — low free quota ⇒
    prefetch disabled this session (an out-of-quota write mid-prefetch must never break
    credential storage or leave partial entries);
  - **fetch priority hints** (`priority: 'low'` on background fetches) noted as a
    progressive enhancement where the HTTP layer exposes them — advisory-only, the
    explicit scheduler remains the real mechanism.
- The wasm client serializes writes with an outer write lock (uploads); a background list
  holding read access while the user uploads is exactly the contention
  `object_cache_service.dart`'s header documents — another reason for the pause-on-upload
  rule, not just bandwidth.

### 6.3 What prefetch produces

A completed prefetch task writes the same L2 cache entries the SWR path reads AND warms
the session-level `_loadedForests` memo — so even a cache-miss open right after prefetch
is fast (forest already in wasm memory).

**Wasm memory pressure** (Gemini flag): every warmed forest occupies wasm linear memory
(32-bit ceiling). v1 bounds: the prefetch queue is capped (≤ 10 desktop / 8 mobile items)
so at most that many forests get warmed beyond what the user opens; P0 measures per-forest
resident cost on the test vault. If forests prove large, V2 adds forest pruning on the
Rust side (drop least-recently-listed forests past a budget) — listed in §10 as a tracked
risk, not a v1 blocker.

### 6.4 Coalescing

A `Map<String, Future<...>> _inFlight` shared by the SWR path and the scheduler:
opening a category that prefetch is mid-fetching awaits the same future (no duplicate
list, no doubled bandwidth — and the user-initiated await effectively promotes the
background task to foreground priority).

## 7. Invalidation

1. **Write-through on app-originated mutations** (the only changes we can see for free):
   upload, delete, rename on web patch the cached listing in place immediately
   (add/remove the `FulaObject`) and stamp the entry `locallyPatched: true`; next SWR
   revalidate reconciles. The screen already updates its in-memory list; this just keeps
   L2 consistent with it.
2. **Cross-device changes** (app uploads a photo while the web tab is open): invisible to
   v1 except through the TTL tiers + the manual Refresh button (force bypass). This is
   the accepted v1 gap — same as Drive's web list before its push channel arrives.
3. **V2 seam — cheap server freshness probe**: the forest root is content-addressed; a
   tiny authenticated endpoint returning the current forest root CID per bucket would
   make revalidation nearly free (compare CIDs; refetch only on change) — the moral
   equivalent of OneDrive's deltaLink. Designed-for but explicitly out of v1 (server
   work, needs fula-api capability review).
4. **Schema/version**: `v` field bump ⇒ entry ignored and rewritten.

## 8. Lifecycle, bounds, and multi-user

| Concern | Decision |
|---|---|
| **Sign-out** | `WebSession.signOut` additionally `Hive.deleteBoxFromDisk('web_listing_cache_v1')` (plus the usage log) + the `signed-out` broadcast. KEK loss already makes leftovers unreadable; we delete anyway. **Audit item (Copilot, high)**: confirm sign-out also disposes the wasm encrypted-client handle so `_loadedForests` state and decrypted forest memory never survive into another account's session (today `initialize()` clears the memo set; the audit verifies the old Rust handle is actually dropped). |
| **Different user signs in** | At sign-in, if the box contains entries for a different `ownerHash`, delete them all (privacy + keeps the box single-tenant; avoids unbounded multi-account growth). Defense-in-depth even without the wipe: entries are AES-GCM-authenticated under the *previous* user's KEK-derived key — a cross-user read fails authentication and registers as a miss. |
| **Browser evicts IndexedDB under storage pressure** | Browsers may clear IndexedDB without warning. Every cache read treats missing/undecryptable entries as a plain miss (never an error); nothing correctness-critical lives only in the cache. |
| **Size bounds** | Per entry: max 20 000 objects (beyond that, store nothing — the screen already paginates poorly past that anyway; log it). Total budget: 25 MB ciphertext. On overflow: LRU-evict by `lastAccess` **before** writing the new entry (never transiently exceed the budget — quota failure mid-write must not be reachable). Listings are metadata-only (≈ 150–300 B/object) so the budget fits ~50–100 k objects across buckets. |
| **Multi-tab** | One `BroadcastChannel('fxfiles-cache')` carrying three message kinds (advisor round upgraded this from prefetch-dedup only): (1) `prefetch-alive` ping — another tab pinged < 5 min ago ⇒ skip prefetch here; (2) `invalidate <key>` — sent on every app-originated write (upload/delete), other tabs drop that L1/L2 entry and revalidate on next view (a delete in tab A must not survive in tab B); (3) `signed-out` — other tabs clear L1 immediately and route to sign-in (the box delete is done by the originating tab; receivers must drop in-memory copies). Hive web serializes box access via IndexedDB transactions. |
| **Mobile data / battery** | Prefetch ceiling: stop after the queue's first 8 items on `PlatformCapabilities`-detected narrow screens (heuristic for phones), full queue on desktop. `navigator.connection.saveData === true` ⇒ prefetch disabled entirely (respect Data Saver). |
| **Master down** | `MasterHealthService` gate at scheduler + the existing stale banners on screens. Prefetch failures never surface UI. |
| **Privacy** | Cache encrypted under a KEK-derived key (§5.1); no filenames at rest in plaintext; no cache writes pre-sign-in (no KEK → no key). |

## 9. Phasing (one Claude session each, gates as usual)

- **P0 — Measure**: temporary `--dart-define=PERF=true` timing probes split into
  **forest-load vs list-from-forest vs manifest GET vs decrypt** on the test vault (the
  split decides whether the scheduler should prioritize forest warming over listings);
  also record per-forest wasm memory cost. Baseline table lands in this doc. If something
  other than forest+listing dominates, re-plan before building.
- **P1 — SWR read path** (pillar A): `web_listing_cache.dart` (encrypted Hive box via
  `crypto.subtle`, owner scoping, schema v1, L1 map) + single-flight map +
  `web_bucket_screen` SWR + feature services `load()` SWR + frozen-legacy manifest halves
  + the `online`/resume revalidation listener. No scheduler yet. Gates: warm open renders
  < 200 ms on test vault; entry decrypt < 100 ms on a low-end phone profile (else move
  decrypt off the open path); analyzer/tests/builds green; cache-miss behavior identical
  to today.
- **P2 — Scheduler** (pillar B): `web_foreground_activity.dart` + call-site wraps +
  `web_prefetch_scheduler.dart` (frecency, concurrency 1, preemption checkpoints, poison
  marks + backoff, health gate, Data Saver, quota check, multi-tab ping). Gate: with a
  download in flight, zero prefetch requests observed in the network log; cold sign-in →
  all six categories warm within ~30 s idle.
- **P3 — Lifecycle** (pillar C): write-through patches on upload/delete + `invalidate`
  broadcasts; sign-out wipe + `signed-out` broadcast + the wasm client-handle disposal
  audit; cross-user wipe; size caps + LRU; usage log. Gate: user-switch E2E shows zero
  cross-account residue (box inspected); two-tab delete test (tab A deletes, tab B view
  drops it on next render); quota torture test (synthetic 30 MB) evicts correctly.
- **P4 — V2 seams (optional, separate approval)**: hover-intent prefetch on desktop
  (dwell > 200 ms over a category tile), wasm forest pruning if P0 shows large forests,
  the fula-api forest-root probe (server change — own review cycle).

**Explicitly rejected for v1 — service-worker caching of encrypted responses** (both
advisors raised it): the deploy intentionally ships `--pwa-strategy=none` because a stale
service worker serving old wasm against new Dart is the classic FRB-web failure mode
(decided in P5 of the web-port plan). Reintroducing a SW for response caching reopens
that risk class and duplicates the storage footprint for modest gain over IndexedDB SWR.
Revisit only with a dedicated SW-versioning design.

## 10. Open questions → resolutions (advisor round, 2026-06-12)

| # | Question | Resolution |
|---|---|---|
| 1 | SWR vs cache-first+TTL without a server freshness signal? | SWR confirmed; original 24 h silent window rejected by both advisors as too long for multi-device. Adopted: 2 min / 1 h tiers + "Synced X ago" subheader + connection-regain revalidation (§5.3). |
| 2 | KEK-derived cache encryption warranted? | Yes — both advisors call it mandatory for the E2E brand promise (IndexedDB is plaintext on disk). Use `crypto.subtle`, not wasm; perf gate < 100 ms on low-end mobile. Per-entry key wrapping rejected (KEK shares the profile — no added security). Threat model stated honestly in §5.1. |
| 3 | Preemption granularity? | Per-bucket task confirmed adequate, with two refinements: a foreground check at the fetch→decrypt boundary, and task-atomic cache commits with 5-min poison marks on failure. Fetch priority hints = advisory extra only. |
| 4 | Eviction + multi-account policy sane? | Single-tenant wipe confirmed as the correct zero-trust default. Gaps closed: `signed-out` + `invalidate` broadcasts across tabs, GCM-auth cross-user miss noted, quota pre-check, eviction-before-insert ordering. |
| 5 | Missing client-only standard mechanisms? | Adopted: L1 memory cache, connection-regain revalidation (best value/complexity per Copilot), hover-intent prefetch (P4). Rejected with reasons: service-worker response cache (§9), pagination (server work, V2). |

Tracked risks (not v1 blockers): wasm forest memory growth from prefetch warming (§6.3,
P0 measures, V2 prunes); cross-device staleness inside the 1 h silent window (V2
forest-root probe closes it); browser-initiated IndexedDB eviction (handled as miss).

## 11. Advisor round summary

Reviewed 2026-06-12 by Gemini CLI and GitHub Copilot CLI (independent model families;
built-in/Codex/Cursor advisors quota-unavailable). Verdicts: structurally sound, no
phasing errors, no blockers. Highest-weight findings, all folded in above: 24 h silent
tier too long (both) → §5.3; cache encryption mandatory but must be Web Crypto (both) →
§5.1; L1 memory layer required for 60 fps (Gemini) → §5.1; wasm forest memory pressure +
write-lock interaction (Gemini) → §6.2/§6.3; sign-out wasm-handle + cross-tab clearing
audit (Copilot) → §8/P3; connection-regain revalidation as the best cheap addition
(Copilot) → §5.3/P1.
