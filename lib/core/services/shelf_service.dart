import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/models/sync_state.dart' show SyncStatus;
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/shelf_classifier.dart';
import 'package:fula_files/core/services/shelf_enricher.dart';
import 'package:fula_files/core/services/shelf_notification_service.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';
import 'package:fula_files/core/services/shelf_suggestion_dismissals_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';

/// Cloud bucket dedicated to Shelf items (Phase plan: dedicated `dump`
/// bucket, separate from the user's main file bucket).
const String kShelfBucket = 'dump';

/// Cloud bucket holding the encrypted thumbnail JPEGs. Separate from
/// the content bucket so listing/cleanup of either is independent.
const String kShelfThumbsBucket = 'dump-thumbs';

/// Subdirectory under `getApplicationDocumentsDirectory()` where the
/// Android share receiver Activity stages payloads + descriptors and
/// where the main app drains them from. NOT under cacheDir per the
/// plan's "Staging" architectural decision (OS may purge cacheDir
/// between retries).
const String kShelfPendingDir = 'dump_pending';

/// Subdirectory under `getApplicationDocumentsDirectory()` for cached
/// thumbnails. Owned exclusively by the Shelf feature — the local
/// delete path uses a `p.isWithin` containment check against this dir
/// before touching a file referenced by `ShelfItem.thumbnailPath`, so
/// a corrupted row can't direct us to delete arbitrary files.
const String kShelfThumbsDirName = 'dump_thumbs';

/// Hive `settings` key recording that a given bucket has been created, so we
/// skip the `bucketExists`/`createBucket` round-trip on every share. The key is
/// bucket-NAME-specific: flipping v8 routing (legacy `dump` → `dump-v8`) must
/// not let a stale "legacy already created" flag skip creating the fresh v8
/// bucket — that would fail the first PUT with NoSuchBucket (silently, for the
/// fire-and-forget thumbnail upload).
String _bucketInitializedFlag(String bucket) => '${bucket}_bucket_initialized';

const int _kContentShaPrefixBytes = 1024 * 1024; // 1 MB

/// Orchestrates the Shelf pipeline: ingestion from staged payloads,
/// dedup, encrypt+upload via [SyncService], notification fan-out.
///
/// Singleton — same instance is shared by the main isolate and (if
/// later wired) the WorkManager background isolate. `init()` is
/// idempotent.
class ShelfService {
  ShelfService._();
  static final ShelfService instance = ShelfService._();

  final _uuid = const Uuid();

  bool _isInitialized = false;
  bool _bucketEnsured = false;
  bool _thumbsBucketEnsured = false;

  /// In-process drain mutex (R9). When a drain is in flight, concurrent
  /// callers join the same future instead of starting a parallel drain.
  /// File-lock for cross-isolate races is deferred until the WM
  /// background-isolate drain path lands (Plan B keeps drain in the
  /// main isolate only — see plan revision R3).
  Future<void>? _drainInFlight;

  // SyncService listener — translates SyncStatus changes on dump-bucket
  // uploads into ShelfItem.uploadStatus updates and notifications.
  // Bound once in [init]; cleared in [resetForTesting].
  void Function(String localPath, SyncStatus status)? _syncListener;

  Future<void> init() async {
    if (_isInitialized) return;
    await ShelfStorageService.instance.init();
    _bindSyncStatusListener();
    _isInitialized = true;
    // Resume any deletes whose cloud cleanup was interrupted by an
    // app kill / network drop in a previous session. Fire-and-forget —
    // never blocks init.
    unawaited(retryPendingDeletes());
  }

  // ---- Deletion --------------------------------------------------------
  //
  // Two-phase delete (per the design review's data-integrity hardening):
  //
  //   1. Write a tombstone (`ShelfPendingDeleteEntry`) so the UI can
  //      hide the row immediately AND a retry pass on the next session
  //      can finish the cloud cleanup if we're interrupted.
  //   2. Cancel any in-flight upload (`SyncService.cancelTask` — per-
  //      item, NOT bucket-wide; bucket-wide would clobber unrelated
  //      shelf uploads). The cancel handles resumable-manifest abort
  //      internally if a manifest exists.
  //   3. Batch-remove all tag associations under `dump://<id>` via the
  //      existing `removeAllTagsFromFile` (single storage write +
  //      coalesced share-refresh — not N share-refreshes).
  //   4. Clear dismissals.
  //   5. Remove local cache + thumbnail files. The thumbnail path is
  //      checked to be inside our managed dir before deletion (defense
  //      against a corrupted `thumbnailPath` pointing outside the
  //      sandbox).
  //   6. Remove the Hive row. ShelfStorageService.delete drops the id
  //      from the order list and schedules a debounced cloud-manifest
  //      sync — the next manifest no longer carries the deleted item.
  //   7. Attempt cloud blob + thumb delete. If any fails, the
  //      tombstone is retained and the retry pass on next init / sync
  //      will rerun the deletes.
  //
  // The orchestration order is deliberate: tombstone FIRST so the row
  // is hidden before any work begins; Hive removal LATE so the row
  // survives a partial-failure mid-operation (the retry pass uses the
  // tombstone, not the Hive row). Cloud cleanup is LAST so a network
  // failure doesn't block local UX.

  /// Remove [item] from the Shelf. Local effects are immediate (item
  /// disappears from the grid); cloud cleanup is best-effort with
  /// automatic retry on the next session if it fails today.
  ///
  /// Idempotent — calling twice with the same item is harmless:
  /// already-deleted local rows + files no-op; already-deleted cloud
  /// blobs surface as `NoSuchKey` which we treat as success.
  Future<void> deleteItem(ShelfItem item) async {
    debugPrint('ShelfService.deleteItem(${item.id}): start');

    await ShelfStorageService.instance.markPendingDelete(
      ShelfPendingDeleteEntry(
        itemId: item.id,
        markedAt: DateTime.now(),
        remoteKey: item.remoteKey,
        thumbnailRemoteKey: item.thumbnailRemoteKey,
        sourceBucket: item.sourceBucket,
        // resumableManifestPath is owned by SyncService; cancelTask
        // looks it up internally so we don't need to capture it here.
        resumableManifestPath: null,
      ),
    );

    if (item.localCachePath.isNotEmpty) {
      try {
        await SyncService.instance.cancelTask(item.localCachePath);
      } catch (e) {
        debugPrint('ShelfService.deleteItem(${item.id}): cancelTask: $e');
      }
    }

    try {
      await TagStorageService.instance.removeAllTagsFromFile(
        localPath: 'dump://${item.id}',
      );
    } catch (e) {
      debugPrint('ShelfService.deleteItem(${item.id}): tag cleanup: $e');
    }

    try {
      await ShelfSuggestionDismissalsService.instance.clearAll(item.id);
    } catch (e) {
      debugPrint('ShelfService.deleteItem(${item.id}): dismissal clear: $e');
    }

    await _removeLocalFiles(item);

    await ShelfStorageService.instance.delete(item.id);

    // Push the deletion into the cloud manifest BEFORE the tombstone is
    // cleared (which happens after cloud cleanup just below). The
    // merge-before-write guard on a future sync folds back in any cloud
    // item this device lacks; if the cloud manifest still listed this
    // just-deleted item after its tombstone cleared, that merge would
    // RESURRECT it. flushNow() runs a sync that reflects the removal while
    // the tombstone is still present (so the merge skips it), leaving the
    // cloud manifest without the item. Non-fatal — _doSyncNow swallows its
    // own errors, and a failed push leaves cloud cleanup below to retain
    // the tombstone for a later retry.
    await ShelfStorageService.instance.flushNow();

    final cloudCleanupOk = await _attemptCloudCleanup(
      remoteKey: item.remoteKey,
      thumbnailRemoteKey: item.thumbnailRemoteKey,
      sourceBucket: item.sourceBucket,
    );
    if (cloudCleanupOk) {
      await ShelfStorageService.instance.clearPendingDelete(item.id);
      debugPrint('ShelfService.deleteItem(${item.id}): complete');
    } else {
      debugPrint(
        'ShelfService.deleteItem(${item.id}): cloud cleanup incomplete; '
        'tombstone retained for retry',
      );
    }
  }

  /// Resume any deletes whose cloud cleanup didn't finish in a prior
  /// session. Walks the pending-deletes box and re-attempts the cloud
  /// blob + thumb deletes. Removes the tombstone on success.
  ///
  /// Fired from `init()` and after each successful manifest sync. Safe
  /// to call concurrently — each id is processed independently and
  /// `FulaApiService.deleteObject` is idempotent.
  Future<void> retryPendingDeletes() async {
    if (!ShelfStorageService.instance.isInitialized) return;
    if (!FulaApiService.instance.isConfigured) return;

    final ids = ShelfStorageService.instance.getPendingDeleteIds();
    if (ids.isEmpty) return;

    debugPrint('ShelfService.retryPendingDeletes: ${ids.length} tombstone(s)');
    for (final id in ids) {
      final entry = ShelfStorageService.instance.getPendingDelete(id);
      if (entry == null) {
        // Corrupted box entry — drop it to avoid an infinite loop.
        await ShelfStorageService.instance.clearPendingDelete(id);
        continue;
      }
      final ok = await _attemptCloudCleanup(
        remoteKey: entry.remoteKey,
        thumbnailRemoteKey: entry.thumbnailRemoteKey,
        sourceBucket: entry.sourceBucket,
      );
      if (ok) {
        await ShelfStorageService.instance.clearPendingDelete(id);
      }
    }
  }

  /// Returns true iff every non-null cloud key was successfully removed
  /// (or was already absent — `NoSuchKey` counts as success). On any
  /// other failure the caller retains the tombstone for retry.
  Future<bool> _attemptCloudCleanup({
    required String? remoteKey,
    required String? thumbnailRemoteKey,
    required String? sourceBucket,
  }) async {
    var ok = true;
    if (remoteKey != null && remoteKey.isNotEmpty) {
      // Body: its recorded home (`dump` / `dump-v8`), else current routing. A
      // v8 item deletes from its v8 bucket; a legacy item's v8-delete is a
      // NoSuchKey no-op AND its legacy copy stays preserved (P4 policy: legacy
      // objects are kept so existing share links keep working).
      final bodyBucket =
          sourceBucket ?? BucketVersionResolver.writeBucket(kShelfBucket);
      ok = await _deleteCloudObjectIdempotent(bodyBucket, remoteKey) && ok;
    }
    if (thumbnailRemoteKey != null && thumbnailRemoteKey.isNotEmpty) {
      ok = await _deleteCloudObjectIdempotent(
            _thumbBucketFor(sourceBucket),
            thumbnailRemoteKey,
          ) &&
          ok;
    }
    return ok;
  }

  /// The thumbnail bucket matching a body's [sourceBucket] version. Body and
  /// thumbnail are written in the same v8-flag state, so the body's recorded
  /// bucket tells us where the thumb went: a v8 body ⇒ the `dump-thumbs-v8`
  /// sibling; otherwise current routing (legacy when the flag is off). Keeps
  /// thumb delete correct even after a v8-flag rollback.
  String _thumbBucketFor(String? sourceBucket) {
    if (sourceBucket != null && BucketVersionResolver.isV8(sourceBucket)) {
      return '$kShelfThumbsBucket-${BucketVersionResolver.versionSuffix}';
    }
    return BucketVersionResolver.writeBucket(kShelfThumbsBucket);
  }

  /// Buckets to try (in order) when re-fetching a thumbnail: the item's
  /// version bucket, plus — while v8 is enabled — the sibling, so a thumb in
  /// either survives mixed legacy/v8 history. Flag off ⇒ the single legacy
  /// bucket only (no wasted v8 request, preserving flag-off parity).
  List<String> _thumbReadBuckets(String? sourceBucket) {
    final primary = _thumbBucketFor(sourceBucket);
    if (!BucketVersionResolver.enabled) return <String>[primary];
    final v8 = '$kShelfThumbsBucket-${BucketVersionResolver.versionSuffix}';
    final sibling = primary == v8 ? kShelfThumbsBucket : v8;
    return <String>[primary, sibling];
  }

  Future<bool> _deleteCloudObjectIdempotent(String bucket, String key) async {
    try {
      await FulaApiService.instance.deleteObject(bucket, key);
      return true;
    } catch (e) {
      final s = e.toString();
      // Already gone → idempotent success. The server-side delete
      // either ran on a previous attempt (and our manifest just didn't
      // catch up) or the upload never landed.
      if (s.contains('NoSuchKey') ||
          s.contains('Not Found') ||
          s.contains('not found') ||
          s.contains('404')) {
        return true;
      }
      debugPrint(
        'ShelfService._deleteCloudObjectIdempotent($bucket/$key): $e',
      );
      return false;
    }
  }

  Future<void> _removeLocalFiles(ShelfItem item) async {
    if (item.localCachePath.isNotEmpty) {
      try {
        final f = File(item.localCachePath);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('ShelfService._removeLocalFiles cache(${item.id}): $e');
      }
    }
    final thumb = item.thumbnailPath;
    if (thumb != null && thumb.isNotEmpty) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        final managedDir =
            p.canonicalize(p.join(docs.path, kShelfThumbsDirName));
        final canonicalThumb = p.canonicalize(thumb);
        if (p.isWithin(managedDir, canonicalThumb)) {
          final f = File(thumb);
          if (await f.exists()) await f.delete();
        } else {
          debugPrint(
            'ShelfService._removeLocalFiles: refusing to delete '
            'thumbnail outside managed dir ($managedDir): $thumb',
          );
        }
      } catch (e) {
        debugPrint('ShelfService._removeLocalFiles thumb(${item.id}): $e');
      }
    }
  }

  // ---- Ingestion -------------------------------------------------------

  /// Ingest a batch of staged payloads — either from the Android share
  /// receiver's descriptor JSON, or from the in-app add flows (Session
  /// 3b). For each file:
  ///   1. Compute candidate `contentSha = sha256(first 1 MB + size)`.
  ///   2. Dedup via [ShelfStorageService.findDuplicate] (handles R8
  ///      collision-prone candidate + full-hash verify for ≤ 50 MB).
  ///   3. Classify via [ShelfClassifier].
  ///   4. Write a [ShelfItem] row with the right initial status
  ///      (`queued` if encryption key is available, else
  ///      `pendingAuth` per R10).
  ///
  /// Does NOT auto-schedule uploads — the caller (drain / manual add
  /// flow) decides when to fire [uploadOne] for each returned item.
  /// Keeps the surface testable without mocking [SyncService].
  ///
  /// Returns the items that were newly created (excludes duplicates).
  Future<List<ShelfItem>> ingestStagedPayload({
    required List<String> cachedPaths,
    required List<String?> mimeTypes,
    required List<String> originalNames,
    String? textPayload,
    String? sourcePackage,
  }) async {
    if (!_isInitialized) await init();
    final out = <ShelfItem>[];
    final hasKey = await _canEncryptNow();

    for (var i = 0; i < cachedPaths.length; i++) {
      final path = cachedPaths[i];
      final mime = i < mimeTypes.length ? mimeTypes[i] : null;
      final name = i < originalNames.length
          ? originalNames[i]
          : p.basename(path);
      final file = File(path);
      if (!await file.exists()) {
        debugPrint('ShelfService.ingestStagedPayload: missing $path');
        continue;
      }
      final sizeBytes = await file.length();
      final contentSha = await _computeContentSha(file, sizeBytes);

      final existing = await ShelfStorageService.instance.findDuplicate(
        contentSha: contentSha,
        sizeBytes: sizeBytes,
        sourceFilePath: path,
      );
      if (existing != null) {
        debugPrint(
            'ShelfService.ingestStagedPayload: duplicate of ${existing.id} '
            'skipped (path=$path)');
        continue;
      }

      final category = ShelfClassifier.classify(
        mimeType: mime,
        filename: name,
        textPayload: textPayload,
      );

      final initialStatus =
          hasKey ? ShelfUploadStatus.queued : ShelfUploadStatus.pendingAuth;

      final item = ShelfItem(
        id: _uuid.v4(),
        receivedAt: DateTime.now(),
        originalName: name,
        mimeType: mime,
        sizeBytes: sizeBytes,
        localCachePath: path,
        category: category,
        uploadStatus: initialStatus,
        sourceAppPackage: sourcePackage,
        textPayload: textPayload,
        contentSha: contentSha,
      );
      await ShelfStorageService.instance.add(item);
      out.add(item);
    }

    return out;
  }

  /// Convenience: ingest + immediately schedule uploads for any newly-
  /// created items whose status is `queued`. `pendingAuth` items are
  /// left untouched until [retryPending] picks them up.
  ///
  /// This is what `drainPendingDir` and the Session 3b manual-add
  /// flows use. Tests of [ingestStagedPayload] don't touch this
  /// method.
  Future<List<ShelfItem>> ingestAndSchedule({
    required List<String> cachedPaths,
    required List<String?> mimeTypes,
    required List<String> originalNames,
    String? textPayload,
    String? sourcePackage,
  }) async {
    final items = await ingestStagedPayload(
      cachedPaths: cachedPaths,
      mimeTypes: mimeTypes,
      originalNames: originalNames,
      textPayload: textPayload,
      sourcePackage: sourcePackage,
    );
    // When the whole batch dedup'd against existing rows (R8 — same
    // contentSha + size + full-hash verify for files ≤ 50 MB), `items`
    // is empty even though `cachedPaths` had real files. Without
    // surfacing this, the Kotlin "Processing N dump(s)…" notification
    // hangs indefinitely (showComplete/showFailed only fire for new
    // items). Replace it with a clear "Already in Shelf" update that
    // reuses the same notification id so the OS swaps in-place.
    if (items.isEmpty) {
      if (cachedPaths.isNotEmpty) {
        await ShelfNotificationService.instance
            .showDuplicate(count: cachedPaths.length);
      }
      return items;
    }
    final hasKey = await _canEncryptNow();
    if (hasKey) {
      await ShelfNotificationService.instance.showReceived(count: items.length);
      for (final i in items) {
        unawaited(uploadOne(i));
      }
    } else {
      await ShelfNotificationService.instance
          .showPendingAuth(count: items.length);
    }
    // Enrichment is independent of upload state — run for every new
    // item so tiles get title/description/thumb even when offline.
    for (final i in items) {
      unawaited(scheduleEnrichment(i));
    }
    return items;
  }

  // ---- Upload ----------------------------------------------------------

  /// Schedule the encrypted upload of a single [ShelfItem] through the
  /// existing [SyncService] pipeline. Status moves
  /// `queued → uploading` immediately, and `uploading → uploaded` or
  /// `uploading → failed` later via the SyncService status listener
  /// bound in [init].
  ///
  /// If the encryption key isn't currently readable (signed out or
  /// device locked — R10), the item is left as `pendingAuth` and
  /// [retryPending] picks it up after session restore.
  Future<void> uploadOne(ShelfItem item) async {
    if (!await _canEncryptNow()) {
      await ShelfStorageService.instance.updateStatus(
        item.id,
        ShelfUploadStatus.pendingAuth,
      );
      return;
    }
    try {
      await ensureShelfBucket();
    } catch (e) {
      debugPrint('ShelfService.ensureShelfBucket failed: $e');
      await ShelfStorageService.instance.updateStatus(
        item.id,
        ShelfUploadStatus.failed,
        errorMessage: 'Bucket unavailable: $e',
      );
      return;
    }
    final remoteKey = _remoteKeyFor(item);
    // The bucket the body will actually land in. `queueUpload` routes the
    // bucket internally (its v8 chokepoint), so this mirrors what it will do —
    // recorded on the item so delete / future cloud-download target the right
    // bucket even if the v8 flag is toggled later.
    final bodyBucket = BucketVersionResolver.writeBucket(kShelfBucket);
    await ShelfStorageService.instance.updateStatus(
      item.id,
      ShelfUploadStatus.uploading,
      remoteKey: remoteKey,
      sourceBucket: bodyBucket,
    );
    try {
      await SyncService.instance.queueUpload(
        localPath: item.localCachePath,
        remoteBucket: kShelfBucket,
        remoteKey: remoteKey,
        encrypt: true,
      );
    } catch (e) {
      await ShelfStorageService.instance.updateStatus(
        item.id,
        ShelfUploadStatus.failed,
        errorMessage: e.toString(),
      );
    }
  }

  /// Kick off main-isolate enrichment for [item] (R2). Fire-and-forget
  /// — never throws, never blocks the caller. On success writes the
  /// auto-title / auto-description / thumbnail / labels back to the
  /// item via [ShelfStorageService.updateEnrichment]. On failure the
  /// row is left with `enrichmentStatus = failed` and the UI falls
  /// back to filename + size.
  ///
  /// Idempotent — re-running enrich on the same item just overwrites
  /// the previous result.
  Future<void> scheduleEnrichment(ShelfItem item) async {
    try {
      final result = await ShelfEnricher.instance.enrich(item);
      await ShelfStorageService.instance.updateEnrichment(
        item.id,
        title: result.title,
        description: result.description,
        thumbnailPath: result.thumbnailPath,
        mlLabels: result.mlLabels.isNotEmpty ? result.mlLabels : null,
        status: result.status,
      );
      // Persist the thumbnail to cloud so it survives a reinstall.
      // Fire-and-forget — the local thumbnail is already on disk and
      // the tile renders from it immediately; cloud upload is the
      // safety net for the next device.
      if (result.thumbnailPath != null) {
        unawaited(_uploadThumbnailToCloud(item.id, result.thumbnailPath!));
      }
    } catch (e) {
      debugPrint('ShelfService.scheduleEnrichment(${item.id}) failed: $e');
      try {
        await ShelfStorageService.instance.updateEnrichment(
          item.id,
          status: ShelfEnrichmentStatus.failed,
        );
      } catch (_) {
        // Last-ditch — never propagate.
      }
    }
  }

  /// Reads the local thumbnail JPEG, encrypts and uploads it to the
  /// `dump-thumbs` bucket, then records the remote key on the
  /// ShelfItem so `restoreFromCloud` can rehydrate it on a fresh
  /// device. Non-fatal; failure leaves `thumbnailRemoteKey` null and
  /// the tile keeps using the local file.
  Future<void> _uploadThumbnailToCloud(
    String dumpItemId,
    String localPath,
  ) async {
    try {
      if (!FulaApiService.instance.isConfigured) return;
      final key = await AuthService.instance.getEncryptionKey();
      if (key == null) return;
      final file = File(localPath);
      if (!await file.exists()) return;
      // Must happen BEFORE encryptAndUpload — without it, the very
      // first thumbnail upload on a fresh account hits NoSuchBucket
      // and the row is left with `thumbnailRemoteKey = null` forever.
      if (!await ensureShelfThumbsBucket()) {
        debugPrint(
            'ShelfService._uploadThumbnailToCloud($dumpItemId): '
            'dump-thumbs bucket unavailable — skipping');
        return;
      }
      final bytes = await file.readAsBytes();
      final now = DateTime.now();
      final yyyy = now.year.toString().padLeft(4, '0');
      final mm = now.month.toString().padLeft(2, '0');
      final remoteKey = '$yyyy/$mm/$dumpItemId.jpg';
      // Route to the v8 thumbs bucket when the migration is enabled — the
      // legacy `dump-thumbs` forest is gc-damaged and rejects writes. Unlike
      // the body (which funnels through SyncService.queueUpload's v8
      // chokepoint), this is a direct PUT, so it must wrap writeBucket itself.
      await FulaApiService.instance.encryptAndUpload(
        BucketVersionResolver.writeBucket(kShelfThumbsBucket),
        remoteKey,
        bytes,
        key,
        contentType: 'image/jpeg',
      );
      await ShelfStorageService.instance
          .updateThumbnailRemoteKey(dumpItemId, remoteKey);
    } catch (e) {
      debugPrint(
          'ShelfService._uploadThumbnailToCloud($dumpItemId): $e');
    }
  }

  // Lazy-fetch dedup — one in-flight download per item id at a time
  // so a scrolling grid doesn't fire 100 simultaneous fetches.
  final Set<String> _thumbnailFetchInFlight = <String>{};

  /// Best-effort lazy fetch of a missing local thumbnail. Called from
  /// the grid tile when `thumbnailPath` is null or its file is gone
  /// but `thumbnailRemoteKey` is set (typical state right after a
  /// `restoreFromCloud` on a fresh device). Idempotent + dedup'd —
  /// safe to call from every tile build. Updates
  /// `ShelfItem.thumbnailPath` on success which triggers the Hive
  /// watch stream and re-renders the tile.
  Future<void> ensureLocalThumbnail(ShelfItem item) async {
    final remoteKey = item.thumbnailRemoteKey;
    if (remoteKey == null || remoteKey.isEmpty) return;
    if (item.thumbnailPath != null) {
      try {
        if (await File(item.thumbnailPath!).exists()) return;
      } catch (_) {/* fallthrough to re-fetch */}
    }
    if (_thumbnailFetchInFlight.contains(item.id)) return;
    _thumbnailFetchInFlight.add(item.id);
    try {
      if (!FulaApiService.instance.isConfigured) return;
      final key = await AuthService.instance.getEncryptionKey();
      if (key == null) return;
      // The thumb lives in the same version-family as the body. Try that
      // bucket first; when v8 is enabled also try the sibling so a thumb in
      // either bucket (mixed legacy/v8 history) still rehydrates.
      Uint8List? bytes;
      for (final bucket in _thumbReadBuckets(item.sourceBucket)) {
        try {
          bytes = await FulaApiService.instance
              .downloadAndDecrypt(bucket, remoteKey, key);
          break;
        } catch (e) {
          debugPrint('ShelfService.ensureLocalThumbnail(${item.id}): '
              '$bucket miss: $e');
        }
      }
      if (bytes == null) return;
      final docs = await getApplicationDocumentsDirectory();
      final thumbsDir = Directory(p.join(docs.path, 'dump_thumbs'));
      if (!await thumbsDir.exists()) {
        await thumbsDir.create(recursive: true);
      }
      final dest = File(p.join(thumbsDir.path, '${item.id}.jpg'));
      await dest.writeAsBytes(bytes, flush: true);
      await ShelfStorageService.instance
          .updateThumbnailLocalPath(item.id, dest.path);
    } catch (e) {
      debugPrint(
          'ShelfService.ensureLocalThumbnail(${item.id}): $e');
    } finally {
      _thumbnailFetchInFlight.remove(item.id);
    }
  }

  /// Re-queue items left in [ShelfUploadStatus.pendingAuth] — called
  /// from the auth-restore hook in Session 5 once the user signs back
  /// in.
  Future<int> retryPending() async {
    if (!_isInitialized) await init();
    if (!await _canEncryptNow()) return 0;
    final pending = ShelfStorageService.instance.getPendingAuthItems();
    for (final item in pending) {
      await ShelfStorageService.instance.updateStatus(
        item.id,
        ShelfUploadStatus.queued,
      );
      unawaited(uploadOne(item));
    }
    return pending.length;
  }

  // ---- Drain (Plan B: main app reads dump_pending/ on resume) ---------

  /// Scan the staging directory for descriptor JSONs left behind by
  /// `ShelfShareActivity`, ingest each batch, and delete the descriptor
  /// on success. Idempotent — concurrent callers join the in-flight
  /// future (R9 in-process mutex).
  Future<int> drainPendingDir() async {
    if (_drainInFlight != null) {
      await _drainInFlight!;
      return 0; // ours yielded to the in-flight drain
    }
    final completer = Completer<int>();
    _drainInFlight = completer.future;
    var ingested = 0;
    try {
      final pendingDir = await _pendingDirectory();
      if (!await pendingDir.exists()) {
        completer.complete(0);
        return 0;
      }
      await for (final entity in pendingDir.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.json')) continue;
        try {
          ingested += await _drainOneDescriptor(entity, pendingDir);
        } catch (e) {
          debugPrint('ShelfService.drain: ${entity.path} failed: $e');
        }
      }
      // Sweep stray payload files whose descriptors were never seen.
      await ShelfStorageService.instance.garbageCollectOrphans(pendingDir);
      completer.complete(ingested);
      return ingested;
    } catch (e) {
      completer.complete(ingested);
      rethrow;
    } finally {
      _drainInFlight = null;
    }
  }

  Future<int> _drainOneDescriptor(File descriptor, Directory dir) async {
    final raw = await descriptor.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final items = (json['items'] as List?) ?? const [];
    if (items.isEmpty) {
      await descriptor.delete();
      return 0;
    }
    final cachedPaths = <String>[];
    final mimeTypes = <String?>[];
    final originalNames = <String>[];
    var missingPayloads = false;
    for (final raw in items) {
      final item = raw as Map<String, dynamic>;
      final relativeFile = item['localFile'] as String?;
      if (relativeFile == null) {
        missingPayloads = true;
        break;
      }
      final absolute = p.join(dir.path, relativeFile);
      if (!await File(absolute).exists()) {
        missingPayloads = true;
        break;
      }
      cachedPaths.add(absolute);
      mimeTypes.add(item['mimeType'] as String?);
      originalNames.add(
        (item['originalName'] as String?) ?? p.basename(absolute),
      );
    }
    if (missingPayloads) {
      // Receiver crashed mid-write — leave the descriptor for the next
      // pass (it may complete) or for orphan GC to sweep eventually.
      return 0;
    }
    final created = await ingestAndSchedule(
      cachedPaths: cachedPaths,
      mimeTypes: mimeTypes,
      originalNames: originalNames,
      textPayload: json['textPayload'] as String?,
      sourcePackage: json['sourcePackage'] as String?,
    );
    await descriptor.delete();
    return created.length;
  }

  // ---- Bucket ---------------------------------------------------------

  /// Ensure the dedicated `dump` bucket exists. Gated by a Hive flag
  /// (`dump_bucket_initialized`) so we don't hit `listBuckets` on
  /// every share. Idempotent — `createBucket` tolerates
  /// already-exists.
  Future<void> ensureShelfBucket() async {
    if (_bucketEnsured) return;
    // Route to the v8 sibling when enabled — the legacy `dump` forest is
    // gc-damaged. (Bodies also get a net from SyncService._ensureBucketExists
    // at upload, but ensuring here keeps a fresh account consistent.)
    final bucket = BucketVersionResolver.writeBucket(kShelfBucket);
    final flagKey = _bucketInitializedFlag(bucket);
    final flag =
        LocalStorageService.instance.getSetting<bool>(flagKey) ?? false;
    if (flag) {
      _bucketEnsured = true;
      return;
    }
    try {
      final exists = await FulaApiService.instance.bucketExists(bucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(bucket);
      }
      await LocalStorageService.instance.saveSetting(flagKey, true);
      _bucketEnsured = true;
    } catch (e) {
      // `createBucket` swallows "already exists" — anything else here
      // is genuinely transient (network / auth) and we'll retry on
      // the next call.
      debugPrint('ShelfService.ensureShelfBucket non-fatal failure: $e');
    }
  }

  /// Same as [ensureShelfBucket] but for the `dump-thumbs` bucket.
  /// Called from `_uploadThumbnailToCloud` AND `ensureLocalThumbnail`
  /// — without this the first thumbnail upload on a fresh account
  /// fails with `NoSuchBucket: dump-thumbs` (visible in user logs).
  Future<bool> ensureShelfThumbsBucket() async {
    if (_thumbsBucketEnsured) return true;
    // Route to the v8 sibling when enabled. The thumbnail upload is a direct
    // fire-and-forget PUT with no SyncService net, so if this skipped creating
    // `dump-thumbs-v8` the first PUT would NoSuchBucket and silently leave
    // `thumbnailRemoteKey` null — hence the bucket-name-specific flag key.
    final bucket = BucketVersionResolver.writeBucket(kShelfThumbsBucket);
    final flagKey = _bucketInitializedFlag(bucket);
    final flag =
        LocalStorageService.instance.getSetting<bool>(flagKey) ?? false;
    if (flag) {
      _thumbsBucketEnsured = true;
      return true;
    }
    try {
      final exists = await FulaApiService.instance.bucketExists(bucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(bucket);
      }
      await LocalStorageService.instance.saveSetting(flagKey, true);
      _thumbsBucketEnsured = true;
      return true;
    } catch (e) {
      final s = e.toString();
      if (s.contains('BucketAlreadyExists') ||
          s.contains('BucketAlreadyOwnedByYou') ||
          s.contains('bucket already exists')) {
        _thumbsBucketEnsured = true;
        await LocalStorageService.instance.saveSetting(flagKey, true);
        return true;
      }
      debugPrint('ShelfService.ensureShelfThumbsBucket non-fatal: $e');
      return false;
    }
  }

  // ---- Internals ------------------------------------------------------

  Future<Directory> _pendingDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, kShelfPendingDir));
  }

  String _remoteKeyFor(ShelfItem item) {
    final now = item.receivedAt.toUtc();
    final year = now.year.toString().padLeft(4, '0');
    final month = now.month.toString().padLeft(2, '0');
    final safeName = _sanitizeName(item.originalName);
    return '$year/$month/${item.id}-$safeName';
  }

  String _sanitizeName(String name) {
    // Replace anything outside [A-Za-z0-9._-] with '_'. Keeps cloud
    // keys safe across S3-flavoured stores.
    final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return sanitized.isEmpty ? 'file' : sanitized;
  }

  /// Test seam: tests assign this to control the encryption-key
  /// availability path (R10) without spinning up the full
  /// [AuthService] / `flutter_secure_storage` stack.
  @visibleForTesting
  Future<Uint8List?> Function() encryptionKeyProvider =
      () => AuthService.instance.getEncryptionKey();

  Future<bool> _canEncryptNow() async {
    try {
      final key = await encryptionKeyProvider();
      return key != null && key.isNotEmpty;
    } catch (e) {
      // Treat keychain-locked / not-initialized as "can't encrypt now".
      debugPrint('ShelfService._canEncryptNow: $e');
      return false;
    }
  }

  Future<String> _computeContentSha(File file, int sizeBytes) async {
    final prefixLen = sizeBytes < _kContentShaPrefixBytes
        ? sizeBytes
        : _kContentShaPrefixBytes;
    final raf = await file.open(mode: FileMode.read);
    try {
      final prefix = await raf.read(prefixLen);
      final suffix = utf8.encode(':$sizeBytes');
      final combined = Uint8List(prefix.length + suffix.length);
      combined.setRange(0, prefix.length, prefix);
      combined.setRange(prefix.length, combined.length, suffix);
      return sha256.convert(combined).toString();
    } finally {
      await raf.close();
    }
  }

  void _bindSyncStatusListener() {
    _syncListener ??= (localPath, status) {
      // Find the dump item (if any) whose localCachePath matches. We
      // don't keep an index by path; the dump box is typically small,
      // so a linear scan is fine.
      final items = ShelfStorageService.instance.getAll();
      ShelfItem? match;
      for (final i in items) {
        if (p.canonicalize(i.localCachePath) == p.canonicalize(localPath)) {
          match = i;
          break;
        }
      }
      if (match == null) return;
      switch (status) {
        case SyncStatus.syncing:
          unawaited(ShelfStorageService.instance.updateStatus(
            match.id, ShelfUploadStatus.uploading,
          ));
          break;
        case SyncStatus.synced:
          unawaited(_onUploadSucceeded(match));
          break;
        case SyncStatus.error:
          unawaited(ShelfStorageService.instance.updateStatus(
            match.id, ShelfUploadStatus.failed,
            errorMessage: 'Upload failed',
          ));
          unawaited(ShelfNotificationService.instance.showFailed(item: match));
          break;
        case SyncStatus.notSynced:
          // No-op — handled by other transitions.
          break;
      }
    };
    SyncService.instance.addListener(_syncListener!);
  }

  Future<void> _onUploadSucceeded(ShelfItem item) async {
    await ShelfStorageService.instance.updateStatus(
      item.id, ShelfUploadStatus.uploaded,
    );
    final fresh = ShelfStorageService.instance.getById(item.id) ?? item;
    await ShelfNotificationService.instance
        .showComplete(items: <ShelfItem>[fresh]);
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    if (_syncListener != null) {
      SyncService.instance.removeListener(_syncListener!);
      _syncListener = null;
    }
    _isInitialized = false;
    _bucketEnsured = false;
    _thumbsBucketEnsured = false;
    _drainInFlight = null;
    encryptionKeyProvider = () => AuthService.instance.getEncryptionKey();
  }

  /// Test-only init that wires the storage layer but skips
  /// [_bindSyncStatusListener] (which would otherwise pull
  /// [SyncService] + the encryption stack into the test isolate).
  @visibleForTesting
  Future<void> initForTesting() async {
    await ShelfStorageService.instance.init();
    _isInitialized = true;
  }
}
