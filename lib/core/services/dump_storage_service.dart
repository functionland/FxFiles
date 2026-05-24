import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';

/// Persistence for the Dump feature. Singleton, mirrors the repo's
/// existing `*Service` convention (see [SyncService], [AuthService]).
///
/// `init()` is idempotent and safe to call from both the main isolate
/// and the WorkManager background isolate (revision R1 in the Dump
/// plan).
class DumpStorageService {
  DumpStorageService._();
  static final DumpStorageService instance = DumpStorageService._();

  static const String _boxName = 'dump_items';

  /// Threshold below which `findDuplicate` does a full-file SHA-256
  /// verification (R8 in the Dump plan). Above this, we accept the
  /// candidate match (size + 1MB-prefix sha) and document the
  /// false-dedup risk for large media.
  static const int fullHashThresholdBytes = 50 * 1024 * 1024;

  /// Bucket holding the encrypted index of all DumpItem rows for this
  /// user. Key shape mirrors TagStorageService's `.fula/tags/<id>.json`
  /// convention.
  static const String _metadataBucket = 'dump-metadata';

  /// Debounce window for cloud sync. Two seconds matches TagStorageService.
  /// Shorter means the user is less likely to lose a sync to "shared
  /// then immediately closed the app" — the longer this is, the wider
  /// the window for the OS to kill the isolate before the Timer fires.
  /// (See also `flushSyncOnPause` wired from `app.dart` for the
  /// belt-and-braces case where even 2 s isn't enough.)
  static const Duration _syncDebounce = Duration(seconds: 2);

  Box<DumpItem>? _box;
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
      Hive.registerAdapter(DumpCategoryAdapter());
    }
    if (!Hive.isAdapterRegistered(61)) {
      Hive.registerAdapter(DumpUploadStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(62)) {
      Hive.registerAdapter(DumpItemAdapter());
    }
    if (!Hive.isAdapterRegistered(63)) {
      Hive.registerAdapter(DumpEnrichmentStatusAdapter());
    }

    try {
      _box = await Hive.openBox<DumpItem>(_boxName)
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
  }

  Future<void> add(DumpItem item) async {
    final box = _box;
    if (box == null) return;
    await box.put(item.id, item);
    _scheduleSyncToCloud();
  }

  Future<void> update(DumpItem item) async {
    final box = _box;
    if (box == null) return;
    await box.put(item.id, item);
    _scheduleSyncToCloud();
  }

  DumpItem? getById(String id) => _box?.get(id);

  List<DumpItem> getAll() => _box?.values.toList() ?? const <DumpItem>[];

  /// Candidate-only dedup lookup by contentSha. Callers must additionally
  /// verify size + (for files ≤ [fullHashThresholdBytes]) full SHA-256
  /// via [findDuplicate].
  List<DumpItem> findByContentSha(String contentSha) {
    final box = _box;
    if (box == null) return const <DumpItem>[];
    return box.values.where((i) => i.contentSha == contentSha).toList();
  }

  /// Returns an existing item whose content matches [sourceFilePath]
  /// per R8 in the Dump plan:
  ///   - same `contentSha` candidate AND same `sizeBytes`
  ///   - AND (if `sizeBytes <= fullHashThresholdBytes`) full SHA-256
  ///     of both files matches
  ///   - else (> threshold): accept candidate (documented false-dedup
  ///     risk for large media)
  ///
  /// Returns `null` when no duplicate is found.
  Future<DumpItem?> findDuplicate({
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
    DumpUploadStatus status, {
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
    required DumpEnrichmentStatus status,
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
  /// from `DumpService` after the post-enrichment fire-and-forget
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
    _scheduleSyncToCloud();
  }

  /// Items left in [DumpUploadStatus.pendingAuth] — picked up by the
  /// DumpService after a successful session restore (R10).
  List<DumpItem> getPendingAuthItems() {
    final box = _box;
    if (box == null) return const <DumpItem>[];
    return box.values
        .where((i) => i.uploadStatus == DumpUploadStatus.pendingAuth)
        .toList();
  }

  /// Stream of the current list. Emits the current snapshot first, then
  /// re-emits the full list on every box mutation.
  Stream<List<DumpItem>> watch() async* {
    final box = _box;
    if (box == null) {
      yield const <DumpItem>[];
      return;
    }
    yield box.values.toList();
    yield* box.watch().map((_) => box.values.toList());
  }

  /// Sweep stale files under [pendingDir] that do not correspond to any
  /// item in the box. Used on init to recover from a partial share
  /// receiver crash (R7 in the Dump plan).
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
  // every DumpItem row, uploaded to `dump-metadata/.fula/dumps/<userId>.json`,
  // restored on the next clean install. Device-specific fields
  // (localCachePath, thumbnailPath) are stripped on the way out and
  // rehydrated lazily on the way back in (see DumpItem.toJson/fromJson).
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
          debugPrint('DumpStorageService.restoreFromCloud: '
              'no encryption key — skipping');
          return 0;
        }
        final userId = await _getUserId();
        if (userId == null) {
          debugPrint('DumpStorageService.restoreFromCloud: '
              'no userId — skipping');
          return 0;
        }
        if (!FulaApiService.instance.isConfigured) {
          debugPrint('DumpStorageService.restoreFromCloud: '
              'FulaApiService not configured — skipping');
          return 0;
        }
        debugPrint('DumpStorageService.restoreFromCloud: '
            'downloading bucket=$_metadataBucket '
            'key=.fula/dumps/$userId.json');
        data = await FulaApiService.instance.downloadAndDecrypt(
          _metadataBucket,
          '.fula/dumps/$userId.json',
          encryptionKey,
        );
        debugPrint('DumpStorageService.restoreFromCloud: '
            'downloaded ${data.length} bytes from cloud');
      }
    } catch (e) {
      debugPrint('DumpStorageService.restoreFromCloud: download failed: $e');
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
          final restoredItem = DumpItem.fromJson(entry);
          // Don't clobber a row we already have locally — local state
          // can be ahead of the cloud snapshot (e.g. an upload-in-
          // progress on a shared item).
          if (box.containsKey(restoredItem.id)) continue;
          await box.put(restoredItem.id, restoredItem);
          restored++;
        } catch (e) {
          debugPrint('DumpStorageService.restoreFromCloud: '
              'skipping malformed entry: $e');
        }
      }
      debugPrint('DumpStorageService.restoreFromCloud: restored $restored '
          'of ${items.length} dump items');
      return restored;
    } catch (e) {
      debugPrint(
          'DumpStorageService.restoreFromCloud: parse failed: $e');
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
      final payload = <String, dynamic>{
        'v': 1,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'items': items,
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
            debugPrint('DumpStorageService.syncToCloud: '
                'metadata bucket unavailable — skipping');
            return;
          }
          payload['userId'] = userId;
          final dataWithUser =
              Uint8List.fromList(utf8.encode(jsonEncode(payload)));
          debugPrint('DumpStorageService.syncToCloud: '
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
        debugPrint('DumpStorageService.syncToCloud: uploaded '
            '${items.length} items (${data.length} bytes)');
      } catch (e) {
        final s = e.toString();
        if (s.contains('AccountProblem') ||
            s.contains('QuotaExceeded') ||
            s.contains('AccessDenied')) {
          // Don't keep retrying a permanently broken sync — log once
          // and disable for the rest of the session.
          debugPrint(
              'DumpStorageService: cloud sync disabled (permanent): $e');
          _syncEnabled = false;
        } else {
          debugPrint('DumpStorageService.syncToCloud: $e');
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
      debugPrint('DumpStorageService: metadata bucket created');
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
        debugPrint('DumpStorageService._ensureMetadataBucket: $e');
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
      debugPrint('DumpStorageService._getUserId failed: $e');
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
