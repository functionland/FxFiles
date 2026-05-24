import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/models/sync_state.dart' show SyncStatus;
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/dump_classifier.dart';
import 'package:fula_files/core/services/dump_enricher.dart';
import 'package:fula_files/core/services/dump_notification_service.dart';
import 'package:fula_files/core/services/dump_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/sync_service.dart';

/// Cloud bucket dedicated to Dump items (Phase plan: dedicated `dump`
/// bucket, separate from the user's main file bucket).
const String kDumpBucket = 'dump';

/// Cloud bucket holding the encrypted thumbnail JPEGs. Separate from
/// the content bucket so listing/cleanup of either is independent.
const String kDumpThumbsBucket = 'dump-thumbs';

/// Subdirectory under `getApplicationDocumentsDirectory()` where the
/// Android share receiver Activity stages payloads + descriptors and
/// where the main app drains them from. NOT under cacheDir per the
/// plan's "Staging" architectural decision (OS may purge cacheDir
/// between retries).
const String kDumpPendingDir = 'dump_pending';

/// Hive flag inside the `settings` box that records whether the dump
/// bucket has been created (so we don't pay the network round-trip
/// on every share).
const String _kDumpBucketInitializedFlag = 'dump_bucket_initialized';

/// Same flag, for the `dump-thumbs` bucket — without it, every
/// post-enrichment thumbnail upload hits NoSuchBucket on a fresh
/// account (confirmed in user logs after a clean reset).
const String _kDumpThumbsBucketInitializedFlag =
    'dump_thumbs_bucket_initialized';

const int _kContentShaPrefixBytes = 1024 * 1024; // 1 MB

/// Orchestrates the Dump pipeline: ingestion from staged payloads,
/// dedup, encrypt+upload via [SyncService], notification fan-out.
///
/// Singleton — same instance is shared by the main isolate and (if
/// later wired) the WorkManager background isolate. `init()` is
/// idempotent.
class DumpService {
  DumpService._();
  static final DumpService instance = DumpService._();

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
  // uploads into DumpItem.uploadStatus updates and notifications.
  // Bound once in [init]; cleared in [resetForTesting].
  void Function(String localPath, SyncStatus status)? _syncListener;

  Future<void> init() async {
    if (_isInitialized) return;
    await DumpStorageService.instance.init();
    _bindSyncStatusListener();
    _isInitialized = true;
  }

  // ---- Ingestion -------------------------------------------------------

  /// Ingest a batch of staged payloads — either from the Android share
  /// receiver's descriptor JSON, or from the in-app add flows (Session
  /// 3b). For each file:
  ///   1. Compute candidate `contentSha = sha256(first 1 MB + size)`.
  ///   2. Dedup via [DumpStorageService.findDuplicate] (handles R8
  ///      collision-prone candidate + full-hash verify for ≤ 50 MB).
  ///   3. Classify via [DumpClassifier].
  ///   4. Write a [DumpItem] row with the right initial status
  ///      (`queued` if encryption key is available, else
  ///      `pendingAuth` per R10).
  ///
  /// Does NOT auto-schedule uploads — the caller (drain / manual add
  /// flow) decides when to fire [uploadOne] for each returned item.
  /// Keeps the surface testable without mocking [SyncService].
  ///
  /// Returns the items that were newly created (excludes duplicates).
  Future<List<DumpItem>> ingestStagedPayload({
    required List<String> cachedPaths,
    required List<String?> mimeTypes,
    required List<String> originalNames,
    String? textPayload,
    String? sourcePackage,
  }) async {
    if (!_isInitialized) await init();
    final out = <DumpItem>[];
    final hasKey = await _canEncryptNow();

    for (var i = 0; i < cachedPaths.length; i++) {
      final path = cachedPaths[i];
      final mime = i < mimeTypes.length ? mimeTypes[i] : null;
      final name = i < originalNames.length
          ? originalNames[i]
          : p.basename(path);
      final file = File(path);
      if (!await file.exists()) {
        debugPrint('DumpService.ingestStagedPayload: missing $path');
        continue;
      }
      final sizeBytes = await file.length();
      final contentSha = await _computeContentSha(file, sizeBytes);

      final existing = await DumpStorageService.instance.findDuplicate(
        contentSha: contentSha,
        sizeBytes: sizeBytes,
        sourceFilePath: path,
      );
      if (existing != null) {
        debugPrint(
            'DumpService.ingestStagedPayload: duplicate of ${existing.id} '
            'skipped (path=$path)');
        continue;
      }

      final category = DumpClassifier.classify(
        mimeType: mime,
        filename: name,
        textPayload: textPayload,
      );

      final initialStatus =
          hasKey ? DumpUploadStatus.queued : DumpUploadStatus.pendingAuth;

      final item = DumpItem(
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
      await DumpStorageService.instance.add(item);
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
  Future<List<DumpItem>> ingestAndSchedule({
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
    // items). Replace it with a clear "Already in Dump" update that
    // reuses the same notification id so the OS swaps in-place.
    if (items.isEmpty) {
      if (cachedPaths.isNotEmpty) {
        await DumpNotificationService.instance
            .showDuplicate(count: cachedPaths.length);
      }
      return items;
    }
    final hasKey = await _canEncryptNow();
    if (hasKey) {
      await DumpNotificationService.instance.showReceived(count: items.length);
      for (final i in items) {
        unawaited(uploadOne(i));
      }
    } else {
      await DumpNotificationService.instance
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

  /// Schedule the encrypted upload of a single [DumpItem] through the
  /// existing [SyncService] pipeline. Status moves
  /// `queued → uploading` immediately, and `uploading → uploaded` or
  /// `uploading → failed` later via the SyncService status listener
  /// bound in [init].
  ///
  /// If the encryption key isn't currently readable (signed out or
  /// device locked — R10), the item is left as `pendingAuth` and
  /// [retryPending] picks it up after session restore.
  Future<void> uploadOne(DumpItem item) async {
    if (!await _canEncryptNow()) {
      await DumpStorageService.instance.updateStatus(
        item.id,
        DumpUploadStatus.pendingAuth,
      );
      return;
    }
    try {
      await ensureDumpBucket();
    } catch (e) {
      debugPrint('DumpService.ensureDumpBucket failed: $e');
      await DumpStorageService.instance.updateStatus(
        item.id,
        DumpUploadStatus.failed,
        errorMessage: 'Bucket unavailable: $e',
      );
      return;
    }
    final remoteKey = _remoteKeyFor(item);
    await DumpStorageService.instance.updateStatus(
      item.id,
      DumpUploadStatus.uploading,
      remoteKey: remoteKey,
    );
    try {
      await SyncService.instance.queueUpload(
        localPath: item.localCachePath,
        remoteBucket: kDumpBucket,
        remoteKey: remoteKey,
        encrypt: true,
      );
    } catch (e) {
      await DumpStorageService.instance.updateStatus(
        item.id,
        DumpUploadStatus.failed,
        errorMessage: e.toString(),
      );
    }
  }

  /// Kick off main-isolate enrichment for [item] (R2). Fire-and-forget
  /// — never throws, never blocks the caller. On success writes the
  /// auto-title / auto-description / thumbnail / labels back to the
  /// item via [DumpStorageService.updateEnrichment]. On failure the
  /// row is left with `enrichmentStatus = failed` and the UI falls
  /// back to filename + size.
  ///
  /// Idempotent — re-running enrich on the same item just overwrites
  /// the previous result.
  Future<void> scheduleEnrichment(DumpItem item) async {
    try {
      final result = await DumpEnricher.instance.enrich(item);
      await DumpStorageService.instance.updateEnrichment(
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
      debugPrint('DumpService.scheduleEnrichment(${item.id}) failed: $e');
      try {
        await DumpStorageService.instance.updateEnrichment(
          item.id,
          status: DumpEnrichmentStatus.failed,
        );
      } catch (_) {
        // Last-ditch — never propagate.
      }
    }
  }

  /// Reads the local thumbnail JPEG, encrypts and uploads it to the
  /// `dump-thumbs` bucket, then records the remote key on the
  /// DumpItem so `restoreFromCloud` can rehydrate it on a fresh
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
      if (!await ensureDumpThumbsBucket()) {
        debugPrint(
            'DumpService._uploadThumbnailToCloud($dumpItemId): '
            'dump-thumbs bucket unavailable — skipping');
        return;
      }
      final bytes = await file.readAsBytes();
      final now = DateTime.now();
      final yyyy = now.year.toString().padLeft(4, '0');
      final mm = now.month.toString().padLeft(2, '0');
      final remoteKey = '$yyyy/$mm/$dumpItemId.jpg';
      await FulaApiService.instance.encryptAndUpload(
        kDumpThumbsBucket,
        remoteKey,
        bytes,
        key,
        contentType: 'image/jpeg',
      );
      await DumpStorageService.instance
          .updateThumbnailRemoteKey(dumpItemId, remoteKey);
    } catch (e) {
      debugPrint(
          'DumpService._uploadThumbnailToCloud($dumpItemId): $e');
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
  /// `DumpItem.thumbnailPath` on success which triggers the Hive
  /// watch stream and re-renders the tile.
  Future<void> ensureLocalThumbnail(DumpItem item) async {
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
      final bytes = await FulaApiService.instance.downloadAndDecrypt(
        kDumpThumbsBucket,
        remoteKey,
        key,
      );
      final docs = await getApplicationDocumentsDirectory();
      final thumbsDir = Directory(p.join(docs.path, 'dump_thumbs'));
      if (!await thumbsDir.exists()) {
        await thumbsDir.create(recursive: true);
      }
      final dest = File(p.join(thumbsDir.path, '${item.id}.jpg'));
      await dest.writeAsBytes(bytes, flush: true);
      await DumpStorageService.instance
          .updateThumbnailLocalPath(item.id, dest.path);
    } catch (e) {
      debugPrint(
          'DumpService.ensureLocalThumbnail(${item.id}): $e');
    } finally {
      _thumbnailFetchInFlight.remove(item.id);
    }
  }

  /// Re-queue items left in [DumpUploadStatus.pendingAuth] — called
  /// from the auth-restore hook in Session 5 once the user signs back
  /// in.
  Future<int> retryPending() async {
    if (!_isInitialized) await init();
    if (!await _canEncryptNow()) return 0;
    final pending = DumpStorageService.instance.getPendingAuthItems();
    for (final item in pending) {
      await DumpStorageService.instance.updateStatus(
        item.id,
        DumpUploadStatus.queued,
      );
      unawaited(uploadOne(item));
    }
    return pending.length;
  }

  // ---- Drain (Plan B: main app reads dump_pending/ on resume) ---------

  /// Scan the staging directory for descriptor JSONs left behind by
  /// `DumpShareActivity`, ingest each batch, and delete the descriptor
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
          debugPrint('DumpService.drain: ${entity.path} failed: $e');
        }
      }
      // Sweep stray payload files whose descriptors were never seen.
      await DumpStorageService.instance.garbageCollectOrphans(pendingDir);
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
  Future<void> ensureDumpBucket() async {
    if (_bucketEnsured) return;
    final flag =
        LocalStorageService.instance.getSetting<bool>(_kDumpBucketInitializedFlag) ??
            false;
    if (flag) {
      _bucketEnsured = true;
      return;
    }
    try {
      final exists = await FulaApiService.instance.bucketExists(kDumpBucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(kDumpBucket);
      }
      await LocalStorageService.instance
          .saveSetting(_kDumpBucketInitializedFlag, true);
      _bucketEnsured = true;
    } catch (e) {
      // `createBucket` swallows "already exists" — anything else here
      // is genuinely transient (network / auth) and we'll retry on
      // the next call.
      debugPrint('DumpService.ensureDumpBucket non-fatal failure: $e');
    }
  }

  /// Same as [ensureDumpBucket] but for the `dump-thumbs` bucket.
  /// Called from `_uploadThumbnailToCloud` AND `ensureLocalThumbnail`
  /// — without this the first thumbnail upload on a fresh account
  /// fails with `NoSuchBucket: dump-thumbs` (visible in user logs).
  Future<bool> ensureDumpThumbsBucket() async {
    if (_thumbsBucketEnsured) return true;
    final flag = LocalStorageService.instance
            .getSetting<bool>(_kDumpThumbsBucketInitializedFlag) ??
        false;
    if (flag) {
      _thumbsBucketEnsured = true;
      return true;
    }
    try {
      final exists =
          await FulaApiService.instance.bucketExists(kDumpThumbsBucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(kDumpThumbsBucket);
      }
      await LocalStorageService.instance
          .saveSetting(_kDumpThumbsBucketInitializedFlag, true);
      _thumbsBucketEnsured = true;
      return true;
    } catch (e) {
      final s = e.toString();
      if (s.contains('BucketAlreadyExists') ||
          s.contains('BucketAlreadyOwnedByYou') ||
          s.contains('bucket already exists')) {
        _thumbsBucketEnsured = true;
        await LocalStorageService.instance
            .saveSetting(_kDumpThumbsBucketInitializedFlag, true);
        return true;
      }
      debugPrint('DumpService.ensureDumpThumbsBucket non-fatal: $e');
      return false;
    }
  }

  // ---- Internals ------------------------------------------------------

  Future<Directory> _pendingDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, kDumpPendingDir));
  }

  String _remoteKeyFor(DumpItem item) {
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
      debugPrint('DumpService._canEncryptNow: $e');
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
      final items = DumpStorageService.instance.getAll();
      DumpItem? match;
      for (final i in items) {
        if (p.canonicalize(i.localCachePath) == p.canonicalize(localPath)) {
          match = i;
          break;
        }
      }
      if (match == null) return;
      switch (status) {
        case SyncStatus.syncing:
          unawaited(DumpStorageService.instance.updateStatus(
            match.id, DumpUploadStatus.uploading,
          ));
          break;
        case SyncStatus.synced:
          unawaited(_onUploadSucceeded(match));
          break;
        case SyncStatus.error:
          unawaited(DumpStorageService.instance.updateStatus(
            match.id, DumpUploadStatus.failed,
            errorMessage: 'Upload failed',
          ));
          unawaited(DumpNotificationService.instance.showFailed(item: match));
          break;
        case SyncStatus.notSynced:
          // No-op — handled by other transitions.
          break;
      }
    };
    SyncService.instance.addListener(_syncListener!);
  }

  Future<void> _onUploadSucceeded(DumpItem item) async {
    await DumpStorageService.instance.updateStatus(
      item.id, DumpUploadStatus.uploaded,
    );
    final fresh = DumpStorageService.instance.getById(item.id) ?? item;
    await DumpNotificationService.instance
        .showComplete(items: <DumpItem>[fresh]);
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
    await DumpStorageService.instance.init();
    _isInitialized = true;
  }
}
