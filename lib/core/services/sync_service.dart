import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/models/sync_task.dart' as persistent;
import 'package:path_provider/path_provider.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/storage_refresh_service.dart';
import 'package:fula_files/core/services/cloud_sync_mapping_service.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/core/services/sync_notification_service.dart';
import 'package:fula_files/core/services/upload_progress_manager.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/upload_queue_lock.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Method channel shared with MainActivity; routes startUploadService /
// stopUploadService through to SyncForegroundService. See
// android/.../SyncForegroundService.kt for the Android side.
const MethodChannel _syncForegroundChannel =
    MethodChannel('land.fx.files/sync_notification');

enum SyncDirection { upload, download, bidirectional }

typedef SyncStatusCallback = void Function(String localPath, SyncStatus status);

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  final List<SyncTask> _uploadQueue = [];
  final List<SyncTask> _downloadQueue = [];
  final Map<String, SyncProgress> _activeSync = {};
  final List<SyncStatusCallback> _listeners = [];

  // Map from localPath to persistent task ID for queue persistence
  final Map<String, String> _taskIdMap = {};

  // Track cancelled buckets to prevent retry callbacks from re-queuing
  final Set<String> _cancelledBuckets = {};

  // Track cancelled localPaths so:
  //   (1) the retry callback in _executeUpload's catch block won't re-queue,
  //   (2) an in-flight upload that completes successfully after cancel won't
  //       flip SyncState to synced.
  // Cleared when a path is genuinely re-queued (e.g. retryFailed, queueUpload).
  // For true mid-chunk abort we need an SDK CancellationToken (Phase B3).
  final Set<String> _cancelledLocalPaths = {};

  // Cross-isolate lock against the SyncForegroundService isolate. Held
  // while this isolate's processUploadQueue is actually draining. The
  // service isolate waits on this lock before taking over, so we never
  // get two `EncryptedClient`s uploading the same SyncTask in parallel
  // (which would generate two distinct DEKs and orphan one of the two
  // ciphertext copies on the storage backend).
  final UploadQueueLock _queueLock = UploadQueueLock(ownerTag: 'sync-service');

  // Phase C: per-task cancel handles for in-flight resumable uploads.
  // Created when an upload starts (in `_executeUpload`), populated into
  // this map, removed on success / error / cancel. `cancelTask` looks
  // up the handle by localPath and triggers it for truly-abortive
  // cancellation (issues fula-api#17 + #18).
  final Map<String, fula.CancelHandle> _activeCancelHandles = {};

  // Phase C + fula-api#20: pending manifest aborts queued by cancelTask
  // while an upload was in flight. _executeUpload's `finally` block
  // (where `_activeCancelHandles` is removed) drains this map and calls
  // `abortResumableUpload` after the in-flight upload has settled —
  // sequentialising abort vs. the upload's own chunk PUTs so partial-
  // upload chunks left on the backend get cleaned up without racing
  // the in-flight code's manifest writes.
  //
  // Keyed by `task.localPath`. Value is the `manifestPath` captured
  // from the persistent task row at cancel time (the row gets removed
  // by cancelTask before the upload settles, so we can't re-derive it
  // later).
  final Map<String, String> _pendingManifestAborts = {};

  // Phase C: cached manifest directory. Resolved lazily on first
  // resumable upload so app startup doesn't pay the path_provider call.
  Directory? _manifestDir;

  // True once we've told MainActivity to bring up the foreground
  // service for the current upload batch. Mirrors the lifecycle of the
  // Android service so we don't double-start. Reset when the service
  // tells us it stopped, or when we hit `cancelAllUploads`.
  bool _foregroundServiceRequested = false;

  List<SyncTask> get uploadQueue => List.unmodifiable(_uploadQueue);
  List<SyncTask> get downloadQueue => List.unmodifiable(_downloadQueue);
  Map<String, SyncProgress> get activeSync => Map.unmodifiable(_activeSync);

  bool _isProcessingUpload = false;
  bool _isRestoring = false;

  // Parallel upload configuration - increased for better performance
  static const int maxParallelUploads = 5;
  int _activeUploads = 0;

  // Throttle upload starts - reduced for faster queueing
  DateTime _lastUploadStart = DateTime.now();

  // Retry configuration
  static const int maxRetryAttempts = 5;
  static const Duration initialRetryDelay = Duration(seconds: 2);
  static const Duration maxRetryDelay = Duration(minutes: 5);

  // Track consecutive failures to pause queue on persistent errors
  int _consecutiveFailures = 0;
  static const int maxConsecutiveFailures = 3;
  bool _isPaused = false;

  // Debounced folder share manifest update (supports multiple folders)
  Timer? _folderShareUpdateTimer;
  final Map<String, String> _pendingFolderShareUpdates = {}; // prefix → bucket

  // Debounced tag share manifest update (one entry per tagId)
  Timer? _tagShareUpdateTimer;
  final Set<String> _pendingTagShareUpdates = {};
  DateTime? _pausedUntil;

  // Public getters for UI to show sync status
  bool get isPaused => _isPaused;
  DateTime? get pausedUntil => _pausedUntil;
  int get consecutiveFailures => _consecutiveFailures;
  int get pendingUploadCount => _uploadQueue.length;

  /// Get all tasks that have failed (for showing retry button in UI)
  List<SyncState> getFailedTasks() {
    return LocalStorageService.instance.getAllSyncStates()
        .where((s) => s.status == SyncStatus.error)
        .toList();
  }

  /// Cancel all pending uploads for a specific bucket (used when disabling folder sync)
  Future<void> cancelUploadsForBucket(String bucket) async {
    debugPrint('Cancelling pending uploads for bucket: $bucket');

    // Find and remove matching tasks from upload queue
    final toRemove = <SyncTask>[];
    for (final task in _uploadQueue) {
      if (task.remoteBucket == bucket) {
        toRemove.add(task);
      }
    }

    for (final task in toRemove) {
      _uploadQueue.remove(task);

      // Remove from persistent storage
      final taskId = _taskIdMap.remove(task.localPath);
      if (taskId != null) {
        await LocalStorageService.instance.removeSyncTask(taskId);
      }

      // Update sync state to not synced
      final state = LocalStorageService.instance.getSyncState(task.localPath);
      if (state != null) {
        await LocalStorageService.instance.addSyncState(
          state.copyWith(status: SyncStatus.notSynced),
        );
        _notifyListeners(task.localPath, SyncStatus.notSynced);
      }
    }

    // Prevent scheduled retry callbacks from re-queuing tasks for this bucket
    _cancelledBuckets.add(bucket);

    debugPrint('Cancelled ${toRemove.length} pending uploads for bucket: $bucket');
  }

  /// Allow a previously cancelled bucket to accept new uploads (called when re-enabling sync)
  void clearCancelledBucket(String bucket) {
    _cancelledBuckets.remove(bucket);
  }

  /// Phase C: derive a stable, per-task manifest path under the app's
  /// documents directory. Naming is hash-based on the task's `localPath`
  /// + `remoteBucket` + `remoteKey` so retries for the same task land
  /// at the same path — no collisions across distinct tasks, no
  /// orphans from minor metadata drift on the same task.
  Future<String> _manifestPathFor(SyncTask task) async {
    _manifestDir ??= await () async {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/sync_manifests');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }();
    // Avoid path separators / arbitrary chars in the filename — hash
    // the task identity. SHA-256 of "${localPath}|${bucket}|${remoteKey}"
    // is overkill for collision avoidance but matches the conservative
    // naming pattern used elsewhere (e.g., BucketCacheService).
    final raw = '${task.localPath}|${task.remoteBucket}|${task.remoteKey}';
    final hash = raw.codeUnits.fold<int>(
      0x811c9dc5,
      (h, b) => ((h ^ b) * 0x01000193) & 0xFFFFFFFF,
    );
    final hex = hash.toRadixString(16).padLeft(8, '0');
    return '${_manifestDir!.path}/sync_$hex.manifest';
  }

  /// Cancel a single queued or in-progress upload by its [localPath].
  ///
  /// Behavior:
  ///   - If the task is still queued (in [_uploadQueue]), remove it before
  ///     it ever starts.
  ///   - If the task is in-flight, mark it cancelled. The active
  ///     [FulaApiService.uploadLargeFileFromPath] future cannot be aborted
  ///     today (the FRB binding doesn't expose a cancellation token; see
  ///     `fula-flutter/src/api/forest.rs:put_flat_from_path`); whatever
  ///     resolution it produces is then suppressed so the UI doesn't flip
  ///     to "synced" and no retry is scheduled.
  ///   - Persistent SyncTask row is removed and SyncState transitions to
  ///     [SyncStatus.notSynced]. UploadProgressManager.failUpload is called
  ///     so the batch progress widget releases its slot.
  Future<void> cancelTask(String localPath) async {
    debugPrint('SyncService: cancelTask($localPath)');

    // Mark cancelled first so any concurrent retry callback / in-flight
    // completion observes the flag and bails out.
    _cancelledLocalPaths.add(localPath);

    // fula-api#20: look up the persistent task's manifestPath BEFORE
    // removing the row below. Any chunked-resumable upload that left a
    // manifest on disk needs that path so we can clean up the manifest
    // file + already-uploaded backend chunks via abort_resumable_upload.
    // Tasks that never started an upload (queued-only) won't have a
    // manifestPath — abort is skipped in that case.
    final taskId = _taskIdMap[localPath];
    final persistentTask = taskId != null
        ? LocalStorageService.instance.getSyncTask(taskId)
        : null;
    final manifestPath = persistentTask?.manifestPath;

    // Phase C: if an in-flight resumable upload has a registered cancel
    // handle, trigger it. The SDK's cooperative cancel returns
    // Err(Cancelled) after the chunks already in flight (up to 16 per
    // fula-api#18) complete. The retry/state suppression logic below +
    // _cancelledLocalPaths handles the brief overlap where late-
    // completing chunks would otherwise flip the task to "synced".
    final cancelHandle = _activeCancelHandles[localPath];
    if (cancelHandle != null) {
      FulaApiService.instance.triggerCancel(cancelHandle);
      debugPrint(
        'SyncService: cancel handle triggered for $localPath; '
        'in-flight upload will return Cancelled shortly',
      );
      // fula-api#20: queue the abort to run AFTER _executeUpload's
      // finally drains it. This serialises abort vs. the in-flight
      // chunk PUTs so partial-upload chunks get cleaned up without
      // racing the in-flight code's manifest writes.
      if (manifestPath != null && manifestPath.isNotEmpty) {
        _pendingManifestAborts[localPath] = manifestPath;
      }
    } else if (manifestPath != null && manifestPath.isNotEmpty) {
      // fula-api#20: not-in-flight (queued only, or previously failed
      // and abandoned). _executeUpload's finally won't fire for this
      // task, so clean up the manifest + orphan chunks right now.
      // Fire-and-forget — abort is best-effort + idempotent (no-op if
      // the manifest was already cleaned by a prior abort or by an
      // SDK auto-delete on a successful upload).
      unawaited(FulaApiService.instance.abortResumableUpload(manifestPath));
    }

    // Drop from the in-memory queue if still pending.
    _uploadQueue.removeWhere((t) => t.localPath == localPath);

    // Remove from persistent storage so restoreQueue doesn't pick it back
    // up on next launch.
    if (taskId != null) {
      _taskIdMap.remove(localPath);
      await LocalStorageService.instance.removeSyncTask(taskId);
    } else {
      // Fall back to scanning persistent storage by localPath in case the
      // taskIdMap was lost (e.g. restoreQueue race).
      final all = LocalStorageService.instance.getPendingSyncTasks();
      for (final t in all) {
        if (t.localPath == localPath) {
          await LocalStorageService.instance.removeSyncTask(t.id);
        }
      }
    }

    // Flip the SyncState so the file-row badge clears.
    final state = LocalStorageService.instance.getSyncState(localPath);
    if (state != null) {
      await LocalStorageService.instance.addSyncState(
        state.copyWith(status: SyncStatus.notSynced, errorMessage: null),
      );
      _notifyListeners(localPath, SyncStatus.notSynced);
      if (state.displayPath != null && state.displayPath != localPath) {
        _notifyListeners(state.displayPath!, SyncStatus.notSynced);
      }
    }

    // Free the batch progress slot. If the upload was in-flight, this means
    // the BatchUploadProgress widget no longer shows it; the underlying
    // Future will still resolve eventually and _executeUpload's
    // _cancelledLocalPaths check below will swallow the result.
    if (_activeSync.containsKey(localPath)) {
      UploadProgressManager.instance.failUpload(localPath);
      _activeSync.remove(localPath);
    }

    // Cross-isolate cancel relay (Android only). Everything above is
    // PER-ISOLATE: `_cancelledLocalPaths`, `_activeCancelHandles`, and
    // `_uploadQueue` are this isolate's in-memory state. If the upload
    // is being driven by the BG isolate (SyncForegroundService), it
    // has its own CancelHandle for the in-flight upload and the
    // Hive deletes alone aren't enough to stop chunks from landing.
    // Relay the signal through the native CrossIsolateRelay so the
    // BG isolate runs its own `cancelTask` locally (and triggers
    // its handle). Skip from the BG isolate itself — see role tag.
    if (Platform.isAndroid &&
        SyncNotificationService.isolateRole != 'background') {
      try {
        await _crossIsolateChannel.invokeMethod<bool>(
          'cancelTaskInBgIsolate',
          <String, dynamic>{'localPath': localPath},
        );
      } catch (e) {
        debugPrint('SyncService.cancelTask: cross-isolate relay failed: $e');
      }
    }
  }

  /// Channel that carries cancel signals from the main isolate to
  /// the BG isolate's `SyncService.instance.cancelTask`. Routed by
  /// `CrossIsolateRelay` on the Kotlin side.
  static const MethodChannel _crossIsolateChannel =
      MethodChannel('land.fx.files/sync_cross_isolate');

  /// Cancel every queued and in-progress upload. Convenience wrapper around
  /// [cancelTask] used by the "Cancel all" sync-queue action and the
  /// existing [clearAll] reset path.
  Future<void> cancelAllUploads() async {
    debugPrint('SyncService: cancelAllUploads');

    // Snapshot both the queue and the in-flight set; cancelTask mutates them.
    final paths = <String>{
      ..._uploadQueue.map((t) => t.localPath),
      ..._activeSync.keys,
    };

    for (final path in paths) {
      await cancelTask(path);
    }

    // Belt-and-braces: ensure the in-memory queue is empty even if a task
    // had no persistent row.
    _uploadQueue.clear();
    _downloadQueue.clear();

    // If a foreground service was running for this batch, tear it down
    // so the OS doesn't keep showing the notification.
    await handleAppForegrounded();
  }

  void addListener(SyncStatusCallback callback) {
    _listeners.add(callback);
  }
  
  void removeListener(SyncStatusCallback callback) {
    _listeners.remove(callback);
  }
  
  void _notifyListeners(String localPath, SyncStatus status) {
    for (final listener in List.of(_listeners)) {
      try {
        listener(localPath, status);
      } catch (e) {
        debugPrint('SyncService: listener error for $localPath: $e');
      }
    }
  }

  Future<void> queueUpload({
    required String localPath,
    required String remoteBucket,
    required String remoteKey,
    bool encrypt = true,
    String? displayPath, // Virtual path for iOS PhotoKit files (for UI lookup)
    String? iosAssetId, // iOS PhotoKit asset ID for stable identification
  }) async {
    // Check if already queued to avoid duplicates
    if (_taskIdMap.containsKey(localPath)) {
      return;
    }

    // If this path was previously cancelled, clear the flag so the new
    // upload completes normally.
    _cancelledLocalPaths.remove(localPath);

    // v8 migration: route new content uploads to the fresh `<base>-v8` bucket
    // (legacy buckets are gc-damaged and block writes). No-op while v8 is
    // disabled or for unmanaged buckets (shelf / metadata / custom / test).
    // Routed here — the one chokepoint every content upload funnels through —
    // so SyncState.bucket (which drives sync-status, share-target, and download
    // routing) reflects the real (v8) bucket.
    final routedBucket = BucketVersionResolver.writeBucket(remoteBucket);
    if (routedBucket != remoteBucket) {
      debugPrint(
        'SyncService: v8-routing upload $remoteBucket -> $routedBucket ($localPath)',
      );
    }

    final task = SyncTask(
      localPath: localPath,
      remoteBucket: routedBucket,
      remoteKey: remoteKey,
      direction: SyncDirection.upload,
      encrypt: encrypt,
    );

    _uploadQueue.add(task);

    // Persist task to database (fire-and-forget to avoid blocking UI)
    // The in-memory queue is the source of truth; persistence is for crash recovery
    if (!_isRestoring) {
      final persistentTask = persistent.SyncTask.upload(
        localPath: localPath,
        remoteBucket: routedBucket,
        remoteKey: remoteKey,
        encrypt: encrypt,
      );
      _taskIdMap[localPath] = persistentTask.id;
      // Don't await - let it write in background
      LocalStorageService.instance.addToSyncQueue(persistentTask);
    }

    final state = SyncState(
      localPath: localPath,
      remotePath: remoteKey,
      // Populate remoteKey too (not just remotePath): linked-key lookups and
      // the cloud-explorer matcher key off remoteKey, so leaving it null made
      // freshly-uploaded files (esp. in -v8 buckets) look "cloud only".
      remoteKey: remoteKey,
      bucket: routedBucket,
      status: SyncStatus.notSynced,
      displayPath: displayPath, // Store virtual path for iOS UI lookup
      iosAssetId: iosAssetId, // Store iOS asset ID for stable identification
    );
    // Don't await - let it write in background
    LocalStorageService.instance.addSyncState(state);

    // Auto-process the queue
    _processUploadQueueAsync();
  }

  /// Move a queued upload to the front of the queue so it uploads next.
  /// Returns true if the task was found and moved.
  bool prioritizeUpload(String localPath) {
    final index = _uploadQueue.indexWhere((t) => t.localPath == localPath);
    if (index <= 0) return false; // not found or already first
    final task = _uploadQueue.removeAt(index);
    _uploadQueue.insert(0, task);
    return true;
  }

  /// Debounced check: if a newly uploaded file falls under a folder with an
  /// active temporal share, update the server manifest after a short delay.
  /// Supports multiple folders concurrently — each prefix is tracked separately.
  void _checkFolderShareUpdate(String bucket, String remoteKey) {
    final lastSlash = remoteKey.lastIndexOf('/');
    if (lastSlash < 0) return; // top-level file, no folder
    final prefix = remoteKey.substring(0, lastSlash + 1);

    _pendingFolderShareUpdates[prefix] = bucket;

    // Debounce: wait 5s after last upload before updating manifests
    _folderShareUpdateTimer?.cancel();
    _folderShareUpdateTimer = Timer(const Duration(seconds: 5), () {
      final updates = Map<String, String>.from(_pendingFolderShareUpdates);
      _pendingFolderShareUpdates.clear();
      for (final entry in updates.entries) {
        debugPrint('[SyncService] Timer fired: updating folder share manifest for ${entry.value}/${entry.key}');
        SharingService.instance.updateFolderShareManifest(entry.value, entry.key).catchError((e, stack) {
          debugPrint('[SyncService] Folder share manifest update failed for ${entry.key}: $e\n$stack');
        });
      }
    });
  }

  /// Debounced check: schedule a manifest refresh for any active tag share
  /// that includes [tagId]. Called from [TaggingExtension] on tagFile/untagFile
  /// and from the upload-completion path when an upload's remoteKey turns up
  /// in a tag's file list (see [_checkUploadAgainstTagShares]).
  void checkTagShareUpdate(String tagId) {
    _pendingTagShareUpdates.add(tagId);
    _tagShareUpdateTimer?.cancel();
    _tagShareUpdateTimer = Timer(const Duration(seconds: 5), () {
      final ids = Set<String>.from(_pendingTagShareUpdates);
      _pendingTagShareUpdates.clear();
      for (final id in ids) {
        debugPrint('[SyncService] Timer fired: updating tag share manifest for $id');
        SharingService.instance.updateTagShareManifest(id).catchError((e, stack) {
          debugPrint('[SyncService] Tag share manifest update failed for $id: $e\n$stack');
        });
      }
    });
  }

  /// Called after a successful upload — checks whether the uploaded file
  /// belongs to any tag with an active temporal share, and schedules a
  /// manifest refresh for each such tag.
  Future<void> _checkUploadAgainstTagShares(String bucket, String remoteKey) async {
    try {
      final tagIds = await SharingService.instance.activeTagSharesContaining(
        bucket: bucket,
        remoteKey: remoteKey,
      );
      for (final id in tagIds) {
        checkTagShareUpdate(id);
      }
    } catch (e) {
      debugPrint('[SyncService] tag share check after upload failed: $e');
    }
  }

  void _processUploadQueueAsync() {
    if (_isProcessingUpload) return;
    _isProcessingUpload = true;
    // Prevent the OS from sleeping while uploads are running
    WakelockPlus.enable().catchError((_) {});
    processUploadQueue().whenComplete(() {
      _isProcessingUpload = false;
      // Release wakelock when queue is drained
      if (_uploadQueue.isEmpty) {
        WakelockPlus.disable().catchError((_) {});
      }
    });
  }

  Future<void> queueDownload({
    required String remoteBucket,
    required String remoteKey,
    required String localPath,
    bool decrypt = true,
  }) async {
    final task = SyncTask(
      localPath: localPath,
      remoteBucket: remoteBucket,
      remoteKey: remoteKey,
      direction: SyncDirection.download,
      encrypt: decrypt,
    );

    _downloadQueue.add(task);
  }

  Future<void> processUploadQueue() async {
    if (_uploadQueue.isEmpty) return;

    // Cross-isolate exclusion: the SyncForegroundService isolate may
    // also try to drain the same persistent queue. If both ran in
    // parallel each would generate its own DEK per upload → file
    // encrypted twice at two different storage_keys, leaving orphaned
    // cloud bytes. The lock now delegates to a Kotlin process-singleton
    // (`UploadOwnershipRegistry`) over MethodChannel — POSIX file locks
    // would have been per-process and so visible-but-useless to two
    // isolates inside one Android process. See `upload_queue_lock.dart`
    // for the why-stateless rationale. **Fail-closed on Android**: if
    // the native channel is unreachable, `tryAcquire` returns false and
    // we SKIP this pass rather than process anyway — the previous
    // fail-open behaviour silently reintroduced the exact race the
    // lock exists to prevent. Release on every exit path via the
    // try/finally below.
    if (!await _queueLock.tryAcquire()) {
      debugPrint(
        'SyncService.processUploadQueue: queue lock held by another '
        'isolate (likely SyncForegroundService) — skipping this pass',
      );
      return;
    }
    try {
      await _processUploadQueueLocked();
    } finally {
      await _queueLock.release();
    }
  }

  Future<void> _processUploadQueueLocked() async {
    if (_uploadQueue.isEmpty) return;

    // Track sync statistics for notification
    final totalToSync = _uploadQueue.length;
    int syncedCount = 0;

    // Calculate total bytes for progress tracking.
    // Iterate a snapshot copy to avoid ConcurrentModificationError when
    // fire-and-forget _queueBatch calls add to _uploadQueue during awaits.
    int totalBytes = 0;
    for (final task in _uploadQueue.toList()) {
      try {
        final file = File(task.localPath);
        if (await file.exists()) {
          totalBytes += await file.length();
        }
      } catch (e) {
        debugPrint('Error getting file size for ${task.localPath}: $e');
      }
    }

    // Start batch progress tracking. Skip if a batch is already active —
    // this happens on the retry/resume paths where processUploadQueue
    // re-enters after a pause or after a retryable failure put the task
    // back on the queue. Calling startBatch again would visibly reset
    // the ETA to 0 (the field log showed two "Starting batch of 1 files
    // (445.0 MB)" lines per single-file retry). Phase B's chunk-level
    // resume will let us track real bytes-uploaded across attempts; for
    // now this at least keeps the time-based ETA continuous.
    if (!UploadProgressManager.instance.hasBatch) {
      UploadProgressManager.instance.startBatch(
        totalFiles: totalToSync,
        totalBytes: totalBytes,
      );
    } else {
      debugPrint(
        'SyncService: continuing existing upload batch — not resetting ETA',
      );
    }

    // Show sync notification (required for foreground service)
    await SyncNotificationService.instance.showSyncNotification(
      title: 'Syncing files',
      body: 'Preparing to sync $totalToSync files...',
    );

    // Process uploads with pause and network checks
    while (_uploadQueue.isNotEmpty) {
      // Check if paused due to consecutive failures
      if (_isPaused) {
        debugPrint('Queue paused, waiting until $_pausedUntil');
        await SyncNotificationService.instance.hideSyncNotification();
        return;
      }

      // Check network before processing
      if (!await _hasNetworkConnection()) {
        debugPrint('No network, pausing sync');
        _pauseQueue(const Duration(seconds: 30));
        await SyncNotificationService.instance.hideSyncNotification();
        return;
      }

      // Check if we can start a new upload
      if (_activeUploads >= maxParallelUploads) {
        // Wait a bit and check again
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final task = _uploadQueue.removeAt(0);
      _activeUploads++;

      // Update notification with progress
      syncedCount++;
      await SyncNotificationService.instance.updateSyncProgress(
        current: syncedCount,
        total: totalToSync,
        currentFile: task.remoteKey.split('/').last,
      );

      // Throttle upload starts - wait at least 10ms between starts
      final timeSinceLastStart = DateTime.now().difference(_lastUploadStart);
      if (timeSinceLastStart.inMilliseconds < 10) {
        await Future.delayed(Duration(milliseconds: 10 - timeSinceLastStart.inMilliseconds));
      }
      _lastUploadStart = DateTime.now();

      // Start upload without awaiting - let it run in background.
      // _executeUpload swallows its own errors (retries + give-up
      // logic live inside it), so no .catchError needed here — the
      // batch counters in UploadProgressManager are the source of
      // truth for success/failure at completion time.
      _executeUpload(task).whenComplete(() {
        _activeUploads--;
      });

      // Yield to UI thread periodically
      await Future.delayed(const Duration(milliseconds: 10));
    }

    // Wait for all active uploads to complete
    while (_activeUploads > 0) {
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // Safety: if files were added during processing (from fire-and-forget batches),
    // restart processing instead of showing completion
    if (_uploadQueue.isNotEmpty) {
      _isProcessingUpload = false;
      _processUploadQueueAsync();
      return;
    }

    // Source truth from UploadProgressManager rather than local
    // `syncedCount` / `errorCount`. The local counters were
    // increment-before-dispatch (syncedCount++ before _executeUpload
    // ever ran) and errorCount-via-.catchError (never fired, because
    // _executeUpload swallows its own retry+give-up paths). Net
    // result: the old notification always said "Successfully synced N
    // files" even when N attempts had all failed. The batch manager
    // tracks the real outcome via completeUpload/failUpload calls.
    final batch = UploadProgressManager.instance.batchProgress;
    final completedFiles = batch?.completedFiles ?? 0;
    final failedFiles = batch?.failedFiles ?? 0;

    // Don't spam a "Sync complete" if nothing actually finished —
    // e.g. a foreground/background handover where this isolate
    // exited the loop because the other isolate took ownership, or
    // a batch consisting entirely of cancelled tasks.
    if (completedFiles == 0 && failedFiles == 0) {
      debugPrint(
        'SyncService: queue drained with zero completions/failures — '
        'suppressing complete notification',
      );
      return;
    }

    await SyncNotificationService.instance.showSyncCompleteNotification(
      fileCount: completedFiles,
      hasErrors: failedFiles > 0,
    );
  }

  /// Check if device has network connectivity suitable for sync
  /// Respects the wifiOnly setting from user preferences
  Future<bool> _hasNetworkConnection() async {
    try {
      final result = await Connectivity().checkConnectivity();

      // No connection at all
      if (result.contains(ConnectivityResult.none)) {
        return false;
      }

      // Check WiFi-only setting
      final wifiOnly = LocalStorageService.instance.getSetting<bool>('wifiOnly') ?? true;
      if (wifiOnly) {
        // Only allow sync on WiFi or Ethernet
        final hasWifi = result.contains(ConnectivityResult.wifi) ||
                        result.contains(ConnectivityResult.ethernet);
        if (!hasWifi) {
          debugPrint('Sync paused: WiFi-only mode enabled, current connection is mobile data');
          return false;
        }
      }

      return true;
    } catch (e) {
      debugPrint('Error checking connectivity: $e');
      return true; // Assume connected if check fails
    }
  }

  /// Pause the upload queue due to consecutive failures or no network.
  ///
  /// Persists [_pausedUntil] to SecureStorage so a force-kill mid-pause
  /// doesn't strand `_consecutiveFailures`. Caps max pause at 10 minutes so
  /// a stale persisted value can't keep the queue stuck forever.
  void _pauseQueue(Duration duration) {
    const maxPause = Duration(minutes: 10);
    final effective = duration > maxPause ? maxPause : duration;

    _isPaused = true;
    _pausedUntil = DateTime.now().add(effective);
    debugPrint('Sync queue paused for ${effective.inSeconds}s');

    // Fire-and-forget persist — don't block the caller on SecureStorage I/O.
    SecureStorageService.instance
        .write(SecureStorageKeys.syncPausedUntil, _pausedUntil!.toIso8601String())
        .catchError((e) => debugPrint('Failed to persist pausedUntil: $e'));

    Future.delayed(effective, _resumeQueue);
  }

  /// Clear pause state and resume processing.
  void _resumeQueue() {
    if (!_isPaused) return;
    _isPaused = false;
    _pausedUntil = null;
    _consecutiveFailures = 0;
    SecureStorageService.instance
        .delete(SecureStorageKeys.syncPausedUntil)
        .catchError((e) => debugPrint('Failed to clear pausedUntil: $e'));
    debugPrint('Sync queue resumed');
    _processUploadQueueAsync();
  }

  /// Restore pause state from SecureStorage. Called from [restoreQueue].
  Future<void> _restorePauseState() async {
    try {
      final iso = await SecureStorageService.instance
          .read(SecureStorageKeys.syncPausedUntil);
      if (iso == null || iso.isEmpty) return;

      final pausedUntil = DateTime.tryParse(iso);
      if (pausedUntil == null) {
        await SecureStorageService.instance
            .delete(SecureStorageKeys.syncPausedUntil);
        return;
      }

      final now = DateTime.now();
      const maxPause = Duration(minutes: 10);
      if (pausedUntil.isBefore(now) ||
          pausedUntil.difference(now) > maxPause) {
        // Expired or suspiciously far in the future — clear and move on.
        await SecureStorageService.instance
            .delete(SecureStorageKeys.syncPausedUntil);
        _consecutiveFailures = 0;
        return;
      }

      _isPaused = true;
      _pausedUntil = pausedUntil;
      final remaining = pausedUntil.difference(now);
      debugPrint('Sync queue resuming from persisted pause; '
          '${remaining.inSeconds}s remaining');
      Future.delayed(remaining, _resumeQueue);
    } catch (e) {
      debugPrint('Failed to restore pause state: $e');
    }
  }

  /// Calculate retry delay with exponential backoff
  Duration _calculateRetryDelay(int attempt) {
    // Exponential backoff: 2s, 4s, 8s, 16s, 32s (capped at 5min)
    final delay = initialRetryDelay * (1 << attempt);
    return delay > maxRetryDelay ? maxRetryDelay : delay;
  }

  /// Check if error is retryable (transient) vs permanent
  bool _isRetryableError(dynamic error) {
    final msg = error.toString().toLowerCase();

    // FIRST: Check for explicitly retryable network/connectivity errors
    // These should ALWAYS be retried regardless of other patterns in the message
    if (msg.contains('dns error') ||
        msg.contains('dns lookup') ||
        msg.contains('no address associated') ||
        msg.contains('name or service not known') ||
        msg.contains('connection refused') ||
        msg.contains('connection reset') ||
        msg.contains('connection closed') ||
        msg.contains('connection timed out') ||
        msg.contains('network is unreachable') ||
        msg.contains('network unreachable') ||
        msg.contains('host unreachable') ||
        msg.contains('no route to host') ||
        msg.contains('socket closed') ||
        msg.contains('socket exception') ||
        msg.contains('client error (connect)') ||
        msg.contains('error sending request') ||
        msg.contains('failed to lookup address') ||
        msg.contains('temporarily unavailable') ||
        msg.contains('service unavailable') ||
        msg.contains('bad gateway') ||
        msg.contains('gateway timeout') ||
        msg.contains('ssl handshake') ||
        msg.contains('certificate') ||
        msg.contains('broken pipe') ||
        msg.contains('eof') ||
        msg.contains('econnrefused') ||
        msg.contains('econnreset') ||
        msg.contains('etimedout') ||
        msg.contains('ehostunreach') ||
        msg.contains('enetunreach')) {
      return true;
    }

    // Permanent errors - don't retry
    // HTTP status codes (use word boundaries to avoid matching in URLs/IDs)
    if (RegExp(r'\b401\b').hasMatch(msg) ||  // Unauthorized
        RegExp(r'\b403\b').hasMatch(msg) ||  // Forbidden
        RegExp(r'\b404\b').hasMatch(msg) ||  // Not Found
        RegExp(r'\b409\b').hasMatch(msg) ||  // Conflict
        RegExp(r'\b410\b').hasMatch(msg) ||  // Gone
        RegExp(r'\b413\b').hasMatch(msg) ||  // Payload Too Large
        RegExp(r'\b422\b').hasMatch(msg)) {  // Unprocessable Entity
      return false;
    }

    // S3/MinIO specific errors
    if (msg.contains('accessdenied') ||
        msg.contains('access denied') ||
        msg.contains('unauthorized') ||
        msg.contains('forbidden') ||
        msg.contains('invalidaccesskeyid') ||
        msg.contains('signaturemismatch') ||
        msg.contains('signature does not match') ||
        msg.contains('nosuchkey') ||
        msg.contains('no such key') ||
        msg.contains('nosuchbucket') ||
        msg.contains('no such bucket') ||
        msg.contains('entitytoolarge') ||
        msg.contains('invalid key') ||
        msg.contains('file not found') ||
        msg.contains('accountproblem')) {  // Quota/billing issues
      return false;
    }

    // App-specific permanent errors
    if (msg.contains('insufficient credit') ||
        msg.contains('quota exceeded') ||
        msg.contains('storage limit') ||
        msg.contains('encryption key not available') ||
        msg.contains('account problem')) {
      return false;
    }

    // Caller-initiated cancellation (fula-api#18 cooperative cancel +
    // #21 typed FulaError::Cancelled). Belt-and-suspenders against the
    // default-true fallback at the bottom: the primary cancel-detection
    // path goes through `_cancelledLocalPaths.contains(task.localPath)`
    // in the catch block (which short-circuits before this function),
    // but any future SDK path that surfaces Cancelled without going
    // through `cancelTask` would otherwise hit the network/server
    // fallback and re-queue the upload. Match on the SDK's stable
    // `Display` string ("upload cancelled by caller", preserved across
    // the #21 typed-variant promotion) so this works for both pre-#21
    // and post-#21 SDK builds without a switch on the Dart variant.
    if (msg.contains('upload cancelled by caller') ||
        msg.contains('cancelled by caller')) {
      return false;
    }

    // Network/server errors (5xx, timeout, connection) - retry
    return true;
  }

  Future<void> processDownloadQueue() async {
    while (_downloadQueue.isNotEmpty) {
      final task = _downloadQueue.removeAt(0);
      await _executeDownload(task);
    }
  }

  Future<void> _executeUpload(SyncTask task) async {
    debugPrint('Starting upload: ${task.localPath} -> ${task.remoteBucket}/${task.remoteKey}');
    final uploadStartTime = DateTime.now();

    try {
      // Check network connectivity before attempting upload
      // This prevents wasting resources when app is backgrounded without network
      if (!await _hasNetworkConnection()) {
        debugPrint('No network for upload, re-queueing: ${task.remoteKey}');
        // Put task back in queue and pause
        _uploadQueue.insert(0, task);
        if (!_isPaused) {
          _pauseQueue(const Duration(seconds: 30));
        }
        return;
      }

      // Ensure FulaApiService is configured before upload
      if (!FulaApiService.instance.isConfigured) {
        debugPrint('SyncService: FulaApiService not configured, attempting to initialize...');
        await AuthService.instance.reinitializeFulaClient();
        if (!FulaApiService.instance.isConfigured) {
          throw FulaApiException('FulaApiService is not configured. Please sign in and configure your API key.');
        }
        debugPrint('SyncService: FulaApiService initialized successfully');
      }

      // Ensure bucket exists before upload
      await _ensureBucketExists(task.remoteBucket);

      final state = LocalStorageService.instance.getSyncState(task.localPath);
      if (state != null) {
        await LocalStorageService.instance.addSyncState(
          state.copyWith(status: SyncStatus.syncing),
        );
        _notifyListeners(task.localPath, SyncStatus.syncing);
        // Also notify by displayPath for iOS UI refresh
        if (state.displayPath != null && state.displayPath != task.localPath) {
          _notifyListeners(state.displayPath!, SyncStatus.syncing);
        }
      }

      _activeSync[task.localPath] = SyncProgress(
        localPath: task.localPath,
        remoteKey: task.remoteKey,
        direction: SyncDirection.upload,
        bytesTransferred: 0,
        totalBytes: 0,
      );

      // Get file size without reading the file into memory
      final fileSize = await File(task.localPath).length();

      _activeSync[task.localPath] = _activeSync[task.localPath]!.copyWith(
        totalBytes: fileSize,
      );

      // Start tracking this upload in progress manager
      UploadProgressManager.instance.startUpload(
        localPath: task.localPath,
        remoteKey: task.remoteKey,
        totalBytes: fileSize,
      );

      // Phase C: resumable upload via fula-api#17 + cancellable via #18.
      // Branch on whether the persistent SyncTask has a manifest path
      // pointing at a still-on-disk manifest file:
      //
      //   * manifestPath != null AND file exists → previous attempt
      //     failed mid-upload. Resume from the manifest; the SDK
      //     re-uploads only the chunks that didn't land last time.
      //   * Otherwise → first attempt or manifest was cleaned up.
      //     Generate a fresh manifest path under the app's documents
      //     directory and call the cancellable resumable upload.
      //
      // Either path uses a per-task CancelHandle so `cancelTask` can
      // abort the in-flight upload truly (fula-api#18). The handle goes
      // into `_activeCancelHandles[localPath]` for the cancel API; it's
      // cleaned up in every exit path below.
      //
      // Read (don't remove) the persistent task ID here — the existing
      // success path at the end of this try block does the removal.
      // Naming this `existingTaskId` to avoid shadowing the later
      // `final taskId = _taskIdMap.remove(...)`.
      final existingTaskId = _taskIdMap[task.localPath];
      final persistentTask = existingTaskId != null
          ? LocalStorageService.instance.getSyncTask(existingTaskId)
          : null;
      final manifestPath = persistentTask?.manifestPath
          ?? await _manifestPathFor(task);
      // Persist the manifest path on first use so subsequent retries
      // hit the resume branch.
      if (existingTaskId != null && persistentTask?.manifestPath == null) {
        await LocalStorageService.instance.updateSyncTask(
          persistentTask!.copyWith(manifestPath: manifestPath),
        );
      }
      // fula_client 0.6.1: createCancelHandle is async (FRB-generated
      // Dart binding returns Future<CancelHandle> because it dispatches
      // into the native lib).
      final cancelHandle = await FulaApiService.instance.createCancelHandle();
      _activeCancelHandles[task.localPath] = cancelHandle;

      // Pre-handle cancel race: a cancel signal (cross-isolate relay or
      // direct cancelTask call) could have landed between
      // `_uploadQueue.removeAt(0)` in the dispatch loop and the handle
      // registration above. In that window, `cancelTask` populated
      // `_cancelledLocalPaths` but found no handle to trigger; the
      // upload would otherwise proceed all the way through the SDK
      // call before honouring the cancel. Now that the handle exists,
      // trigger it eagerly so the SDK observes `Cancelled` at its
      // first chunk-boundary poll.
      if (_cancelledLocalPaths.contains(task.localPath)) {
        debugPrint(
          'Cancel arrived before handle registered for ${task.localPath} — '
          'triggering eagerly',
        );
        FulaApiService.instance.triggerCancel(cancelHandle);
      }

      String etag;
      try {
        final isResume = persistentTask?.manifestPath != null
            && await File(manifestPath).exists();
        if (isResume) {
          debugPrint(
            'Resuming upload: ${task.localPath} via manifest $manifestPath',
          );
          etag = await FulaApiService.instance.resumeLargeFileUpload(
            manifestPath,
            task.localPath,
            cancelHandle: cancelHandle,
            onProgress: (UploadProgress progress) {
              // Late-progress guard: cancelTask may have removed the
              // `_activeSync` entry concurrently. The SDK keeps firing
              // onProgress until it observes the cancel at its next
              // chunk boundary (up to MAX_CONCURRENT_CHUNK_UPLOADS in
              // flight). Without this guard the `!.copyWith` would
              // throw "Null check operator used on a null value" and
              // crash the BG isolate (or be swallowed by FRB).
              final current = _activeSync[task.localPath];
              if (current == null) return;
              _activeSync[task.localPath] = current.copyWith(
                bytesTransferred: progress.bytesUploaded,
              );
              // Real cumulative bytes -> UI progress manager (drives the %).
              UploadProgressManager.instance
                  .updateProgress(task.localPath, progress.bytesUploaded);
            },
          );
        } else {
          etag = await FulaApiService.instance.uploadLargeFileResumable(
            task.remoteBucket,
            task.remoteKey,
            task.localPath,
            manifestPath,
            cancelHandle: cancelHandle,
            onProgress: (UploadProgress progress) {
              final current = _activeSync[task.localPath];
              if (current == null) return;
              _activeSync[task.localPath] = current.copyWith(
                bytesTransferred: progress.bytesUploaded,
              );
              // Real cumulative bytes -> UI progress manager (drives the %).
              UploadProgressManager.instance
                  .updateProgress(task.localPath, progress.bytesUploaded);
            },
          );
        }
      } finally {
        // Whether success, error, or cancel — the in-flight handle is
        // no longer relevant. cancelTask checks for presence before
        // triggering, so removing here is safe.
        _activeCancelHandles.remove(task.localPath);

        // fula-api#20: drain any pending manifest abort cancelTask
        // queued while the upload was in flight. We're past the chunk-
        // PUT loop here, so the abort no longer races the upload's own
        // manifest writes. Idempotent + best-effort — a missing
        // manifest (SDK auto-deleted on clean completion) returns Ok.
        final pendingAbort = _pendingManifestAborts.remove(task.localPath);
        if (pendingAbort != null && pendingAbort.isNotEmpty) {
          debugPrint(
            'SyncService: draining abort for ${task.localPath} '
            '(manifest=$pendingAbort)',
          );
          unawaited(
            FulaApiService.instance.abortResumableUpload(pendingAbort),
          );
        }
      }

      // If cancelTask fired while we were awaiting the SDK, suppress success
      // bookkeeping. cancelTask flipped SyncState to notSynced and removed
      // the persistent row; we just need to make sure we don't re-write
      // synced over it. With Phase C's cancel handle, the in-flight upload
      // returns Err(Cancelled) before this branch fires — but the
      // suppression is still correct for the brief overlap window where
      // up to MAX_CONCURRENT_CHUNK_UPLOADS chunks finish post-cancel.
      if (_cancelledLocalPaths.contains(task.localPath)) {
        debugPrint('Upload completed after cancel: ${task.remoteKey} — suppressing success state');
        _cancelledLocalPaths.remove(task.localPath);
        _activeSync.remove(task.localPath);
        return;
      }

      debugPrint('Upload completed: ${task.remoteKey}, etag: $etag');

      // Record upload completion for speed tracking and progress
      final uploadDuration = DateTime.now().difference(uploadStartTime);
      UploadProgressManager.instance.completeUpload(
        localPath: task.localPath,
        actualDuration: uploadDuration,
      );

      // Reset consecutive failures on success
      _consecutiveFailures = 0;

      if (state != null) {
        await LocalStorageService.instance.addSyncState(
          state.copyWith(
            status: SyncStatus.synced,
            lastSyncedAt: DateTime.now(),
            etag: etag,
            localSize: fileSize,
          ),
        );
        _notifyListeners(task.localPath, SyncStatus.synced);
        // Also notify by displayPath for iOS UI refresh
        if (state.displayPath != null && state.displayPath != task.localPath) {
          _notifyListeners(state.displayPath!, SyncStatus.synced);
        }

        // Request storage refresh after upload (with 10s debounce)
        StorageRefreshService.instance.requestRefresh();

        // Store mapping for reinstall persistence (both iOS and Android)
        await CloudSyncMappingService.instance.addMapping(SyncMapping(
          iosAssetId: state.iosAssetId, // iOS only
          localPath: !Platform.isIOS ? task.localPath : null, // Android + Desktop
          remoteKey: task.remoteKey,
          bucket: task.remoteBucket,
          etag: etag,
          uploadedAt: DateTime.now(),
        ));

      }

      // Check if this file is under an active temporal folder share
      // (outside state block — always fires after successful upload)
      _checkFolderShareUpdate(task.remoteBucket, task.remoteKey);

      // Also check tag shares: the file may have been queued by tag-share
      // auto-upload, or it may have been independently tagged with a tag
      // that's currently shared.
      // ignore: discarded_futures
      _checkUploadAgainstTagShares(task.remoteBucket, task.remoteKey);

      // Remove completed task from persistent queue
      final taskId = _taskIdMap.remove(task.localPath);
      if (taskId != null) {
        await LocalStorageService.instance.removeSyncTask(taskId);
      }

      _activeSync.remove(task.localPath);
    } catch (e, stack) {
      debugPrint('Upload failed: $e');
      debugPrint('Stack: $stack');

      // If cancelTask fired while we were awaiting the SDK, the error here
      // is effectively the cancel taking effect (or a network failure that
      // happened to coincide). cancelTask already cleaned up; don't retry,
      // don't bump consecutive-failures, don't mark errored.
      if (_cancelledLocalPaths.contains(task.localPath)) {
        debugPrint('Upload failed after cancel: ${task.remoteKey} — suppressing retry');
        _cancelledLocalPaths.remove(task.localPath);
        _activeSync.remove(task.localPath);
        return;
      }

      // Track consecutive failures
      _consecutiveFailures++;

      // Get current retry count from persistent task
      final taskId = _taskIdMap[task.localPath];
      final persistentTask = taskId != null
          ? LocalStorageService.instance.getSyncTask(taskId)
          : null;
      final retryCount = persistentTask?.retryCount ?? 0;

      // Check if we should retry this error
      final shouldRetry = retryCount < maxRetryAttempts && _isRetryableError(e);

      if (shouldRetry) {
        // Calculate exponential backoff delay
        final delay = _calculateRetryDelay(retryCount);
        debugPrint('Will retry ${task.remoteKey} in ${delay.inSeconds}s (attempt ${retryCount + 1}/$maxRetryAttempts)');

        // Update state to show pending retry (not permanent error)
        final state = LocalStorageService.instance.getSyncState(task.localPath);
        if (state != null) {
          await LocalStorageService.instance.addSyncState(
            state.copyWith(
              status: SyncStatus.syncing, // Show as syncing (pending retry)
              errorMessage: 'Retry ${retryCount + 1}/$maxRetryAttempts in ${delay.inSeconds}s: ${e.toString()}',
            ),
          );
          _notifyListeners(task.localPath, SyncStatus.syncing);
          // Also notify by displayPath for iOS UI refresh
          if (state.displayPath != null && state.displayPath != task.localPath) {
            _notifyListeners(state.displayPath!, SyncStatus.syncing);
          }
        }

        // Update persistent task retry count
        if (persistentTask != null) {
          await LocalStorageService.instance.updateSyncTask(
            persistentTask.copyWith(
              status: persistent.SyncTaskStatus.pending,
              errorMessage: e.toString(),
              retryCount: retryCount + 1,
            ),
          );
        }

        // Schedule retry with exponential backoff
        Future.delayed(delay, () {
          if (!_isPaused &&
              !_cancelledBuckets.contains(task.remoteBucket) &&
              !_cancelledLocalPaths.contains(task.localPath)) {
            _uploadQueue.add(task);
            _processUploadQueueAsync();
          }
        });
      } else {
        // Max retries exceeded or permanent error - mark as failed
        debugPrint('Giving up on ${task.remoteKey} after $retryCount attempts (retryable: ${_isRetryableError(e)})');

        // Track failed upload in progress manager
        UploadProgressManager.instance.failUpload(task.localPath);

        // Create user-friendly error message
        final errorStr = e.toString().toLowerCase();
        String userMessage;
        if (errorStr.contains('accountproblem') || errorStr.contains('quota')) {
          userMessage = 'Storage quota exceeded. Please free up space or upgrade your plan.';
        } else if (errorStr.contains('accessdenied') || errorStr.contains('unauthorized')) {
          userMessage = 'Access denied. Please check your API key in Settings.';
        } else if (errorStr.contains('nosuchbucket')) {
          userMessage = 'Storage bucket not found. Please try again later.';
        } else {
          userMessage = e.toString();
        }

        final state = LocalStorageService.instance.getSyncState(task.localPath);
        if (state != null) {
          await LocalStorageService.instance.addSyncState(
            state.copyWith(
              status: SyncStatus.error,
              errorMessage: userMessage,
            ),
          );
          _notifyListeners(task.localPath, SyncStatus.error);
          // Also notify by displayPath for iOS UI refresh
          if (state.displayPath != null && state.displayPath != task.localPath) {
            _notifyListeners(state.displayPath!, SyncStatus.error);
          }
        }

        // Update persistent task status to permanently failed
        if (persistentTask != null) {
          await LocalStorageService.instance.updateSyncTask(
            persistentTask.copyWith(
              status: persistent.SyncTaskStatus.failed,
              errorMessage: e.toString(),
              retryCount: retryCount + 1,
            ),
          );
        }

        // Remove from task ID map since we're giving up
        _taskIdMap.remove(task.localPath);
      }

      // Pause queue on too many consecutive failures
      if (_consecutiveFailures >= maxConsecutiveFailures && !_isPaused) {
        debugPrint('Too many consecutive failures ($_consecutiveFailures), pausing queue');
        _pauseQueue(const Duration(minutes: 2));
      }

      _activeSync.remove(task.localPath);
    }
  }
  
  final Set<String> _verifiedBuckets = {};
  final Map<String, Future<void>> _bucketCreationInProgress = {};

  Future<void> _ensureBucketExists(String bucket) async {
    // Skip if we've already verified this bucket exists
    if (_verifiedBuckets.contains(bucket)) return;

    // If another upload is already creating this bucket, wait for it
    if (_bucketCreationInProgress.containsKey(bucket)) {
      await _bucketCreationInProgress[bucket];
      return;
    }

    // Start creation and track the future to prevent race condition
    final future = _createBucketIfNeeded(bucket);
    _bucketCreationInProgress[bucket] = future;

    try {
      await future;
      _verifiedBuckets.add(bucket);
    } finally {
      _bucketCreationInProgress.remove(bucket);
    }
  }

  Future<void> _createBucketIfNeeded(String bucket) async {
    try {
      final exists = await FulaApiService.instance.bucketExists(bucket);
      if (!exists) {
        debugPrint('Creating bucket: $bucket');
        await FulaApiService.instance.createBucket(bucket);
      }
    } catch (e) {
      // Ignore "bucket already exists" errors - they're fine
      final msg = e.toString().toLowerCase();
      if (msg.contains('already exists') ||
          msg.contains('bucketalreadyexists') ||
          msg.contains('bucketalreadyownedbyyou')) {
        debugPrint('Bucket $bucket already exists, continuing');
        return;
      }
      debugPrint('Error ensuring bucket exists: $e');
      rethrow;
    }
  }

  Future<void> _executeDownload(SyncTask task) async {
    try {
      // Ensure FulaApiService is configured before download
      if (!FulaApiService.instance.isConfigured) {
        debugPrint('SyncService: FulaApiService not configured, attempting to initialize...');
        await AuthService.instance.reinitializeFulaClient();
        if (!FulaApiService.instance.isConfigured) {
          throw FulaApiException('FulaApiService is not configured. Please sign in and configure your API key.');
        }
        debugPrint('SyncService: FulaApiService initialized successfully');
      }

      _activeSync[task.remoteKey] = SyncProgress(
        localPath: task.localPath,
        remoteKey: task.remoteKey,
        direction: SyncDirection.download,
        bytesTransferred: 0,
        totalBytes: 0,
      );

      Uint8List data;
      if (task.encrypt) {
        final encryptionKey = await AuthService.instance.getEncryptionKey();
        if (encryptionKey == null) {
          throw SyncException('Encryption key not available');
        }

        data = await FulaApiService.instance.downloadAndDecrypt(
          task.remoteBucket,
          task.remoteKey,
          encryptionKey,
        );
      } else {
        data = await FulaApiService.instance.downloadObject(
          task.remoteBucket,
          task.remoteKey,
        );
      }

      final file = File(task.localPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data);

      _activeSync.remove(task.remoteKey);
    } catch (e) {
      debugPrint('Download failed: $e');
      _activeSync.remove(task.remoteKey);
      rethrow;
    }
  }

  Future<void> retryFailed() async {
    final states = LocalStorageService.instance.getAllSyncStates();
    final failedStates = states.where((s) => s.status == SyncStatus.error).toList();

    for (final state in failedStates) {
      if (state.bucket != null && state.remotePath != null) {
        await queueUpload(
          localPath: state.localPath,
          remoteBucket: state.bucket!,
          remoteKey: state.remotePath!,
          displayPath: state.displayPath,
          iosAssetId: state.iosAssetId,
        );
      }
    }

    await processUploadQueue();
  }

  /// Legacy entrypoint kept for callers outside the sync-queue UI; delegates
  /// to [cancelAllUploads] so persistent state and SyncState badges stay in
  /// sync with the in-memory queue.
  Future<void> cancelAll() async {
    await cancelAllUploads();
  }

  Future<void> clearAll() async {
    // Phase C: trigger every in-flight cancel handle before tearing
    // state down. Otherwise pending Rust tasks would keep PUTting
    // chunks under a state we just wiped.
    for (final handle in _activeCancelHandles.values) {
      try {
        FulaApiService.instance.triggerCancel(handle);
      } catch (_) {
        // Cancel triggers are best-effort during clearAll.
      }
    }
    _activeCancelHandles.clear();

    _uploadQueue.clear();
    _downloadQueue.clear();
    _activeSync.clear();
    _verifiedBuckets.clear();
    _taskIdMap.clear();
    _cancelledLocalPaths.clear();
    _isProcessingUpload = false;
    _activeUploads = 0;
    await LocalStorageService.instance.clearAllSyncStates();
    await LocalStorageService.instance.clearSyncQueue();
  }

  /// Resume uploads if there are pending items in the queue.
  /// Called when the app returns from sleep/background.
  void resumeIfPending() {
    if (_uploadQueue.isNotEmpty && !_isProcessingUpload) {
      debugPrint('SyncService: Resuming ${_uploadQueue.length} pending uploads after wake');
      _processUploadQueueAsync();
    }
  }

  /// Called from `App.didChangeAppLifecycleState` when the app moves to
  /// the background. If there are pending uploads on Android, this asks
  /// MainActivity to bring up `SyncForegroundService` so the process is
  /// protected from kill (and a separate FlutterEngine drains the queue
  /// in case the activity dies). Coordinates with the service isolate
  /// via [UploadQueueLock] so only one isolate processes at a time.
  Future<void> handleAppBackgrounded() async {
    if (!Platform.isAndroid) return;
    if (_uploadQueue.isEmpty && _activeUploads == 0) {
      debugPrint('SyncService: app backgrounded with empty queue — skipping FG service');
      return;
    }
    if (_foregroundServiceRequested) return;
    debugPrint('SyncService: app backgrounded with pending uploads — starting FG service');
    try {
      await _syncForegroundChannel.invokeMethod<void>('startUploadService');
      _foregroundServiceRequested = true;
    } catch (e) {
      debugPrint('SyncService: startUploadService failed: $e');
    }
  }

  /// Called from `App.didChangeAppLifecycleState` when the app returns
  /// to the foreground. Tells the service to stop so the main isolate
  /// can take back the queue. Safe to call even if no service was
  /// started.
  Future<void> handleAppForegrounded() async {
    if (!Platform.isAndroid) return;
    if (!_foregroundServiceRequested) return;
    debugPrint('SyncService: app foregrounded — stopping FG service');
    try {
      await _syncForegroundChannel.invokeMethod<void>('stopUploadService');
    } catch (e) {
      debugPrint('SyncService: stopUploadService failed: $e');
    }
    _foregroundServiceRequested = false;
  }

  /// Restore pending tasks from persistent storage (call on app start)
  /// Uses batching and timeout to prevent blocking app startup
  Future<void> restoreQueue() async {
    if (_isRestoring) return;
    _isRestoring = true;

    try {
      await _restorePauseState();

      final pendingTasks = LocalStorageService.instance.getPendingSyncTasks();
      if (pendingTasks.isEmpty) {
        debugPrint('SyncService: No pending tasks to restore');
        _isRestoring = false;
        return;
      }

      debugPrint('SyncService: Restoring ${pendingTasks.length} pending tasks');

      // Process in batches with timeout to prevent blocking UI
      const batchSize = 50;
      const maxDuration = Duration(seconds: 5); // Don't block startup more than 5s
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < pendingTasks.length; i += batchSize) {
        // Check timeout - defer remaining to background if exceeded
        if (stopwatch.elapsed >= maxDuration) {
          debugPrint('SyncService: restoreQueue timeout reached, deferring remaining ${pendingTasks.length - i} tasks');
          final remainingTasks = pendingTasks.sublist(i);
          // Schedule deferred restoration via microtask (after UI renders)
          Future.microtask(() => _restoreRemainingTasks(remainingTasks));
          break;
        }

        final end = (i + batchSize < pendingTasks.length) ? i + batchSize : pendingTasks.length;
        final batch = pendingTasks.sublist(i, end);

        await _restoreBatch(batch);

        // Yield to UI thread between batches
        await Future.delayed(Duration.zero);
      }

      stopwatch.stop();
      debugPrint('SyncService: Restored ${_uploadQueue.length} tasks to queue in ${stopwatch.elapsedMilliseconds}ms');

      // Start processing if we have tasks
      if (_uploadQueue.isNotEmpty) {
        _processUploadQueueAsync();
      }
    } finally {
      _isRestoring = false;
    }
  }

  /// Process a batch of persistent tasks during queue restoration
  Future<void> _restoreBatch(List<persistent.SyncTask> batch) async {
    // Check file existence in parallel for the batch
    final existenceChecks = await Future.wait(
      batch.map((task) async {
        if (_taskIdMap.containsKey(task.localPath)) {
          return MapEntry(task, null); // Already in queue, skip
        }
        final file = File(task.localPath);
        final exists = await file.exists();
        return MapEntry(task, exists);
      }),
    );

    for (final entry in existenceChecks) {
      final persistentTask = entry.key;
      final exists = entry.value;

      if (exists == null) continue; // Already in queue

      if (!exists) {
        // File no longer exists, remove from queue (fire-and-forget)
        LocalStorageService.instance.removeSyncTask(persistentTask.id);
        continue;
      }

      // Add to in-memory queue.
      // Re-route UPLOAD tasks through the v8 resolver on restore: a task
      // persisted to a legacy managed bucket (e.g. `images`) before the flag
      // flipped would otherwise re-enter the queue as `images` and hit the
      // read-only-legacy write guard. writeBucket is a no-op when the flag is
      // off and idempotent on an already-v8 bucket. DOWNLOAD tasks keep their
      // original bucket — the file may genuinely live in legacy.
      final task = SyncTask(
        localPath: persistentTask.localPath,
        remoteBucket: persistentTask.isUpload
            ? BucketVersionResolver.writeBucket(persistentTask.remoteBucket)
            : persistentTask.remoteBucket,
        remoteKey: persistentTask.remoteKey,
        direction: persistentTask.isUpload ? SyncDirection.upload : SyncDirection.download,
        encrypt: persistentTask.encrypt,
      );

      _uploadQueue.add(task);
      _taskIdMap[persistentTask.localPath] = persistentTask.id;

      // Update persistent task status to pending if it was in_progress (fire-and-forget)
      if (persistentTask.status == persistent.SyncTaskStatus.inProgress) {
        LocalStorageService.instance.updateSyncTask(
          persistentTask.copyWith(status: persistent.SyncTaskStatus.pending),
        );
      }
    }
  }

  /// Restore remaining tasks in background (called when startup timeout is reached)
  Future<void> _restoreRemainingTasks(List<persistent.SyncTask> remainingTasks) async {
    debugPrint('SyncService: Restoring ${remainingTasks.length} deferred tasks in background');

    const batchSize = 50;
    for (int i = 0; i < remainingTasks.length; i += batchSize) {
      final end = (i + batchSize < remainingTasks.length) ? i + batchSize : remainingTasks.length;
      final batch = remainingTasks.sublist(i, end);

      await _restoreBatch(batch);

      // Yield to UI thread between batches
      await Future.delayed(const Duration(milliseconds: 10));
    }

    debugPrint('SyncService: Deferred restoration complete, total queue: ${_uploadQueue.length}');

    // Start processing if we have tasks and not already processing
    if (_uploadQueue.isNotEmpty && !_isProcessingUpload) {
      _processUploadQueueAsync();
    }
  }

  /// Process queue with a timeout (for background tasks with limited execution time)
  Future<void> processQueueWithTimeout(Duration timeout) async {
    if (_isProcessingUpload) return;
    // The background-isolate path also needs cross-isolate exclusion:
    // if the main isolate is still processing when this runs (e.g.,
    // WorkManager fired while the app was still alive), we'd race on
    // the persistent queue with separate Rust clients. See the longer
    // note in [processUploadQueue].
    if (!await _queueLock.tryAcquire()) {
      debugPrint(
        'SyncService.processQueueWithTimeout: queue lock contended — '
        'another isolate is already draining the queue. Skipping.',
      );
      return;
    }
    _isProcessingUpload = true;
    try {
      final stopwatch = Stopwatch()..start();

      debugPrint('SyncService: Processing queue with ${timeout.inMinutes}min timeout');

      while (_uploadQueue.isNotEmpty && stopwatch.elapsed < timeout) {
        // Check if we can start a new upload
        if (_activeUploads >= maxParallelUploads) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }

        final task = _uploadQueue.removeAt(0);
        _activeUploads++;

        // Start upload without awaiting
        _executeUpload(task).whenComplete(() {
          _activeUploads--;
        });

        // Small delay between starting uploads
        await Future.delayed(const Duration(milliseconds: 10));

        // Check remaining time
        final remainingTime = timeout - stopwatch.elapsed;
        if (remainingTime < const Duration(seconds: 30)) {
          debugPrint('SyncService: Less than 30s remaining, stopping new uploads');
          break;
        }
      }

      // Wait for active uploads to complete (up to remaining time)
      while (_activeUploads > 0 && stopwatch.elapsed < timeout) {
        await Future.delayed(const Duration(milliseconds: 200));
      }

      stopwatch.stop();
      debugPrint('SyncService: Timeout processing complete. '
          'Elapsed: ${stopwatch.elapsed.inSeconds}s, '
          'Remaining in queue: ${_uploadQueue.length}, '
          'Active: $_activeUploads');
    } finally {
      _isProcessingUpload = false;
      await _queueLock.release();
    }
  }

  /// Get count of pending tasks (in-memory + persistent)
  int get pendingTaskCount => _uploadQueue.length + _downloadQueue.length;
}

class SyncTask {
  final String localPath;
  final String remoteBucket;
  final String remoteKey;
  final SyncDirection direction;
  final bool encrypt;

  SyncTask({
    required this.localPath,
    required this.remoteBucket,
    required this.remoteKey,
    required this.direction,
    this.encrypt = true,
  });
}

class SyncProgress {
  final String localPath;
  final String remoteKey;
  final SyncDirection direction;
  final int bytesTransferred;
  final int totalBytes;

  SyncProgress({
    required this.localPath,
    required this.remoteKey,
    required this.direction,
    required this.bytesTransferred,
    required this.totalBytes,
  });

  double get percentage => totalBytes > 0 ? (bytesTransferred / totalBytes) * 100 : 0;

  SyncProgress copyWith({
    String? localPath,
    String? remoteKey,
    SyncDirection? direction,
    int? bytesTransferred,
    int? totalBytes,
  }) {
    return SyncProgress(
      localPath: localPath ?? this.localPath,
      remoteKey: remoteKey ?? this.remoteKey,
      direction: direction ?? this.direction,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      totalBytes: totalBytes ?? this.totalBytes,
    );
  }
}

class SyncException implements Exception {
  final String message;
  SyncException(this.message);

  @override
  String toString() => 'SyncException: $message';
}
