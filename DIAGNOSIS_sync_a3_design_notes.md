# A3 — Foreground Service design sketch (deferred from session ending 2026-05-22)

User chose the "full FG service + FlutterEngineCache" approach (vs. WorkManager-on-detach or `flutter_foreground_task` plugin). This file captures the design before code lands so the next session can validate with advisors first.

## Components to build

### 1. `android/app/src/main/kotlin/land/fx/files/dev/SyncForegroundService.kt` (new)
- `extends Service`
- Manifest entry: `<service android:name=".SyncForegroundService" android:foregroundServiceType="dataSync" android:exported="false" android:stopWithTask="false"/>`
- `onCreate`:
  - Build the existing sync notification (reuse the builder logic in `MainActivity.kt:418-455`).
  - `startForeground(SYNC_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)`
  - Spawn the background FlutterEngine:
    ```kotlin
    val cached = FlutterEngineCache.getInstance().get(SYNC_ENGINE_KEY)
    val engine = cached ?: FlutterEngine(applicationContext).also {
      it.dartExecutor.executeDartEntrypoint(
        DartExecutor.DartEntrypoint(
          FlutterInjector.instance().flutterLoader().findAppBundlePath(),
          "syncBackgroundEntrypoint",
        )
      )
      FlutterEngineCache.getInstance().put(SYNC_ENGINE_KEY, it)
    }
    ```
  - Wire a method channel (`land.fx.files/sync_service_bridge`) on the engine for progress updates and stop requests.
- `onStartCommand`: return `START_STICKY`. Handle `ACTION_STOP` extra by calling `stopForeground(STOP_FOREGROUND_REMOVE)` + `stopSelf()`.
- `onDestroy`: tear down the engine (`engine.destroy()`), remove from cache, ensure foreground state is removed.

### 2. `lib/sync_background_entrypoint.dart` (new)
- Top-level function with `@pragma('vm:entry-point')`
- Bootstraps the isolate (mirror `background_sync_service.dart:callbackDispatcher` lines 32-106): RustLib.init → SecureStorage.init → LocalStorage.init → UploadSpeedTracker.init → AuthService.checkExistingSession(skipHeavyOperations: true).
- Acquires the cross-isolate upload lock (see #3 below). Bail out if held.
- Loops: `SyncService.restoreQueue()` → `SyncService.processQueueWithTimeout(Duration(minutes: 30))` → if queue still non-empty, sleep + repeat.
- On lock release (when MainActivity foregrounds), exit gracefully.

### 3. Cross-isolate upload lock
**Hazard**: both MainActivity isolate and service isolate run independent `EncryptedClient` instances with independent DEK generators. If both pick up the same `SyncTask`, the file ends up encrypted twice at two storage_keys; forest registers the later one; earlier becomes orphaned cloud bytes (and wasted bandwidth).

**Plan**: file-system lock on `<documentsDir>/sync_queue.lock` using `dart:io` `File.openSync(mode: FileMode.write).lockSync(FileLock.exclusive)`.
- MainActivity isolate acquires on `processUploadQueue` entry, releases on exit. Drops the lock when entering `AppLifecycleState.paused/detached`.
- Service isolate acquires before processing. If contended (MainActivity still alive and uploading), retry with backoff or wait for the contended-state signal.

**Open question for advisor next session**: do Dart isolates in the same Android process share file locks correctly? `FileLock` is OS-level (`flock` on Linux/Android, `LockFileEx` on Windows). Two isolates = two file descriptors = should work, but verify on a real device.

### 4. MainActivity hooks
- New method channel `land.fx.files/sync_foreground_service`:
  - `startUploadService` → `applicationContext.startForegroundService(Intent(this, SyncForegroundService::class.java))`
  - `stopUploadService` → service Intent with `ACTION_STOP`
- Call `startUploadService` from `SyncService` when the queue becomes non-empty AND we're entering background (`AppLifecycleState.paused/detached`).
- Call `stopUploadService` from `SyncService.resumeIfPending` when the app foregrounds, so the main isolate takes over.

### 5. Progress handoff (UX polish, defer to v2)
- The service isolate starts fresh: no in-memory progress percent.
- For v1: accept that the foreground notification's progress momentarily snaps to "preparing…" when the service takes over, then re-displays the time-based ETA from the persisted `UploadSpeedTracker` stats.
- v2: persist per-task `bytesUploadedSoFar` in the SyncTask Hive row (needs Phase B2's resumable upload to be meaningful).

### 6. `FOREGROUND_SERVICE_DATA_SYNC` 6-hour limit (Android 14+)
- For a single 450MB Wi-Fi upload: fine.
- For long-running multi-file batches: at 5h45m mark, gracefully tear down the service (the queue stays in Hive), schedule a WM one-off task with `initialDelay: 30 minutes` to resume after the 24-hour window resets. Surface to the user via a notification.
- Document the limit in the user-facing settings page.

## Risks / open questions (next session)

- Two FlutterEngines in the same process eat extra RAM (~50 MB each). Worth checking on low-end devices.
- Re-instantiating the encrypted client in the service isolate triggers a cold-load of the forest from master (IPNS + base.org RPC). If that fails (the exact scenario in the user's log), the service-driven upload also stalls. Phase B fixes (resume + faster forest cache) would help here.
- The `stopWithTask="false"` flag means our service survives task removal — but Android can still kill it under memory pressure. `START_STICKY` requests a restart; verify the restart path actually re-spawns the engine and resumes uploads.
- Method channel between service and engine: confirm we can post messages from Kotlin (`MethodChannel(engine.dartExecutor.binaryMessenger, ...)`) to drive progress UI updates that the service-owned notification displays.

## Test plan

- Manual on a real Android 15 device: start a 100 MB upload, swipe app away, observe (a) notification stays, (b) Wi-Fi upload continues, (c) reopen app and progress is correctly reflected.
- Verify only one upload runs at a time (open app while service is mid-upload, check logs for double-PUT to S3 chunks).
- Memory: monitor process memory before/after service spin-up.
- 6-hour limit: simulate by setting the service's foreground-allowed window to a short value (test build only) and verify graceful handoff.
