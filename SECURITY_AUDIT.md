# FxFiles Security Audit

Last updated: 2026-04-20

## Scope and methodology

This audit covers the FxFiles Flutter application (this repository). It does
**not** re-audit the `fula_client` dependency, which has its own audit; the
crypto / storage / share-token primitives it exposes are trusted here.

The review was a line-by-line read of every service under
`lib/core/services/`, the deep-link handler (`lib/core/services/deep_link_service.dart`),
the app-level handlers in `lib/app/app.dart`, platform configuration
(`android/`, `ios/Runner/Info.plist`, `pubspec.yaml` MSIX block), and every
data model that serializes to or from cloud / deep-link input.

Each finding below was confirmed by reading the exact source, not by agent
summaries.

## Threat model assumptions

Things we explicitly do **not** defend against:

- **Physical device access after passcode bypass.** Once the OS keychain /
  Keystore / DPAPI is unlocked, an attacker with arbitrary code execution on
  the device can read anything this app can read.
- **Malicious server with access to ciphertext at rest.** The confidentiality
  bound here is whatever `fula_client` provides; we do not add a second
  defense-in-depth layer on top.
- **Holders of a share or collaboration link fragment.** Anyone with the `#`
  fragment of a share or collab URL is an intended participant. See
  "Not vulnerabilities — by design" below.

## Fixed in this pass (CRITICAL + HIGH)

### CRITICAL

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| 1 | Zip-slip in archive extraction | `lib/core/services/archive_service.dart` `_extractZipIsolate` | Entries now go through `safeJoin`; entries that escape the output dir are skipped with a log. |
| 2 | Path traversal on WhatsApp restore | `lib/core/services/whatsapp_backup_service.dart` restore loop | Target paths are resolved via `safeJoin`; unsafe `relativePath` entries are skipped. |
| 3 | Path traversal on collab folder sync | `lib/core/services/collab_folder_sync_service.dart` `_resolveLocalPath` + tombstone delete | `fileName` and `pathScope` are sanitized per-segment and joined via `safeJoin`. Unsafe entries are marked `download_failed` so they don't retry each poll. |
| 4 | `fxfiles://shell/*` deep links silently queue uploads/shares/collab | `lib/core/services/deep_link_service.dart` `_handleShellCommand`; `lib/app/app.dart` shell handlers | `_handleShellCommand` is now gated to `Platform.isWindows` — shell context menus are Windows-only by design; `windows/runner/main.cpp` is the sole legitimate producer. On Windows, paths outside the current user's profile directory are rejected before the UI layer is invoked, and all shell handlers (`_handleShellUpload`, `_handleShellShare`, `_handleShellCollab`, `_handleShellAcceptCollab`) show a modal confirmation dialog displaying the resolved path before acting. |
| 5 | `fxfiles://auth-callback?key=…` silently replaces an already-stored JWT | `lib/core/services/deep_link_service.dart` `_storeApiKey` | First-time writes and idempotent re-logins still proceed silently (legitimate cloud.fx.land → redirect flow). When the incoming key differs from a non-empty stored key, `onApiKeyReplaceProposed` fires; the UI in `lib/app/app.dart` `_promptApiKeyReplace` shows a confirmation dialog and either calls `confirmApiKeyReplace()` or `rejectApiKeyReplace()`. |

### HIGH

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| 6 | iOS Keychain accessibility too broad | `lib/core/services/secure_storage_service.dart` | Changed `KeychainAccessibility.first_unlock_this_device` → `first_unlock`. Preserves background-task access (WorkManager / BGTaskScheduler) while narrowing the `kSecAttrAccessible` class. `passcode_this_device` was explicitly rejected — it would lock out users with no device passcode. |
| 7 | Collaboration expiry defined but not enforced | `lib/core/services/collaboration_service.dart` | Added `_assertNotExpired(group)`; called at the top of `downloadCollabFile`, `uploadCollabFileFromLocal`, `addFileToGroup`, `removeFileFromGroup`, and `refreshGroup`. Throws `CollaborationException('Collaboration has expired')` when `group.isExpired`. |
| 8 | Revocation list was local-only | `lib/core/services/sharing_service.dart` + `cloud_share_storage_service.dart` + `sharing_provider.dart` | Added `uploadRevokedList` / `downloadRevokedList` to `CloudShareStorageService`, a best-effort push in `_addToRevokedList`, and a cloud-merge step in `SharesNotifier.loadShares` that calls `SharingService.importRevokedShareIds`. Revocations made on device A now apply after a restore on device B. |
| 9 | JWT and long URLs logged via `debugPrint` | `auth_service.dart`, `ipfs_public_service.dart`, `billing_api_service.dart` | Replaced token previews / full URLs / full response bodies with presence flags and status codes only. `debugPrint` is stripped in Flutter release builds, but a debug/profile build no longer leaks tokens or CIDs to logcat / Console.app. |

### Common helper

`lib/core/utils/safe_path.dart` centralises filesystem-traversal defences used
by the three path-traversal fixes:

- `safeJoin(baseDir, untrustedRelative)` — normalises and asserts the result
  stays under `baseDir`; throws `FormatException` otherwise.
- `sanitizeFileName(name)` — strips path separators and traversal tokens so a
  single manifest field can't masquerade as a relative path.

## Not vulnerabilities — by design

These were flagged during the audit but are intentional behaviours of the
sharing / collaboration design. They are recorded here so future reviewers
don't re-flag them without reading this file.

1. **Collaboration manifest merge does not authenticate who added a file.**
   `lib/core/models/collaboration_group.dart` `mergeWith` does a blind union
   of `files` and `removedFileIds` across local, S3, and server manifests.
   The collaboration link secret lives in the URL fragment (`#sk=…`) and is
   never sent to the server; anyone who has the link is an intended
   full-access collaborator. Any such party can add or remove files by
   construction. Defense-in-depth checks here would break the design.

2. **Share tokens are reusable; no consumption tracking.**
   `lib/core/models/share_token.dart` has no `isConsumed` /
   `downloadCount` / `maxDownloads` fields, and the backend does not expose
   an "exchange token for a single download" endpoint. Public share links
   with a fragment secret are meant to be redeemable repeatedly by anyone
   who has the full URL. "Revocation" (the list synced via fix #8) is the
   only enforcement mechanism, and it is best-effort (a cached manifest on
   a device that never re-opens the app will not honour it).

3. **`fxfiles://auth-callback?key=…` first-time write is silent.**
   When the stored JWT is empty (first-time login) or equal to the incoming
   key (idempotent re-login), the incoming key is written with no prompt.
   This is the legitimate flow: the user taps "Get API key" in the app,
   cloud.fx.land redirects back with the key, and the app stores it. Only
   when the incoming key differs from a non-empty stored key does fix #5
   prompt the user.

## Second pass — MEDIUM / LOW fixed (2026-04-20)

Follow-up pass expanding scope to robustness, error handling, and UX in
addition to remaining security. Every change was verified by reading the
exact lines cited before and after the edit.

### Security

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| S1 | Cloud HTTP calls had no timeout — UI could hang on slow/unresponsive backends | `ipfs_public_service.dart`, `billing_api_service.dart`, `collaboration_service.dart`, `sharing_service.dart`, `cloud_share_storage_service.dart` | Added `.timeout(...)` to every `http.get/post/put/delete` and `MultipartRequest.send()`. 15s for reads, 30s for writes/manifests, 60s for file downloads, 5min for uploads. `TimeoutException` propagates through existing catch blocks. |
| S2 | Hive metadata boxes for face embeddings and OCR tags were plaintext on disk | `face_storage_service.dart`, `tag_storage_service.dart`, `secure_storage_service.dart`, `lib/core/utils/hive_cipher.dart` *(new)* | Boxes now open with `HiveAesCipher`, keyed from a per-install AES-256 key stored under `SecureStorageKeys.hiveMetadataKey`. Legacy plaintext boxes are deleted and rebuilt on first open failure (data is re-derivable by rescanning). |
| S3 | Predictable timestamp-based temp filenames in OS temp dir | `website_service.dart:525` | Replaced `millisecondsSinceEpoch` with `_uuid.v4()` for the website video-thumbnail scratch file. Other `millisecondsSinceEpoch` uses reviewed and cleared as not vulnerable (app-private `.trash`, WorkManager task IDs, S3 object keys, content-hashed caches). |
| S4 | No Windows reserved-name validation on create/rename | `safe_path.dart`, `file_service.dart` | Added `isReservedWindowsName()` (case-insensitive match against `CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9` after stripping extension) and `invalidFilenameCharsPattern`. `createDirectory` and `renameFile` throw on match when `Platform.isWindows`; invalid-character check runs on all platforms. |

### Robustness

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| R1 | `_pauseQueue` used `Future.delayed` without persistence — force-kill mid-pause stranded `_consecutiveFailures` | `sync_service.dart` | `_pausedUntil` is now persisted to SecureStorage (`SecureStorageKeys.syncPausedUntil`). `restoreQueue` calls `_restorePauseState()` which re-schedules or clears based on the persisted timestamp. Max pause capped at 10 min to prevent a stale value from wedging the queue. |
| R2 | `json['shares'] as List<dynamic>` crashed on malformed cloud manifest (pure-client DoS) | `cloud_share_storage_service.dart`, `cloud_collaboration_storage_service.dart`, `cloud_sync_mapping_service.dart` | Replaced with null-safe casts and type guards; `jsonDecode` wrapped in try/catch that logs and returns an empty list. Non-map entries within a list are skipped individually. |
| R3 | Rapid concurrent `startSync()` calls for the same group raced and could leak watchers | `collab_folder_sync_service.dart` | Added `_startingSync` set; `startSync` returns early if already in progress for that group, removes the entry in `finally`. `_startSyncDirect` still cancels any existing watcher first. |
| R4 | `UploadProgressNotifier` listener could throw during a Riverpod rebuild race | `upload_progress_provider.dart` | Listener body wrapped in try/catch; added `onError` on the stream subscription. `ref.onDispose` cancellation preserved. |
| R5 | Startup `Future.microtask` / `Future` fire-and-forget had no error handling | `main.dart` | `SyncService.restoreQueue`, initial `loadStorageInfo`, and `FaceStorageService.init().then(...)` chain are now wrapped in try/catch or `.catchError` so a startup failure logs once instead of producing an unhandled async exception. |

### UX

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| U1 | Sign-out had no confirmation — one-tap destructive action | `settings_screen.dart` | Added `AlertDialog` confirmation with explanatory body before calling `AuthService.signOut()`. |
| U2 | "Clear Cache" was a no-op that lied to the user | `settings_screen.dart` | Implemented: confirmation → progress dialog → recursively deletes temp + cache directories (never the app-support dir / Hive / tokens) → snackbar reporting bytes freed. |
| U3 | `_PermissionChip` used `Colors.grey[200]` — unreadable in dark mode | `share_screen.dart` | Swapped to `Theme.of(context).colorScheme.surfaceContainerHighest` for background and `textTheme.labelSmall` with `onSurfaceVariant` for text so both track the active theme. |
| U4 | Hardcoded `Colors.white` / `Colors.black` on themed backgrounds | `file_browser_screen.dart` | Swapped selection-check icon and SnackBar spinner colors to `colorScheme.onPrimary` / `onInverseSurface`. Fixed-color blue chips with white download icons left intact (foreground + background both fixed — contrast guaranteed by construction). |
| U5 | Password setup dialog had no show/hide toggle and a 6-char min for an irrecoverable password | `password_setup_dialog.dart` | Added visibility toggle to both fields. Minimum raised to 12 characters with "16+ recommended" helper text and strengthened error message. |
| U6 | Rename dialog accepted invalid characters and oversized names | `file_browser_screen.dart` | TextField now has `maxLength: 200`, `FilteringTextInputFormatter.deny(invalidFilenameCharsPattern)`, live validation via `StatefulBuilder`, and the Rename button is disabled while invalid. Reuses the S4 reserved-name helper. |
| U7 | Search empty-state did not echo the query back | `search_screen.dart` | Empty-state now shows `No results for "<query>"`. |
| U8 | Auto-clipboard write after collab group creation — other apps can harvest the URL-fragment secret | `share_screen.dart` | Removed the unconditional `Clipboard.setData(...)` after group creation; the success snackbar now has a "Copy link" action that requires a user tap. Other copy sites (menu actions and explicit "Copy Link" buttons) are already user-initiated and left as-is. |

### Still deferred (after second pass)

- **Certificate pinning for `*.cloud.fx.land`.** `ipfs_public_service.dart`,
  `billing_api_service.dart`, and `collaboration_service.dart` make HTTPS
  requests using the default system trust store. A compromised CA could
  MITM uploads / pin requests / collab manifests. Pinning via a custom
  `SecurityContext` or `http.BaseClient` is the standard mitigation.
- **OAuth client IDs are hardcoded.** `lib/core/services/auth_service.dart`
  and `lib/core/services/wallet_service.dart` ship with their Google /
  Apple / WalletConnect client IDs inline, as does `ios/Runner/Info.plist`.
  These IDs are considered public, but rotating them requires a coordinated
  release.
- **Password-protected shares are brute-forceable offline.** A holder of a
  password-protected share ciphertext can brute-force the password with
  Argon2id locally. Owner-chosen strong passwords mitigate this, but the
  current UI does not enforce a minimum strength on share creation
  (distinct from the per-app backup password strengthened in U5).
- **Collab link secret in URL fragment leaks via browser history.** When a
  collab link is opened in a browser before being handed to the app, the
  URL (including fragment) is recorded in browser history and, on some
  platforms, system recents. Short-TTL links or per-device derivation would
  fix this but is a design-level change.
- **`android:requestLegacyExternalStorage="true"` on Android.** The app
  still requests the legacy storage mode for compatibility with older API
  levels. Migrating to scoped storage (MediaStore / SAF) is the long-term
  fix.
- **Hive boxes beyond face/tag metadata remain plaintext.** Sync state and
  folder-watch state still leak filenames/folder structure. Lower-value
  than face embeddings and tags; the `getHiveMetadataCipher` helper is
  reusable when this is addressed.

## Files touched in first pass (CRITICAL + HIGH)

- `lib/core/utils/safe_path.dart` *(new)*
- `lib/core/services/archive_service.dart`
- `lib/core/services/whatsapp_backup_service.dart`
- `lib/core/services/collab_folder_sync_service.dart`
- `lib/core/services/deep_link_service.dart`
- `lib/app/app.dart`
- `lib/core/services/collaboration_service.dart`
- `lib/core/services/secure_storage_service.dart`
- `lib/core/services/cloud_share_storage_service.dart`
- `lib/core/services/sharing_service.dart`
- `lib/features/sharing/providers/sharing_provider.dart`
- `lib/core/services/auth_service.dart`
- `lib/core/services/ipfs_public_service.dart`
- `lib/core/services/billing_api_service.dart`

## Files touched in second pass (MEDIUM + LOW + robustness + UX)

- `lib/core/utils/hive_cipher.dart` *(new)*
- `lib/core/utils/safe_path.dart` — reserved-name helper + invalid-char pattern
- `lib/core/services/secure_storage_service.dart` — new `hiveMetadataKey`, `syncPausedUntil` keys
- `lib/core/services/sync_service.dart` — persisted pause state
- `lib/core/services/cloud_share_storage_service.dart` — null-safe JSON
- `lib/core/services/cloud_collaboration_storage_service.dart` — null-safe JSON
- `lib/core/services/cloud_sync_mapping_service.dart` — null-safe JSON
- `lib/core/services/collab_folder_sync_service.dart` — startSync mutex
- `lib/core/services/ipfs_public_service.dart` — HTTP timeouts
- `lib/core/services/billing_api_service.dart` — HTTP timeouts
- `lib/core/services/collaboration_service.dart` — HTTP timeouts
- `lib/core/services/sharing_service.dart` — HTTP timeouts
- `lib/core/services/face_storage_service.dart` — Hive encryption
- `lib/core/services/tag_storage_service.dart` — Hive encryption
- `lib/core/services/website_service.dart` — UUID temp paths
- `lib/core/services/file_service.dart` — reserved-name + invalid-char validation
- `lib/features/sync/providers/upload_progress_provider.dart` — stream listener hardening
- `lib/features/settings/screens/settings_screen.dart` — sign-out confirm + clear-cache impl
- `lib/features/sharing/screens/share_screen.dart` — themed chip + opt-in clipboard
- `lib/features/browser/screens/file_browser_screen.dart` — themed colors + rename validator
- `lib/features/apps/widgets/password_setup_dialog.dart` — show/hide toggle + min length
- `lib/features/search/screens/search_screen.dart` — empty-state query echo
- `lib/main.dart` — startup try/catch
