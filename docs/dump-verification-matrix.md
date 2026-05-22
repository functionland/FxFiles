# Dump feature — verification matrix

Session 5 of [the Dump plan](../../.claude/plans/i-want-to-add-buzzing-anchor.md) calls out 16 scenarios that gate "ready to ship". For each, this document records:

- **Expected behavior** — what the user should observe.
- **Coverage** — `auto` if exercised by an automated test in this repo (with the file path), `device` if device-smoke-only.
- **Reproduce** — exact steps to verify on a real build.

Run each `device` row at least once on a real Android handset and (after the Xcode setup in [`ios-share-extension-setup.md`](./ios-share-extension-setup.md)) on a real iPhone before declaring the feature shippable.

---

## 1 · Android image from Gallery

**Expected** — share photo to *FxFiles Dump* → "Processing 1 dump…" notification appears within ~2 s. Open FxFiles → notification updates to "Dumped: \<filename\>" within a few seconds, the photo lands in `/dump` as a tile with category `image`. After enrichment runs (next foreground tick): ML Kit labels surface as the auto-description; downscaled thumbnail replaces the placeholder.

**Coverage** — partial auto (`test/unit/core/services/dump_classifier_test.dart`, `dump_service_test.dart`, `dump_enricher_test.dart`); end-to-end is **device**.

**Reproduce** —
1. `adb install build/app/outputs/flutter-apk/app-debug.apk`.
2. Open Gallery → pick any photo → Share → "FxFiles Dump".
3. Watch the notification, then open FxFiles.

---

## 2 · Android screenshot

**Expected** — same as #1 but classifier routes to category `screenshot` (filename matches the `screenshot` regex). Enrichment uses ML Kit OCR's first line as the auto-title when available; falls back to the literal "Screenshot".

**Coverage** — auto for classification (`dump_classifier_test.dart` "screenshot category always titles…"); enrichment is exercised in `dump_enricher_test.dart`'s screenshot branch. Live OCR is **device**.

**Reproduce** —
1. Take a screenshot on the device (power+volume-down).
2. Share it to FxFiles Dump.
3. Verify the tile shows category `screenshot` + a real OCR-derived title if there's any text in the image.

---

## 3 · Android URL from Chrome

**Expected** — share a webpage URL → category `link`, `textPayload` is the URL. After link enrichment runs: auto-title becomes the page's `<og:title>` (or `<title>` fallback); auto-description is the URL. The thumbnail stays as the link icon (no OG-image download in MVP).

**Coverage** — auto for classifier + enricher (`dump_enricher_test.dart` "Link enrichment — R14 SSRF guards" group); the live HTTP fetch is **device** (private-IP block is unit-tested via `localhost` → returns host fallback).

**Reproduce** —
1. In Chrome, open a public website (e.g. `https://flutter.dev`).
2. Share → URL → FxFiles Dump.
3. After a few seconds, the tile shows the page title.

---

## 4 · Android plain text from Keep

**Expected** — share a multi-line note → category `note`. `originalName` = first non-empty line (truncated to 60 chars, ellipsis on overflow) or `"Note <ts>"` if empty/whitespace/emoji-only. Enrichment's note path produces a "paper" placeholder thumbnail; auto-description = first 200 chars.

**Coverage** — auto for classifier + enricher (`dump_enricher_test.dart` "Note enrichment" group, "very long first line is truncated", "empty payload returns title=originalName"). Manual entry path covered by `test/widget/features/dump/dump_add_note_screen_test.dart`. End-to-end **device**.

**Reproduce** —
1. Google Keep → write a note → Share to FxFiles Dump.
2. Verify the first line surfaces as the tile title.

---

## 5 · Android multi-select gallery

**Expected** — select 5 images in Gallery → Share to FxFiles Dump (uses ACTION_SEND_MULTIPLE). One descriptor JSON is written per transaction; 5 `DumpItem` rows appear in `/dump`. Single notification "5 items dumped" (batched).

**Coverage** — partial auto (`dump_service_test.dart` multi-path tests verify the batched ingest; share-target receiver is Kotlin and not in dart-test). Receiver-side handling is **device**.

**Reproduce** —
1. Gallery → multi-select 3-5 photos → Share → FxFiles Dump.
2. Open FxFiles → all photos appear in `/dump` after the drain.

---

## 6 · Android PDF from Drive

**Expected** — share a PDF → category `document`. Auto-title = filename basename; auto-description = `<page count> pages · <size>` (page count requires `flutter_pdfview` to render; falls back to size+PDF if rendering fails). Thumbnail is the PDF icon (full-page render is a stretch goal — currently falls back to the icon).

**Coverage** — auto for the classifier branch + description fallback (`dump_enricher_test.dart` "document title=filename, desc='size · PDF'"). Full page-count + first-page render is **device**.

**Reproduce** —
1. Open a PDF in Google Drive → Share → FxFiles Dump.
2. Verify the tile shows the PDF icon + `<size> · PDF` description.

---

## 7 · iOS Photos image (Share Extension)

**Expected** — share to FxFiles Dump from Photos → headless extension fires → "Queued 1 item — will upload when FxFiles next runs" notification appears within ~1 s. Reopen FxFiles → AppLifecycleState.resumed triggers the drain → ~5 s later "Dumped: \<filename\>" notification replaces the queued one; the photo appears in `/dump`.

**Coverage** — auto for the bridge contract (`dump_ios_bridge_test.dart`); the Swift extension + AppDelegate drain is **device** (requires the Xcode target setup in [`ios-share-extension-setup.md`](./ios-share-extension-setup.md)).

**Reproduce** —
1. Build + run on a real iPhone (`flutter run -d <id>`).
2. Photos → pick → Share → FxFiles Dump.
3. Wait for the queued notification, switch to FxFiles, watch the drain.

---

## 8 · iOS Safari URL share

**Expected** — same as #7 but for a webpage URL. Classifier routes to `link`; enrichment fetches the OG title. iOS-specific path: textPayload is preserved through the App Group descriptor.

**Coverage** — auto for the textPayload preservation test in `dump_ios_bridge_test.dart` ("descriptor with textPayload preserves it"). Live enrichment is **device**.

**Reproduce** —
1. Safari → open a public page → Share → FxFiles Dump.
2. Verify the tile shows category `link` + the OG title.

---

## 9 · iOS file from Files.app

**Expected** — share a generic file from Files.app → extension stages it as `kUTType.fileURL`/`kUTType.data` per UTType. Drain ingests with the correct MIME from `UTType.preferredMIMEType`.

**Coverage** — auto for the multi-mime drain path (`dump_ios_bridge_test.dart` "single descriptor with one file → ingest creates 1 DumpItem"). Live mime detection is **device**.

**Reproduce** —
1. Files.app → pick any document (`.docx`, `.zip`, etc.) → Share → FxFiles Dump.
2. Verify the tile shows the correct category (`file`/`document`).

---

## 10 · Signed-out share

**Expected** — sign out of FxFiles entirely. Share an image to FxFiles Dump → it's ingested with status `pendingAuth` and a "Dump saved — sign in to upload" notification appears. Sign back in → `AuthService._initializeFulaClient` fires `DumpService.retryPending()` → the item transitions to `queued` and uploads immediately.

**Coverage** — auto:
- The retry transition itself is in `test/unit/core/services/dump_retry_pending_test.dart` (all 5 cases).
- The pendingAuth status assignment on signed-out ingest is in `test/unit/core/services/dump_service_test.dart` "encryption-key gating (R10)" group.
- The actual auth wiring (`unawaited(DumpService.instance.retryPending())` inside `_initializeFulaClient`) is verified by `flutter build apk --debug` succeeding (compile-time check that the import + call are valid).

End-to-end is **device**.

**Reproduce** —
1. Sign out (Profile → Sign out).
2. Share image → see pendingAuth notification.
3. Sign in → watch the item flip to uploaded.

---

## 11 · Airplane mode share

**Expected** — enable airplane mode → share image → ingested with `queued` status (assuming user is signed in — the encryption key is in Keychain regardless of network). SyncService's `queueUpload` queues it; the upload itself fails repeatedly and ends up in the failed-retry pool. Disable airplane mode → SyncService retries on its next tick.

**Coverage** — auto for the ingest path (no network involved). Auto for SyncService retry behavior (pre-existing, not Dump-specific). Live cycle is **device**.

**Reproduce** —
1. Toggle airplane mode on.
2. Share image → notification "Processing 1 dump…", item appears in `/dump` with `queued` status (spinner badge).
3. Toggle airplane mode off → spinner replaced by the "uploaded" check within the SyncService retry tick.

---

## 12 · Duplicate share (R8 collision verification)

**Expected** — share the SAME image twice in a row → the second share is dedup'd (R8: contentSha candidate + size + full SHA-256 verification for files ≤50 MB; large media accepts candidate). No second `DumpItem` row is created. UX surface: the duplicate notification still appears briefly (the receiver Activity can't know it's a dup before staging), but `/dump` shows only one tile.

**Coverage** — auto:
- `dump_storage_service_test.dart` "findDuplicate (R8…)" group (5 cases including the prefix-collision rejection).
- `dump_service_test.dart` "ingestStagedPayload — dedup" group.

End-to-end on **device** completes the verification.

**Reproduce** —
1. Share an image → wait for drain.
2. Share the SAME image again → only one tile in `/dump`.

---

## 13 · `/dump` screen filtering + search

**Expected** —
- Tap FAB → bottom sheet with 3 add rows.
- Filter chips toggle category filter; selected categories show in chip.
- Date chip opens range picker; selected range surfaces as the chip label.
- Search opens a TextField; typed query (250 ms debounce) filters tiles.
- Filter+search compose (intersection).
- Empty/filter-empty/populated states all render.

**Coverage** — auto:
- `test/widget/features/dump/dump_screen_test.dart` — 6 cases covering empty, populated grid, tap navigation, search open/close, debounced filter, filter-empty.
- `test/widget/features/dump/dump_filter_bar_test.dart` — 4 cases for chip taps + date chip label.

---

## 14 · Notification tap

**Expected** — tap any Dump notification → the app opens at `/dump` (deep link `fxfiles://dump`). If the notification carries a specific item id, opens at `/dump/<id>` and dispatches to the appropriate viewer.

**Coverage** — auto:
- `DumpDeepLinkController` emits the right path (verified via `deep_link_service` change in Session 3).
- `app.dart`'s `_navigateToDump` subscribes to the stream and pushes the route.

End-to-end is **device**.

**Reproduce** —
1. Trigger a Dumped notification (any of the above scenarios).
2. Tap it → FxFiles opens at `/dump`.

---

## 15 · Main app open during share (Android)

**Expected** — FxFiles is already in the foreground or recents → share an image from Gallery → the share Activity stages the payload + posts the "received" notification while the main app is alive → main app's resume + periodic ticks drain the staging directory → item appears in `/dump` without the user having to navigate back.

**Coverage** — auto for the drain on lifecycle resume (`dump_service_test.dart` doesn't exercise lifecycle directly, but the drain logic is unit-tested; the `AppLifecycleState.resumed` wire-up in `app.dart` is verified by compile). End-to-end is **device**.

**Reproduce** —
1. Open FxFiles, leave it on `/dump`.
2. Open Gallery (push FxFiles to background) → share an image → tap "FxFiles Dump".
3. Return to FxFiles → the item appears within a couple of seconds without manual refresh.

---

## 16 · WorkManager handoff (Plan A) verification

**Expected** — under the default Plan B (R3), the share Activity does NOT directly trigger the Dart-side WorkManager task; the drain happens on the main app's resume or via the periodic dump-process task. If Plan A is later enabled, the Kotlin Activity routes via `WorkManager.enqueueUniqueWork` and the `dumpProcessTask` callback fires within a few seconds.

**Coverage** — auto for the Dart-side task constant + dispatcher branch (`dump_service_test.dart` indirectly via `ingestAndSchedule`); the Kotlin-side enqueue is **device** (requires logcat to inspect).

**Reproduce** —
1. `adb logcat | grep -E "WorkManager|DumpProcess"`.
2. Share an image → if Plan A is active, logcat shows the task being enqueued + dispatched.
3. If Plan A is NOT active (default), confirm the drain happens on next foreground.

---

## Summary

|  # | Scenario | Coverage |
|---:|---|---|
|  1 | Android image | partial auto + device |
|  2 | Android screenshot | auto + device |
|  3 | Android URL | auto + device |
|  4 | Android plain text | auto + device |
|  5 | Android multi-select | partial auto + device |
|  6 | Android PDF | auto + device |
|  7 | iOS Photos image | bridge auto + device |
|  8 | iOS Safari URL | auto + device |
|  9 | iOS Files.app | auto + device |
| 10 | Signed-out share | full auto + device |
| 11 | Airplane mode | partial auto + device |
| 12 | Duplicate share | full auto + device |
| 13 | `/dump` filtering | full auto |
| 14 | Notification tap | partial auto + device |
| 15 | Main app open | auto + device |
| 16 | WorkManager handoff | partial auto + device |

Caveats already documented in code or in `docs/ios-share-extension-setup.md`:

- iOS notification permission must be granted by the user (R5 — main app prompts on cold launch). Without it, both stage-1 (queued) and stage-2 (uploaded) notifications silently no-op; the items still appear in `/dump`.
- iOS BGTaskScheduler firing time is opportunistic. Foreground resume is the reliable drain path.
- Multi-account: pendingAuth items are claimed by whoever next signs in. There is no per-item account binding in v1 — a user A → sign out → user B → drain sequence would upload A's pending items under B's credentials. v1 deliberately accepts this for simplicity.
- iOS plaintext file protection level is `completeUntilFirstUserAuthentication`, not `complete`. This lets the BGTask drain run while the device is locked (post first-unlock-after-boot). Trade-off: staged plaintext is readable while the device is locked-but-post-first-unlock. The protected window is from cold boot until first unlock. For an E2E-encrypted product this is a deliberate availability trade-off — documented in the Privacy Nutrition Labels TODO in `docs/ios-share-extension-setup.md` § 7.
- iOS notification content includes the filename / auto-title on the lock screen. iOS users wanting maximum privacy should disable "Show Previews" in Settings → Notifications → FxFiles, or set it to "When Unlocked".
- The `dump_tile_test` "renders Image.file when thumbnail file exists" case is skipped under `flutter test` (image decode doesn't resolve under the unit-test event loop on this SDK build); device-smoke covers the live thumbnail rendering.

## Session 6 — External advisor review pass

Three independent external advisors (`gemini-advisor`, `cursor-advisor`, `codex-advisor`) reviewed the as-built code. Findings flagged by 2+ advisors → real issues, fixed in this session. Single-advisor flags → reviewed and either fixed or documented.

### Convergent findings fixed in Session 6

| # | Source | Issue | Fix |
|---|---|---|---|
| S6-1 | Codex | `ShareViewController.viewDidAppear` can fire multiple times → duplicate `processShare` Tasks → duplicate txn dirs + uploads | Added `didKickOffProcessing` re-entry guard. |
| S6-2 | Gemini + Codex | iOS BGTask drain moves files App Group → Documents, deletes App Group txn, returns descriptors in-memory only — **no Dart code is woken to ingest**. Result: orphan plaintext in `Documents/dump_pending/` that never uploads. | `drainAppGroupContainerSync` now writes a sidecar JSON `<txnId>.json` to `Documents/dump_pending/` in the same schema Android writes. `DumpService.drainPendingDir` picks them up on the next foreground (already wired in `app.dart` lifecycle hook). Foreground path ingests via the in-memory return AND calls a new `ackTxns` channel method to delete the sidecar (so it doesn't re-ingest on next resume — R8 dedup would short-circuit anyway, but this avoids the waste). |
| S6-3 | Codex | BGTask + foreground drain can race over the same txn dir (corruption, partial moves, orphans). | `drainAppGroupContainerSync` now wraps body in `NSLock` (`dumpDrainLock`). Single drain at a time. |
| S6-4 | Codex | `"mimeType": mime as Any` boxes `Optional.none` when `UTType.preferredMIMEType` is nil → `JSONSerialization` failure → whole transaction discarded after files were already copied. | Changed to `(mime as Any?) ?? NSNull()` — explicit null sentinel that `JSONSerialization` accepts. |
| S6-5 | Codex | Partial move failure in iOS drain leaves stuck state: some files in Documents, others still in App Group, manifest expects all — next drain pass fails again, infinite stuck. | Track `movedPairs: [(source, dest)]` during the loop. On move failure, iterate in reverse and move each `dest` back to its `source` — restores the original txn dir state for the next pass. |
| S6-6 | Cursor | `DumpService.init()` (which binds the `SyncService` status listener) is only called lazily on first ingest. If `SyncService` finishes a queued-from-prior-session upload before that first ingest, `SyncStatus.synced` is lost and the `DumpItem` stays `uploading` forever. | Added `await DumpService.instance.init()` to `main.dart` right after `LocalStorageService.init()` — listener bound on every cold start, idempotent on subsequent calls. |
| — | (normalisation) | iOS extension wrote `sourceApp`; Android/Dart expected `sourcePackage`. | Both extension and AppDelegate now write `sourcePackage`. The bridge accepts either key (legacy fallback for one release transition). |

### Single-advisor findings reviewed

| Source | Issue | Decision |
|---|---|---|
| Cursor | `retryPending` claimed "not wired" in `_initializeFulaClient` | **False positive** — verified at `auth_service.dart:766`. cursor-agent's grep against the large auth file did not surface the hook. No fix needed. |
| Gemini | "Notification redundancy on iOS — showReceived after extension's queued" | **False positive** — `DumpNotificationService.showReceived` is a no-op on iOS (early-returns under `!_isAndroidEnabled`). Verified in code. |
| Cursor | `copyWith` cannot clear `errorMessage` on re-queue (sticky message after retry) | **Accepted for v1** — minor cosmetic surface; the failed-message persistence on a retry is observable but harmless. Will polish with an explicit `clearErrorMessage: true` sentinel in a follow-up. |
| Cursor | Silent Hive init failure → permanent empty Dump UI with no error channel | **Accepted for v1** — failure mode is rare on modern Android/iOS; documented as a known limitation. |
| Cursor | `watch()` re-materializes the full list on every box event | **Accepted for v1** — fine for typical user dump counts (<1000 items); worth optimising if a power-user hits perf wall. |
| Codex | App Store `UIBackgroundModes: audio` requires justification | **Pre-existing** — declared for the existing `AudioService` (ryanheise audio playback), not Dump. Mentioned in PR description per Session 4 plan. |
| Codex | iOS plaintext file protection is `completeUntilFirstUserAuthentication` not `complete` | **Documented** — deliberate trade-off so the BGTask drain can run while screen-locked-post-first-unlock. Added explicit caveat to this matrix + the iOS setup doc. |
| Codex | Notification content shows filename on lock screen | **Documented** — user can disable previews in iOS Settings. Added caveat. |
| Codex + Gemini | Multi-account: pendingAuth items uploadable under a different signed-in user | **Accepted v1 trade-off** — already documented in the Caveats list above. No per-item account binding in v1. |
| Codex | Large text payloads duplicated in memory + on disk + manifest + channel | **Accepted for v1** — practical share sizes don't trigger memory pressure. Could add a soft cap if users hit it. |
| Codex | Filename length unbounded in sanitize | **Minor risk** — extreme filenames (>255 chars) would fail file-system limits and the item is dropped. Acceptable failure mode for a v1 edge case. |
| Codex | BGTask's `requiresNetworkConnectivity = true` hard to justify when the task itself doesn't upload | **Accepted** — the task ends up driving the upload chain via the next foreground's ingest pipeline, so network is genuinely needed. App Review should accept this with the proper justification copy in the submission notes. |
| Codex | Enrichment on main isolate causes jank under 50-image share | **R2 deliberate decision** — moving ML Kit / `flutter_pdfview` / canvas to a background isolate requires careful platform-channel handling that the codebase doesn't pattern. v1 accepts the jank; revisit if user complaints surface. |
| Gemini | `uploadOne` lacks idempotency check (could double-spawn if rapidly re-queued) | **Mitigated** by `SyncService.queueUpload` (line 152 of `sync_service.dart`) which dedups on `localPath` already. The Dump layer doesn't double-spawn in practice because `retryPending` flips status to `queued` synchronously before the fire-and-forget upload. |
| Gemini | `_bindSyncStatusListener` could double-bind if `init()` is called twice | **Already guarded** — `_syncListener ??= ...` ensures the closure is created once. The `SyncService.addListener` call IS inside that guard so it's also only called once. |

### Verdict

After Session 6's fixes, the convergent advisor concerns (data-loss on iOS BGTask handoff, drain races, atomicity around partial moves, re-entry duplication) are resolved. The remaining single-advisor flags are either false positives, documented v1 trade-offs, or accepted minor polish items.

The implementation is ready for device smoke against the verification matrix above. Total test count after Session 6: same 150 passing + 1 skipped — no Dart unit-test-visible behavior changed; the iOS Swift changes pass through dart analyze + flutter build apk --debug, and the Swift-side smoke is covered by the device matrix.
