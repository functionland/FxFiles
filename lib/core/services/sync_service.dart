import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/models/sync_task.dart' as persistent;
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/storage_refresh_service.dart';

// Top-level function for isolate - reads file bytes
Future<Uint8List> _readFileInIsolate(String path) async {
  final file = File(path);
  return await file.readAsBytes();
}

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

    debugPrint('Cancelled ${toRemove.length} pending uploads for bucket: $bucket');
  }

  void addListener(SyncStatusCallback callback) {
    _listeners.add(callback);
  }
  
  void removeListener(SyncStatusCallback callback) {
    _listeners.remove(callback);
  }
  
  void _notifyListeners(String localPath, SyncStatus status) {
    for (final listener in _listeners) {
      listener(localPath, status);
    }
  }

  Future<void> queueUpload({
    required String localPath,
    required String remoteBucket,
    required String remoteKey,
    bool encrypt = true,
  }) async {
    // Check if already queued to avoid duplicates
    if (_taskIdMap.containsKey(localPath)) {
      return;
    }

    final task = SyncTask(
      localPath: localPath,
      remoteBucket: remoteBucket,
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
        remoteBucket: remoteBucket,
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
      bucket: remoteBucket,
      status: SyncStatus.notSynced,
    );
    // Don't await - let it write in background
    LocalStorageService.instance.addSyncState(state);

    // Auto-process the queue
    _processUploadQueueAsync();
  }
  
  void _processUploadQueueAsync() {
    if (_isProcessingUpload) return;
    _isProcessingUpload = true;
    processUploadQueue().whenComplete(() => _isProcessingUpload = false);
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
    // Process uploads with pause and network checks
    while (_uploadQueue.isNotEmpty) {
      // Check if paused due to consecutive failures
      if (_isPaused) {
        debugPrint('Queue paused, waiting until ${_pausedUntil}');
        return;
      }

      // Check network before processing
      if (!await _hasNetworkConnection()) {
        debugPrint('No network, pausing sync');
        _pauseQueue(const Duration(seconds: 30));
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

      // Throttle upload starts - wait at least 10ms between starts
      final timeSinceLastStart = DateTime.now().difference(_lastUploadStart);
      if (timeSinceLastStart.inMilliseconds < 10) {
        await Future.delayed(Duration(milliseconds: 10 - timeSinceLastStart.inMilliseconds));
      }
      _lastUploadStart = DateTime.now();

      // Start upload without awaiting - let it run in background
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
  }

  /// Check if device has network connectivity
  Future<bool> _hasNetworkConnection() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return !result.contains(ConnectivityResult.none);
    } catch (e) {
      debugPrint('Error checking connectivity: $e');
      return true; // Assume connected if check fails
    }
  }

  /// Pause the upload queue due to consecutive failures or no network
  void _pauseQueue(Duration duration) {
    _isPaused = true;
    _pausedUntil = DateTime.now().add(duration);
    debugPrint('Sync queue paused for ${duration.inSeconds}s');

    Future.delayed(duration, () {
      _isPaused = false;
      _pausedUntil = null;
      _consecutiveFailures = 0;
      debugPrint('Sync queue resumed');
      _processUploadQueueAsync();
    });
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

    // Permanent errors - don't retry
    // HTTP status codes
    if (msg.contains('401') ||  // Unauthorized
        msg.contains('403') ||  // Forbidden
        msg.contains('404') ||  // Not Found
        msg.contains('409') ||  // Conflict
        msg.contains('410') ||  // Gone
        msg.contains('413') ||  // Payload Too Large
        msg.contains('422')) {  // Unprocessable Entity
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
        msg.contains('file not found')) {
      return false;
    }

    // App-specific permanent errors
    if (msg.contains('insufficient credit') ||
        msg.contains('quota exceeded') ||
        msg.contains('storage limit') ||
        msg.contains('encryption key not available')) {
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
    try {
      // Ensure bucket exists before upload
      await _ensureBucketExists(task.remoteBucket);
      
      final state = LocalStorageService.instance.getSyncState(task.localPath);
      if (state != null) {
        await LocalStorageService.instance.addSyncState(
          state.copyWith(status: SyncStatus.syncing),
        );
        _notifyListeners(task.localPath, SyncStatus.syncing);
      }

      _activeSync[task.localPath] = SyncProgress(
        localPath: task.localPath,
        remoteKey: task.remoteKey,
        direction: SyncDirection.upload,
        bytesTransferred: 0,
        totalBytes: 0,
      );

      // Read file in isolate to avoid blocking UI thread
      final data = await compute(_readFileInIsolate, task.localPath);
      
      _activeSync[task.localPath] = _activeSync[task.localPath]!.copyWith(
        totalBytes: data.length,
      );

      String etag;
      if (task.encrypt) {
        final encryptionKey = await AuthService.instance.getEncryptionKey();
        if (encryptionKey == null) {
          throw SyncException('Encryption key not available');
        }

        etag = await FulaApiService.instance.encryptAndUploadLargeFile(
          task.remoteBucket,
          task.remoteKey,
          data,
          encryptionKey,
          originalFilename: task.localPath.split('/').last,
          onProgress: (UploadProgress progress) {
            _activeSync[task.localPath] = _activeSync[task.localPath]!.copyWith(
              bytesTransferred: progress.bytesUploaded,
            );
          },
        );
      } else {
        etag = await FulaApiService.instance.uploadLargeFile(
          task.remoteBucket,
          task.remoteKey,
          data,
          onProgress: (UploadProgress progress) {
            _activeSync[task.localPath] = _activeSync[task.localPath]!.copyWith(
              bytesTransferred: progress.bytesUploaded,
            );
          },
        );
      }

      debugPrint('Upload completed: ${task.remoteKey}, etag: $etag');

      // Reset consecutive failures on success
      _consecutiveFailures = 0;

      if (state != null) {
        await LocalStorageService.instance.addSyncState(
          state.copyWith(
            status: SyncStatus.synced,
            lastSyncedAt: DateTime.now(),
            etag: etag,
            localSize: data.length,
          ),
        );
        _notifyListeners(task.localPath, SyncStatus.synced);

        // Request storage refresh after upload (with 10s debounce)
        StorageRefreshService.instance.requestRefresh();
      }

      // Remove completed task from persistent queue
      final taskId = _taskIdMap.remove(task.localPath);
      if (taskId != null) {
        await LocalStorageService.instance.removeSyncTask(taskId);
      }

      _activeSync.remove(task.localPath);
    } catch (e, stack) {
      debugPrint('Upload failed: $e');
      debugPrint('Stack: $stack');

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
          if (!_isPaused) {
            _uploadQueue.add(task);
            _processUploadQueueAsync();
          }
        });
      } else {
        // Max retries exceeded or permanent error - mark as failed
        debugPrint('Giving up on ${task.remoteKey} after $retryCount attempts (retryable: ${_isRetryableError(e)})');

        final state = LocalStorageService.instance.getSyncState(task.localPath);
        if (state != null) {
          await LocalStorageService.instance.addSyncState(
            state.copyWith(
              status: SyncStatus.error,
              errorMessage: e.toString(),
            ),
          );
          _notifyListeners(task.localPath, SyncStatus.error);
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
        );
      }
    }

    await processUploadQueue();
  }

  Future<void> cancelAll() async {
    _uploadQueue.clear();
    _downloadQueue.clear();
  }

  Future<void> clearAll() async {
    _uploadQueue.clear();
    _downloadQueue.clear();
    _activeSync.clear();
    _verifiedBuckets.clear();
    _taskIdMap.clear();
    _isProcessingUpload = false;
    _activeUploads = 0;
    await LocalStorageService.instance.clearAllSyncStates();
    await LocalStorageService.instance.clearSyncQueue();
  }

  /// Restore pending tasks from persistent storage (call on app start)
  Future<void> restoreQueue() async {
    if (_isRestoring) return;
    _isRestoring = true;

    try {
      final pendingTasks = LocalStorageService.instance.getPendingSyncTasks();
      if (pendingTasks.isEmpty) {
        debugPrint('SyncService: No pending tasks to restore');
        _isRestoring = false;
        return;
      }

      debugPrint('SyncService: Restoring ${pendingTasks.length} pending tasks');

      for (final persistentTask in pendingTasks) {
        // Skip if already in queue
        if (_taskIdMap.containsKey(persistentTask.localPath)) continue;

        // Check if file still exists
        final file = File(persistentTask.localPath);
        if (!await file.exists()) {
          // File no longer exists, remove from queue
          await LocalStorageService.instance.removeSyncTask(persistentTask.id);
          continue;
        }

        // Add to in-memory queue
        final task = SyncTask(
          localPath: persistentTask.localPath,
          remoteBucket: persistentTask.remoteBucket,
          remoteKey: persistentTask.remoteKey,
          direction: persistentTask.isUpload ? SyncDirection.upload : SyncDirection.download,
          encrypt: persistentTask.encrypt,
        );

        _uploadQueue.add(task);
        _taskIdMap[persistentTask.localPath] = persistentTask.id;

        // Update persistent task status to pending (in case it was in_progress)
        if (persistentTask.status == persistent.SyncTaskStatus.inProgress) {
          await LocalStorageService.instance.updateSyncTask(
            persistentTask.copyWith(status: persistent.SyncTaskStatus.pending),
          );
        }
      }

      debugPrint('SyncService: Restored ${_uploadQueue.length} tasks to queue');

      // Start processing if we have tasks
      if (_uploadQueue.isNotEmpty) {
        _processUploadQueueAsync();
      }
    } finally {
      _isRestoring = false;
    }
  }

  /// Process queue with a timeout (for background tasks with limited execution time)
  Future<void> processQueueWithTimeout(Duration timeout) async {
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
