# Diagnosis: Sync Queue Cancel + Large-File Upload Issues

**Date**: 2026-05-21
**User-reported symptoms**:

1. Settings > Sync Queue has no Cancel button (only Retry and Move-to-front).
2. Large-file upload (445 MB video) issues:
   - **2a.** Closing the app stops the upload; the Android progress notification disappears; reopening the app restarts the upload from 0%.
   - **2b.** While uploading, opening any phone-side bucket (Images/Videos) or the Cloud Files section hangs indefinitely.

User-supplied log excerpt (relevant lines):

```
UploadProgressManager: Starting batch of 1 files (445.0 MB)
UploadProgressManager: Estimated total duration: 911s
Starting upload: .../Cloudfx - tagging.mp4 -> videos/Cloudfx - tagging.mp4
Upload failed: FulaApiException: Failed to upload file from path: AnyhowException(
  HTTP error: error sending request for url
  (https://s3.cloud.fx.land/videos/Qm…7eafbcdd…chunks/00000091)
  ...
  Caused by: 3: Software caused connection abort (os error 103))
Will retry … in 2s (attempt 1/5)
listObjects(videos, prefix="") error: AnyhowException(
  users-index resolution failed: IPNS exhausted; chain RPC transport:
  error sending request for url (https://mainnet.base.org/))
UploadProgressManager: Starting batch of 1 files (445.0 MB)   ← restart from 0
No network, pausing sync
```

---

## Root causes (proved by code reads)

### Issue 1 — no Cancel UI
- `lib/features/settings/screens/sync_queue_screen.dart:216-228` — trailing action is only Retry (failed) or Move-to-front (pending). No cancel.
- `lib/core/services/sync_service.dart:974-977` — `cancelAll()` only clears in-memory queues; does NOT clear the persistent SyncTask rows or update SyncState. `cancelUploadsForBucket` exists (lines 85-119) but is internal (called when disabling folder sync), not user-callable per task.
- **In-flight cancellation is not possible from Dart**: `fula.putFlatFromPath` returns a Future. Dart cannot cancel a Rust future; dropping it doesn't propagate cancellation into the Rust task running inside flutter_rust_bridge.

### Issue 2a — upload restarts from 0 after app close
Three independent contributors:

(a) **No Android Foreground Service.** `MainActivity.kt:418-455` calls `NotificationManager.notify(SYNC_NOTIFICATION_ID, …)` — a plain notification, NOT `Service.startForeground()`. `AndroidManifest.xml:21` declares `FOREGROUND_SERVICE_DATA_SYNC` permission and registers `androidx.work.impl.foreground.SystemForegroundService` (for WorkManager) but no actual sync `Service` class exists under `android/app/src/main/kotlin/land/fx/files/dev/`. When the activity is destroyed the process is killed; the notification dies with it.

(b) **No chunk-level resume bridged to Flutter.** `fula-flutter/src/api/forest.rs:158-175` shows `put_flat_from_path` reads the entire file with `tokio::fs::read(&file_path).await` then calls `put_object_flat` (single shot). The Rust SDK DOES have a resumable encrypted-upload path in `fula-client/src/encryption.rs:7116` (`resume_upload` taking a manifest_path + data), driven by `put_object_encrypted_resumable` (which writes a manifest of completed chunks). NEITHER `resume_upload` NOR `put_object_encrypted_resumable` is exposed through `fula-flutter`.

   The non-encrypted multipart API (`start_multipart`/`upload_part`/`complete_multipart`/`abort_multipart`/`detach_multipart`) IS exposed in `fula-flutter/src/api/multipart.rs` but: (1) it uses `FulaClientHandle`, not `EncryptedClientHandle`, so it bypasses the encryption layer the rest of the app relies on, and (2) FxFiles' `SyncService` never calls it.

(c) **Dart-side restart logic.** `SyncService.restoreQueue()` (`lib/core/services/sync_service.dart:1002`) re-queues the task. Without a persisted resume manifest, `_executeUpload` calls `uploadLargeFileFromPath` which starts a fresh encryption + upload from chunk 0. The visible "Starting batch … 445.0 MB" twice in the log is exactly this restart.

### Issue 2b — UI hangs during upload
Two compounding causes:

(a) **`tokio::sync::RwLock` contention in fula-flutter's encrypted bridge.**
`EncryptedClientHandle.inner = Arc<RwLock<EncryptedClient>>` (`client.rs:202`).
The binding takes `write().await` for upload functions even though the underlying methods take `&self`:

| Function | Lock taken | Underlying method signature |
|---|---|---|
| `put_flat` (forest.rs:81) | `write().await` | `EncryptedClient::put_object_flat(&self, …)` (encryption.rs:6036) |
| `put_flat_from_path` (forest.rs:167) | `write().await` | `EncryptedClient::put_object_flat(&self, …)` |
| `put_flat_deferred` (forest.rs:102) | `write().await` | `EncryptedClient::put_object_flat_deferred(&self, …)` |
| `list_from_forest` (forest.rs:142) | `read().await` | `EncryptedClient::list_files_from_forest(&self, …)` |
| `load_forest` (forest.rs:29) | `write().await` | `EncryptedClient::load_forest(&self, …)` |

`tokio::sync::RwLock` is write-preferring: any active `write()` blocks all subsequent `read()` and `write()` calls until released. A 445 MB upload holds `write()` for ~15 minutes; concurrent UI calls (listObjects → `list_from_forest`, loading a not-yet-cached forest → `load_forest`) wait the entire time.

The underlying `EncryptedClient` uses `DashMap` and other internally-synchronized structures (see `forest_cache` in `encryption.rs:6091`), so `read()` should be safe for puts. The `write()` choice in the bridge is over-conservative.

(b) **No timeout / no stale fallback on `listObjects`.**
`FulaApiService.listObjects` (`lib/core/services/fula_api_service.dart:533-574`) has no timeout and no cached fallback. Compare with `listBucketsCached` (lines 467-496) which retries once, then falls back to `BucketCacheService` and surfaces `stale=true`. When the IPNS chain RPC at `mainnet.base.org` times out during forest load, the UI spins until the RPC finally errors (can be 30s+) — and during a held write lock, even longer.

---

## Proposed fix plan

### SDK changes (`E:/GitHub/fula-api`)
1. **Reduce lock scope** in `fula-flutter/src/api/forest.rs`: switch `put_flat`, `put_flat_from_path`, `put_flat_deferred`, `put_flat_from_path_deferred`, `put_flat_with_metadata`, and `delete_flat` from `write().await` to `read().await`. Audit `EncryptedClient` to confirm internal synchronization handles the concurrency.
   - Risk: any internal `&self` method that hides a non-Sync invariant becomes unsound. Mitigation: keep `write().await` only on `load_forest` / `flush_forest` (places that legitimately replace the in-memory forest entry).
2. **Bridge `resume_upload` + `put_object_encrypted_resumable`** through fula-flutter so the Dart side can persist a manifest path and resume chunked uploads across process restarts.
3. **Expose a cancel handle** for `put_flat_from_path` (a `CancellationToken` argument from `tokio_util` or an `Arc<AtomicBool>` checked between chunk PUTs) so the Dart side can abort in-flight uploads.

### App changes (`E:/GitHub/FxFiles`)
4. **Sync Queue Screen**: add per-task cancel button (trailing icon `LucideIcons.x`) and a "Cancel all" app-bar action. Cancel removes from `_uploadQueue`, removes from persistent storage, sets SyncState to `notSynced`. For in-progress tasks, mark a "cancel requested" flag that the upload loop checks (graceful) — fully aborting needs SDK change #3.
5. **Android Foreground Service**: create `SyncForegroundService.kt` that owns the upload notification via `startForeground()` with type `dataSync`. The Dart engine continues to run within the service so uploads survive `MainActivity` destruction. Start it when a non-empty queue is processed; stop when drained or canceled.
6. **listObjects timeout + fallback**: wrap `FulaApiService.listObjects` with a 10s timeout and a per-bucket file-list cache (mirror `BucketCacheService`), surface `stale=true` to the UI.
7. **SyncService resume integration**: persist `manifest_path` per `SyncTask`. On retry/restoreQueue, if a manifest exists, call the bridged `resume_upload` instead of `put_flat_from_path`. Clear manifest on completion.

---

## Advisor review (2026-05-21)

Consulted gemini-advisor, cursor-advisor, codex-advisor in parallel + built-in advisor (sees full transcript).

**Material disagreement, surfaced for the record:**

- **Gemini** and **Cursor** both said the proposed bridge change (`write().await` → `read().await` for `put_flat*`) is "safe and necessary".
- **Codex** found a specific lost-update bug they missed: the monolithic v1 forest path uses clone-mutate-reinsert (`encryption.rs:6334-6352`, code comment literally says *"Monolithic v1: clone, mutate, re-insert"*). Two concurrent puts to the same v1 bucket would each clone the same `forest`, each `upsert_file` independently, each reinsert into `forest_cache` — second write wins, first entry lost.
- **I verified Codex's catch** by reading `encryption.rs:6294-6353`. Confirmed: v7 (ShardedHamt) path uses an inner `tokio::sync::RwLock<ShardedHamtPrivateForest>` (line 6313 takes `forest_arc.write().await`), so concurrent puts serialize correctly. v1 path has no such inner lock.

**Update (user-confirmed 2026-05-21):** walkable-v8 is the wire-format hint flag (default `true` since 2026-05-09 per `fula-client/src/config.rs:332`) — NOT a forest version. The current forest format is **v7 sharded HAMT** (`ForestCacheEntry::ShardedHamt`) with lazy migration from legacy formats on next write (`sharded_diff.txt:443`). For FxFiles' production buckets (all created with a recent SDK) the v1 monolithic path with the lost-update race effectively never fires — Codex's concern lands only on legacy buckets that nobody's written to since the migration date.

**So the SDK lock-scope refactor is safe for FxFiles' production data**, but should still be defensible:
- (i) Keep `write()` for `load_forest` / `flush_forest` (mutate the cache entry itself).
- (ii) Switch puts to `read()` (the v7 path serializes via the inner `RwLock<ShardedHamtPrivateForest>`).
- (iii) Optionally add a per-bucket inner mutex to the v1 clone-mutate-reinsert block as a defense-in-depth for any straggler legacy buckets — small change, future-proof.

**Verified additional findings (post-advisor):**

- **Server-side chunk dedupe does NOT exist** in `put_object_chunked_internal` (`encryption.rs:6399-6534`). The function unconditionally PUTs every chunk and, on any failure, actively `delete_object`s every chunk that succeeded (line 6528-6534). So the user's "restarts from 0" is LITERAL bandwidth waste, not just UX-only progress reset. This makes bridging `resume_upload` high-value.

- **Time-based progress reset** is a separate UX wart: `UploadProgressManager.startBatch` (`upload_progress_manager.dart:72`) zeroes the ETA on every retry. Even if chunks were dedup'd, the bar would still visibly restart.

## Phased plan

### Phase A — app-only, ships independently (no SDK changes needed)

A1. **Sync Queue cancel UI.** Add per-task `LucideIcons.x` button on pending and in-progress rows + "Cancel all" app-bar action. New `SyncService.cancelTask(localPath)` removes from `_uploadQueue`, removes the persistent SyncTask row, sets SyncState to `notSynced`. For in-progress: set a `_canceledLocalPaths` flag the upload loop checks between awaits (graceful; true abort waits for SDK token in Phase B).

A2. **`listObjects` timeout + stale-cache fallback.** Mirror `listBucketsCached` (`fula_api_service.dart:467-496`). New `listObjectsCached(bucket, {prefix})` with 10s timeout, retry once, fall back to per-bucket `ObjectCacheService` snapshot, surface `stale=true`. Wire from `_loadCloudData` and `_loadCategoryFiles`. Solves the "UI hangs forever" symptom even when the SDK lock is held — the UI shows cached files immediately and refreshes when the upload releases the lock.

A3. **Android Foreground Service.** New `SyncForegroundService.kt` calling `startForeground(SYNC_NOTIFICATION_ID, …, FOREGROUND_SERVICE_TYPE_DATA_SYNC)`. Owns the existing sync notification. The service hosts a **background FlutterEngine** (via `FlutterEngineCache`) so the existing `SyncService` keeps running across `MainActivity` destruction. Stop when queue drains. Note: even with this, individual uploads still restart from 0 until Phase B lands — but the process won't be killed mid-upload.

A4. **Don't reset the progress bar on retry.** Track per-task starting offset in `UploadProgressManager.startBatch` so the time-based ETA continues rather than zeroing.

### Phase B — fula-api SDK changes (REVISED 2026-05-22 after test evidence)

**Critical finding from the lost-update repro test** (`fula-api/tests/v1_concurrent_put_race_tests.rs`, run 2026-05-22):

1. **The v1 monolithic path is dead in production.** Calling `seed_v1_forest(...)` then `list_directory(...)` ends with `is_forest_sharded_hamt(bucket) == true` — confirming user's "lazy migration on first read" claim. Codex's v1 concern is moot for any bucket that's been touched on a recent SDK.

2. **The v7 sharded-HAMT path ALSO has a lost-update race**, contrary to Gemini and Cursor's "v7 is safe" claim. With the outer bridge `write().await` removed (direct `EncryptedClient::put_object_flat` calls from `tokio::spawn`-ed tasks), only **1 of 10 concurrent puts** survives the persisted forest. The race is deterministic (3/3 runs returned `count=2` of expected `11`). All 10 calls return `Ok(_)` from the API — they're silent lost writes.

This invalidates the original B1 plan. **The bridge `write().await` is load-bearing for correctness**, not just convenience. Changing it to `read().await` would expose this v7 race in production and corrupt user forests.

What this means for the original goal of "fix UI hang during upload (Issue 2b)":
- A2's `listObjectsCached` + stale-cache fallback (already shipped this session) is **the only practical mitigation** at the app level — UI never hangs because cached content renders immediately and refreshes when the SDK lock frees.
- Fixing the v7 race in the SDK is a separate, deeper investigation. It's almost certainly in `flush_forest`'s interaction with concurrent in-memory upserts — most likely a flush serialization issue where the in-memory state at the time of the *first* flush wins on the server.

### Phase B revised plan

B1. ~~**Lock-scope refactor**~~ **CANCELLED.** Test evidence proves the bridge lock cannot safely be loosened until the v7 lost-update race is fixed in `EncryptedClient::flush_forest` (or wherever the actual race lives).

B1'. **(Optional follow-up SDK investigation)** Diagnose the v7 lost-update from `fula-api/tests/v1_concurrent_put_race_tests.rs`. Codex-advisor's refined hypothesis (validated against the code): inside `save_sharded_hamt_forest`, the SDK snapshots the v7 forest, releases the per-forest write lock during conditional page/dir/root PUTs, then reacquires the lock and calls `reconcile_flush(...)` against the **old snapshot** — overwriting any in-memory upserts that landed during the network round-trip. Likely fix: either (a) hold the forest lock across the entire flush sequence (serializes uploads but eliminates the race), or (b) make `reconcile_flush` merge with intervening live mutations instead of overwriting them. Either is non-trivial. **Don't pursue without explicit user direction** — the bridge lock workaround is correct, just blocking on UI.

B2. **Bridge `resume_upload` and `put_object_encrypted_resumable`** through `fula-flutter`. Still valuable: addresses the actual user pain (Issue 2a "restart from 0%"). Independent of the lock-scope question. New Dart functions `startResumableUpload` + `resumeUpload(manifestPath, filePath)`. Rust tests: BAO rejects modified bytes; successful resume picks up; clean completion deletes manifest.

B3. **Cancellation token** for in-flight encrypted uploads. Add opaque cancel-handle arg, checked between chunk PUTs in `put_object_chunked_internal`. `tokio_util::sync::CancellationToken` internally; opaque FRB handle. Independent of B1' and B2.

### Phase C — wire SDK changes into the app (depends on B2 + B3)

C1. Switch `SyncService._executeUpload` from `uploadLargeFileFromPath` to the resumable variant. Persist `manifest_path` per `SyncTask`.

C2. Wire B3's cancel handle into `SyncService.cancelTask` for true in-flight abort.

C3. Remove the now-redundant "time-based ETA reset" hack from A4 — real per-chunk progress can flow through.

### Phase C — wire SDK changes into the app

C1. Switch `SyncService._executeUpload` from `uploadLargeFileFromPath` to the resumable variant. Persist `manifest_path` per `SyncTask`.

C2. Wire B5's cancel handle into `SyncService.cancelTask` for true in-flight abort.

C3. Remove the now-redundant "time-based ETA reset" hack from A4 — real per-chunk progress can flow through.

---

## Recommended scope for this work

The built-in advisor recommended: **ship Phase A first, then Phase B+C as a separate PR with the SDK safety verification gating the lock change.** Phase A alone:
- Solves Issue 1 fully (cancel UI)
- Solves Issue 2b substantially (UI never hangs even if the lock is still held, because cached listings render immediately)
- Solves Issue 2a partially (process survives app close; individual uploads still restart from 0 until Phase B lands chunk resume)

Phase B+C delivers full chunk-level resume + true cancellation, but requires SDK changes with non-trivial review/test work and the safety verification above.
