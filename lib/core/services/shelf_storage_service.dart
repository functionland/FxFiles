import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';

/// Persistence for the Shelf feature. Singleton, mirrors the repo's
/// existing `*Service` convention (see [SyncService], [AuthService]).
///
/// `init()` is idempotent and safe to call from both the main isolate
/// and the WorkManager background isolate (revision R1 in the Shelf
/// plan).
class ShelfStorageService {
  ShelfStorageService._();
  static final ShelfStorageService instance = ShelfStorageService._();

  static const String _boxName = 'dump_items';

  /// Holds the user-defined display order as a single JSON-encoded
  /// `List<String>` of item ids under the key `'order'`. New box name —
  /// no historical data, so we use the post-rename feature name.
  static const String _orderBoxName = 'shelf_order';
  static const String _orderKey = 'order';

  /// Tombstones for items the user removed but whose cloud-side cleanup
  /// (blob + thumb delete) has not yet succeeded. Keyed by item id;
  /// value is a JSON `PendingDeleteEntry`. Retry pass walks this box
  /// on every init + after each successful manifest sync.
  static const String _pendingDeletesBoxName = 'shelf_pending_deletes';

  /// Threshold below which `findDuplicate` does a full-file SHA-256
  /// verification (R8 in the Shelf plan). Above this, we accept the
  /// candidate match (size + 1MB-prefix sha) and document the
  /// false-dedup risk for large media.
  static const int fullHashThresholdBytes = 50 * 1024 * 1024;

  /// Bucket holding the encrypted index of all ShelfItem rows for this
  /// user. Key shape mirrors TagStorageService's `.fula/tags/<id>.json`
  /// convention.
  static const String _metadataBucket = 'dump-metadata';

  /// Current cloud manifest payload version. v1 was items-only; v2
  /// adds the `'order'` field (per-user display order). Restore tolerates
  /// both — a v1 payload restores items with no order applied (default
  /// newest-first sort).
  static const int _manifestVersion = 2;

  /// Debounce window for cloud sync. Two seconds matches TagStorageService.
  /// Shorter means the user is less likely to lose a sync to "shared
  /// then immediately closed the app" — the longer this is, the wider
  /// the window for the OS to kill the isolate before the Timer fires.
  /// (See also `flushSyncOnPause` wired from `app.dart` for the
  /// belt-and-braces case where even 2 s isn't enough.)
  static const Duration _syncDebounce = Duration(seconds: 2);

  Box<ShelfItem>? _box;
  Box<String>? _orderBox;
  Box<String>? _pendingDeletesBox;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized && (_box?.isOpen ?? false);

  Timer? _syncDebounceTimer;
  Completer<void>? _inFlightSync;
  bool _syncEnabled = true;

  // Bucket-ready cache. Mirrors TagStorageService._ensureBucketExists —
  // every `_doSyncNow` calls `_ensureMetadataBucket` which short-
  // circuits after the first success in this session. Without this
  // every upload would hit `NoSuchBucket` on a fresh account because
  // we never created the bucket before the first PUT.
  bool _metadataBucketReady = false;

  /// Test seam — production code leaves this null and uses the real
  /// `FulaApiService` / `AuthService`. Tests can stub it to record
  /// upload+download calls without spinning up the cloud client.
  @visibleForTesting
  Future<void> Function(Uint8List bytes, String key)? cloudSyncUploadOverride;

  @visibleForTesting
  Future<Uint8List?> Function(String key)? cloudSyncDownloadOverride;

  Future<void> init() async {
    if (isInitialized) return;

    if (!Hive.isAdapterRegistered(60)) {
      Hive.registerAdapter(ShelfCategoryAdapter());
    }
    if (!Hive.isAdapterRegistered(61)) {
      Hive.registerAdapter(ShelfUploadStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(62)) {
      Hive.registerAdapter(ShelfItemAdapter());
    }
    if (!Hive.isAdapterRegistered(63)) {
      Hive.registerAdapter(ShelfEnrichmentStatusAdapter());
    }

    try {
      _box = await Hive.openBox<ShelfItem>(_boxName)
          .timeout(const Duration(milliseconds: 1500));
      _isInitialized = true;
      // Backfill case: rows existed in local Hive before the cloud-
      // sync code shipped (or a previous sync attempt failed silently
      // due to a missing bucket). Schedule a sync now so they make
      // it to cloud before the user's next clean reset. The debounce
      // means we only fire once even if init() is called repeatedly
      // (e.g. background isolate + main isolate races).
      if ((_box?.length ?? 0) > 0) {
        _scheduleSyncToCloud();
      }
    } catch (e) {
      debugPrint('Failed to open dump_items box: $e');
    }

    // Order box — non-fatal if it fails to open; UI falls back to
    // default newest-first sort.
    try {
      _orderBox = await Hive.openBox<String>(_orderBoxName)
          .timeout(const Duration(milliseconds: 1500));
    } catch (e) {
      debugPrint('Failed to open shelf_order box: $e');
    }

    // Pending-deletes tombstone box — non-fatal if it fails to open;
    // cloud-cleanup retry just won't run this session (next launch
    // retries).
    try {
      _pendingDeletesBox = await Hive.openBox<String>(_pendingDeletesBoxName)
          .timeout(const Duration(milliseconds: 1500));
    } catch (e) {
      debugPrint('Failed to open shelf_pending_deletes box: $e');
    }
  }

  Future<void> add(ShelfItem item) async {
    final box = _box;
    if (box == null) return;
    await box.put(item.id, item);
    // Prepend to user-defined order so new arrivals land at the top
    // by default. Reorder-by-drag persists a permutation of this list;
    // future arrivals always go to position 0.
    await _prependToOrder(item.id);
    _scheduleSyncToCloud();
  }

  Future<void> update(ShelfItem item) async {
    final box = _box;
    if (box == null) return;
    await box.put(item.id, item);
    _scheduleSyncToCloud();
  }

  ShelfItem? getById(String id) => _box?.get(id);

  List<ShelfItem> getAll() => _box?.values.toList() ?? const <ShelfItem>[];

  /// Candidate-only dedup lookup by contentSha. Callers must additionally
  /// verify size + (for files ≤ [fullHashThresholdBytes]) full SHA-256
  /// via [findDuplicate].
  List<ShelfItem> findByContentSha(String contentSha) {
    final box = _box;
    if (box == null) return const <ShelfItem>[];
    return box.values.where((i) => i.contentSha == contentSha).toList();
  }

  /// Returns an existing item whose content matches [sourceFilePath]
  /// per R8 in the Shelf plan:
  ///   - same `contentSha` candidate AND same `sizeBytes`
  ///   - AND (if `sizeBytes <= fullHashThresholdBytes`) full SHA-256
  ///     of both files matches
  ///   - else (> threshold): accept candidate (documented false-dedup
  ///     risk for large media)
  ///
  /// Returns `null` when no duplicate is found.
  Future<ShelfItem?> findDuplicate({
    required String contentSha,
    required int sizeBytes,
    required String sourceFilePath,
  }) async {
    final candidates = findByContentSha(contentSha)
        .where((c) => c.sizeBytes == sizeBytes)
        .toList();
    if (candidates.isEmpty) return null;

    if (sizeBytes > fullHashThresholdBytes) {
      return candidates.first;
    }

    final sourceFullSha = await _fullSha256OfFile(sourceFilePath);
    if (sourceFullSha == null) {
      // Couldn't read source — fall back to candidate match.
      return candidates.first;
    }
    for (final c in candidates) {
      final candidateFullSha = await _fullSha256OfFile(c.localCachePath);
      if (candidateFullSha == sourceFullSha) return c;
    }
    return null;
  }

  Future<void> updateStatus(
    String id,
    ShelfUploadStatus status, {
    String? remoteKey,
    String? errorMessage,
  }) async {
    final existing = getById(id);
    if (existing == null) return;
    final updated = existing.copyWith(
      uploadStatus: status,
      remoteKey: remoteKey ?? existing.remoteKey,
      errorMessage: errorMessage,
    );
    await update(updated);
  }

  Future<void> updateEnrichment(
    String id, {
    String? title,
    String? description,
    String? thumbnailPath,
    List<String>? mlLabels,
    required ShelfEnrichmentStatus status,
  }) async {
    final existing = getById(id);
    if (existing == null) return;
    final updated = existing.copyWith(
      autoTitle: title ?? existing.autoTitle,
      autoDescription: description ?? existing.autoDescription,
      thumbnailPath: thumbnailPath ?? existing.thumbnailPath,
      mlLabels: mlLabels ?? existing.mlLabels,
      enrichmentStatus: status,
    );
    await update(updated);
  }

  /// Records the cloud key for the encrypted thumbnail JPEG. Called
  /// from `ShelfService` after the post-enrichment fire-and-forget
  /// upload succeeds. Lazy-fetch on a fresh device reads this key.
  Future<void> updateThumbnailRemoteKey(String id, String remoteKey) async {
    final existing = getById(id);
    if (existing == null) return;
    await update(existing.copyWith(thumbnailRemoteKey: remoteKey));
  }

  /// Sets the local thumbnail path for an item (used by lazy-fetch
  /// after downloading a thumbnail from `thumbnailRemoteKey`). Kept
  /// separate from `updateEnrichment` so the path change doesn't
  /// flip `enrichmentStatus`.
  Future<void> updateThumbnailLocalPath(String id, String localPath) async {
    final existing = getById(id);
    if (existing == null) return;
    await update(existing.copyWith(thumbnailPath: localPath));
  }

  Future<void> delete(String id) async {
    final box = _box;
    if (box == null) return;
    await box.delete(id);
    // Drop the id from the user-defined order so the next sync ships a
    // sanitised list. Keeping the orphan id is harmless (we filter on
    // restore) but bloats the manifest over time.
    await _removeFromOrder(id);
    _scheduleSyncToCloud();
  }

  // ----- User-defined order --------------------------------------------

  /// Returns the persisted display order. Items missing from this list
  /// (e.g. brand-new arrivals between the last manifest sync and the
  /// next provider rebuild) are surfaced separately by the sort layer.
  List<String> getOrder() {
    final box = _orderBox;
    if (box == null) return const <String>[];
    final raw = box.get(_orderKey);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded.cast<String>();
    } catch (e) {
      debugPrint('ShelfStorageService.getOrder: decode failed: $e');
      return const <String>[];
    }
  }

  /// Persist the user's preferred display order. The argument is
  /// sanitised — duplicates dropped, ids with no live ShelfItem
  /// removed — before writing, so a stale caller can't corrupt the
  /// stored list. Schedules a debounced cloud-manifest sync.
  Future<void> setOrder(List<String> ids) async {
    final orderBox = _orderBox;
    if (orderBox == null) return;
    final liveIds = _box?.keys.cast<String>().toSet() ?? const <String>{};
    final seen = <String>{};
    final cleaned = <String>[];
    for (final id in ids) {
      if (!liveIds.contains(id)) continue;
      if (!seen.add(id)) continue;
      cleaned.add(id);
    }
    // No-op write skip: avoids a redundant cloud-manifest re-upload
    // when the UI fires onReorder for an unchanged final position
    // (e.g. drag picked up then dropped onto the same slot).
    final current = getOrder();
    if (_listEquals(current, cleaned)) return;
    await orderBox.put(_orderKey, jsonEncode(cleaned));
    _scheduleSyncToCloud();
  }

  /// Watch the persisted order as a stream of snapshots. The provider
  /// layer maps this into the sort step.
  Stream<List<String>> watchOrder() async* {
    final box = _orderBox;
    if (box == null) {
      yield const <String>[];
      return;
    }
    yield getOrder();
    yield* box.watch(key: _orderKey).map((_) => getOrder());
  }

  Future<void> _prependToOrder(String id) async {
    final box = _orderBox;
    if (box == null) return;
    final current = getOrder();
    if (current.isNotEmpty && current.first == id) return; // no-op
    final updated = <String>[id, ...current.where((x) => x != id)];
    await box.put(_orderKey, jsonEncode(updated));
  }

  Future<void> _removeFromOrder(String id) async {
    final box = _orderBox;
    if (box == null) return;
    final current = getOrder();
    if (!current.contains(id)) return;
    final updated = current.where((x) => x != id).toList(growable: false);
    await box.put(_orderKey, jsonEncode(updated));
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ----- Pending-delete tombstones --------------------------------------

  /// Snapshot of every item id awaiting cloud-side cleanup. Used by
  /// the provider layer to hide them from the visible grid even
  /// before the Hive row is removed.
  Set<String> getPendingDeleteIds() {
    final box = _pendingDeletesBox;
    if (box == null) return const <String>{};
    return box.keys.cast<String>().toSet();
  }

  /// Returns the structured entry for a pending delete (remote keys
  /// snapshot, marked-at timestamp) so the retry pass can rerun the
  /// cloud deletes without re-reading the (now-removed) ShelfItem.
  ShelfPendingDeleteEntry? getPendingDelete(String id) {
    final box = _pendingDeletesBox;
    if (box == null) return null;
    final raw = box.get(id);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return ShelfPendingDeleteEntry.fromJson(decoded);
    } catch (e) {
      debugPrint('ShelfStorageService.getPendingDelete($id): decode failed: $e');
      return null;
    }
  }

  Future<void> markPendingDelete(ShelfPendingDeleteEntry entry) async {
    final box = _pendingDeletesBox;
    if (box == null) return;
    await box.put(entry.itemId, jsonEncode(entry.toJson()));
  }

  Future<void> clearPendingDelete(String id) async {
    final box = _pendingDeletesBox;
    if (box == null) return;
    if (!box.containsKey(id)) return;
    await box.delete(id);
  }

  Stream<Set<String>> watchPendingDeleteIds() async* {
    final box = _pendingDeletesBox;
    if (box == null) {
      yield const <String>{};
      return;
    }
    yield getPendingDeleteIds();
    yield* box.watch().map((_) => getPendingDeleteIds());
  }

  /// Items left in [ShelfUploadStatus.pendingAuth] — picked up by the
  /// ShelfService after a successful session restore (R10).
  List<ShelfItem> getPendingAuthItems() {
    final box = _box;
    if (box == null) return const <ShelfItem>[];
    return box.values
        .where((i) => i.uploadStatus == ShelfUploadStatus.pendingAuth)
        .toList();
  }

  /// Stream of the current list. Emits the current snapshot first, then
  /// re-emits the full list on every box mutation.
  Stream<List<ShelfItem>> watch() async* {
    final box = _box;
    if (box == null) {
      yield const <ShelfItem>[];
      return;
    }
    yield box.values.toList();
    yield* box.watch().map((_) => box.values.toList());
  }

  /// Sweep stale files under [pendingDir] that do not correspond to any
  /// item in the box. Used on init to recover from a partial share
  /// receiver crash (R7 in the Shelf plan).
  ///
  /// Paths are canonicalized via `package:path` before comparison so a
  /// `localCachePath` saved with one separator style (or relative form)
  /// still matches the absolute path returned by `Directory.list()`.
  /// On Windows this also normalises drive-letter case.
  Future<int> garbageCollectOrphans(Directory pendingDir) async {
    if (!await pendingDir.exists()) return 0;
    final box = _box;
    if (box == null) return 0;
    final knownPaths = box.values
        .map((i) => p.canonicalize(i.localCachePath))
        .toSet();
    var deleted = 0;
    await for (final entity in pendingDir.list()) {
      if (entity is! File) continue;
      if (knownPaths.contains(p.canonicalize(entity.path))) continue;
      try {
        await entity.delete();
        deleted++;
      } catch (e) {
        debugPrint('Failed to delete orphan ${entity.path}: $e');
      }
    }
    return deleted;
  }

  /// Convenience for tests / hot-restart: close the box. After this,
  /// `init()` must be called again.
  Future<void> close() async {
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    await _box?.close();
    _box = null;
    await _orderBox?.close();
    _orderBox = null;
    await _pendingDeletesBox?.close();
    _pendingDeletesBox = null;
    _isInitialized = false;
  }

  /// Test-only: closes the box and resets initialization state so the
  /// next test can call `init()` against a fresh Hive directory.
  /// Mirrors the convention in `AutomateTaskService.resetForTesting`.
  @visibleForTesting
  Future<void> resetForTesting() async {
    cloudSyncUploadOverride = null;
    cloudSyncDownloadOverride = null;
    _syncEnabled = true;
    _metadataBucketReady = false;
    await close();
  }

  // -------------------- Cloud sync --------------------
  //
  // Mirrors the TagStorageService pattern: encrypted JSON snapshot of
  // every ShelfItem row, uploaded to `dump-metadata/.fula/dumps/<userId>.json`,
  // restored on the next clean install. Device-specific fields
  // (localCachePath, thumbnailPath) are stripped on the way out and
  // rehydrated lazily on the way back in (see ShelfItem.toJson/fromJson).
  //
  // Sync is *write-amplifying* — every mutation reschedules a debounced
  // upload of the whole index. For a few thousand items the snapshot
  // is < 1 MB so this is cheap; if it grows we'd switch to a delta or
  // per-id key. Test seams (`cloudSyncUploadOverride` /
  // `cloudSyncDownloadOverride`) let unit tests assert sync behaviour
  // without spinning up FulaApiService.

  /// Manually trigger an immediate sync. Mutations call
  /// [_scheduleSyncToCloud] which debounces by [_syncDebounce]; this
  /// is the public hook to flush right away (e.g. before sign-out).
  Future<void> syncToCloud() => _doSyncNow();

  /// Public entry point used by the auth-restore hook on cold start.
  /// Idempotent + non-fatal: missing bucket, missing key, missing
  /// session → silent return. On success the box is populated with
  /// the cloud rows.
  Future<int> restoreFromCloud() async {
    if (!isInitialized) await init();
    final box = _box;
    if (box == null) return 0;
    if (!_syncEnabled) return 0;

    Uint8List? data;
    try {
      if (cloudSyncDownloadOverride != null) {
        // Test mode — bypass auth + FulaApiService.
        data = await cloudSyncDownloadOverride!('.fula/dumps/test.json');
      } else {
        final encryptionKey = await AuthService.instance.getEncryptionKey();
        if (encryptionKey == null) {
          debugPrint('ShelfStorageService.restoreFromCloud: '
              'no encryption key — skipping');
          return 0;
        }
        final userId = await _getUserId();
        if (userId == null) {
          debugPrint('ShelfStorageService.restoreFromCloud: '
              'no userId — skipping');
          return 0;
        }
        if (!FulaApiService.instance.isConfigured) {
          debugPrint('ShelfStorageService.restoreFromCloud: '
              'FulaApiService not configured — skipping');
          return 0;
        }
        debugPrint('ShelfStorageService.restoreFromCloud: '
            'downloading bucket=$_metadataBucket '
            'key=.fula/dumps/$userId.json');
        data = await FulaApiService.instance.downloadAndDecrypt(
          _metadataBucket,
          '.fula/dumps/$userId.json',
          encryptionKey,
        );
        debugPrint('ShelfStorageService.restoreFromCloud: '
            'downloaded ${data.length} bytes from cloud');
      }
    } catch (e) {
      debugPrint('ShelfStorageService.restoreFromCloud: download failed: $e');
      return 0;
    }
    if (data == null || data.isEmpty) return 0;

    try {
      final jsonStr = utf8.decode(data);
      final raw = jsonDecode(jsonStr);
      if (raw is! Map<String, dynamic>) return 0;
      final items = (raw['items'] as List?) ?? const <dynamic>[];
      var restored = 0;
      for (final entry in items) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          final restoredItem = ShelfItem.fromJson(entry);
          // Don't clobber a row we already have locally — local state
          // can be ahead of the cloud snapshot (e.g. an upload-in-
          // progress on a shared item).
          if (box.containsKey(restoredItem.id)) continue;
          await box.put(restoredItem.id, restoredItem);
          restored++;
        } catch (e) {
          debugPrint('ShelfStorageService.restoreFromCloud: '
              'skipping malformed entry: $e');
        }
      }
      // v2 manifest carries the user-defined order. v1 payloads omit
      // it; we leave the local order untouched in that case so a
      // partial cross-device restore from an older client doesn't
      // wipe the locally-set order. Sanitise against the post-restore
      // item set.
      final cloudOrder = raw['order'];
      if (cloudOrder is List) {
        final liveIds = box.keys.cast<String>().toSet();
        final cleaned = cloudOrder
            .whereType<String>()
            .where(liveIds.contains)
            .toSet()
            .toList(growable: false);
        await _orderBox?.put(_orderKey, jsonEncode(cleaned));
      }
      debugPrint('ShelfStorageService.restoreFromCloud: restored $restored '
          'of ${items.length} dump items '
          '(order: ${cloudOrder is List ? cloudOrder.length : 0})');
      return restored;
    } catch (e) {
      debugPrint(
          'ShelfStorageService.restoreFromCloud: parse failed: $e');
      return 0;
    }
  }

  void _scheduleSyncToCloud() {
    if (!_syncEnabled) return;
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(_syncDebounce, () {
      _syncDebounceTimer = null;
      _doSyncNow();
    });
  }

  Future<void> _doSyncNow() async {
    if (!_syncEnabled) return;
    // Coalesce concurrent calls so a Timer firing while the previous
    // sync is still mid-upload doesn't double-fire.
    if (_inFlightSync != null) {
      await _inFlightSync!.future;
      return;
    }
    final completer = Completer<void>();
    _inFlightSync = completer;

    try {
      final box = _box;
      if (box == null) return;

      final items = box.values.map((i) => i.toJson()).toList(growable: false);
      // Sanitise the order against the current item set on the way
      // out — drops any orphan ids (e.g. a delete that happened
      // between the in-memory list snapshot and now).
      final liveIds = box.keys.cast<String>().toSet();
      final order = getOrder().where(liveIds.contains).toList(growable: false);
      final payload = <String, dynamic>{
        'v': _manifestVersion,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'items': items,
        'order': order,
      };
      final data = Uint8List.fromList(utf8.encode(jsonEncode(payload)));

      try {
        if (cloudSyncUploadOverride != null) {
          // Test mode — bypass auth + FulaApiService.
          await cloudSyncUploadOverride!(data, '.fula/dumps/test.json');
        } else {
          final encryptionKey =
              await AuthService.instance.getEncryptionKey();
          if (encryptionKey == null) return;
          final userId = await _getUserId();
          if (userId == null) return;
          if (!FulaApiService.instance.isConfigured) return;
          // Make sure the bucket exists before the PUT. Without this,
          // every upload hits NoSuchBucket on a fresh account and the
          // cloud-restore on the next install finds nothing.
          if (!await _ensureMetadataBucket()) {
            debugPrint('ShelfStorageService.syncToCloud: '
                'metadata bucket unavailable — skipping');
            return;
          }
          payload['userId'] = userId;
          final dataWithUser =
              Uint8List.fromList(utf8.encode(jsonEncode(payload)));
          debugPrint('ShelfStorageService.syncToCloud: '
              'starting upload of ${items.length} items '
              '(${dataWithUser.length} bytes)');
          await FulaApiService.instance.encryptAndUpload(
            _metadataBucket,
            '.fula/dumps/$userId.json',
            dataWithUser,
            encryptionKey,
            contentType: 'application/json',
          );
        }
        debugPrint('ShelfStorageService.syncToCloud: uploaded '
            '${items.length} items (${data.length} bytes)');
      } catch (e) {
        final s = e.toString();
        if (s.contains('AccountProblem') ||
            s.contains('QuotaExceeded') ||
            s.contains('AccessDenied')) {
          // Don't keep retrying a permanently broken sync — log once
          // and disable for the rest of the session.
          debugPrint(
              'ShelfStorageService: cloud sync disabled (permanent): $e');
          _syncEnabled = false;
        } else {
          debugPrint('ShelfStorageService.syncToCloud: $e');
        }
      }
    } finally {
      _inFlightSync = null;
      completer.complete();
    }
  }

  /// Ensure the `dump-metadata` bucket exists before we PUT into it.
  /// Mirrors `TagStorageService._ensureBucketExists`: try `createBucket`
  /// (which is idempotent in spirit but throws on existing buckets in
  /// most S3-flavoured APIs), tolerate the canonical
  /// "BucketAlreadyExists" / "BucketAlreadyOwnedByYou" errors, and
  /// fall back to `listObjects` as a final sanity check.
  ///
  /// Cached in `_metadataBucketReady` so a long-lived session pays
  /// the round-trip exactly once.
  Future<bool> _ensureMetadataBucket() async {
    if (_metadataBucketReady) return true;
    try {
      await FulaApiService.instance.createBucket(_metadataBucket);
      _metadataBucketReady = true;
      debugPrint('ShelfStorageService: metadata bucket created');
      return true;
    } catch (e) {
      final s = e.toString();
      if (s.contains('BucketAlreadyExists') ||
          s.contains('BucketAlreadyOwnedByYou') ||
          s.contains('bucket already exists')) {
        _metadataBucketReady = true;
        return true;
      }
      // Some S3 backends 200 on "create existing" but our wrapper may
      // surface it differently — try a list as a tie-breaker before
      // giving up. If list succeeds, the bucket is there.
      try {
        await FulaApiService.instance.listObjects(_metadataBucket);
        _metadataBucketReady = true;
        return true;
      } catch (_) {
        debugPrint('ShelfStorageService._ensureMetadataBucket: $e');
        return false;
      }
    }
  }

  Future<String?> _getUserId() async {
    try {
      final publicKey = await AuthService.instance.getPublicKeyString();
      if (publicKey == null || publicKey.isEmpty) return null;
      final hash = sha256.convert(utf8.encode(publicKey));
      return hash.toString().substring(0, 16);
    } catch (e) {
      debugPrint('ShelfStorageService._getUserId failed: $e');
      return null;
    }
  }

  Future<String?> _fullSha256OfFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString();
    } catch (e) {
      debugPrint('Failed to hash $path: $e');
      return null;
    }
  }
}

/// Tombstone record for a deleted ShelfItem whose cloud-side cleanup
/// (blob + thumb delete) has not yet succeeded. Persisted in
/// `'shelf_pending_deletes'` so the retry pass on the next session can
/// finish the job even if the original delete attempt was interrupted
/// by an app kill / network drop.
class ShelfPendingDeleteEntry {
  final String itemId;
  final DateTime markedAt;
  final String? remoteKey;
  final String? thumbnailRemoteKey;

  /// Path of the resumable-upload manifest that was in flight when the
  /// delete fired, if any. Used by the orchestrator to abort the
  /// upload so it can't write back a `remoteKey` against an item that
  /// no longer exists.
  final String? resumableManifestPath;

  const ShelfPendingDeleteEntry({
    required this.itemId,
    required this.markedAt,
    this.remoteKey,
    this.thumbnailRemoteKey,
    this.resumableManifestPath,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'itemId': itemId,
        'markedAt': markedAt.toUtc().toIso8601String(),
        if (remoteKey != null) 'remoteKey': remoteKey,
        if (thumbnailRemoteKey != null)
          'thumbnailRemoteKey': thumbnailRemoteKey,
        if (resumableManifestPath != null)
          'resumableManifestPath': resumableManifestPath,
      };

  factory ShelfPendingDeleteEntry.fromJson(Map<String, dynamic> json) {
    return ShelfPendingDeleteEntry(
      itemId: json['itemId'] as String,
      markedAt: DateTime.parse(json['markedAt'] as String),
      remoteKey: json['remoteKey'] as String?,
      thumbnailRemoteKey: json['thumbnailRemoteKey'] as String?,
      resumableManifestPath: json['resumableManifestPath'] as String?,
    );
  }
}
