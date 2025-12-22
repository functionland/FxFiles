import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

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

  List<SyncTask> get uploadQueue => List.unmodifiable(_uploadQueue);
  List<SyncTask> get downloadQueue => List.unmodifiable(_downloadQueue);
  Map<String, SyncProgress> get activeSync => Map.unmodifiable(_activeSync);

  bool _isProcessingUpload = false;
  
  // Parallel upload configuration - reduced to prevent UI blocking
  static const int maxParallelUploads = 2;
  int _activeUploads = 0;
  
  // Throttle upload starts to prevent overwhelming the system
  DateTime _lastUploadStart = DateTime.now();
  
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
    final task = SyncTask(
      localPath: localPath,
      remoteBucket: remoteBucket,
      remoteKey: remoteKey,
      direction: SyncDirection.upload,
      encrypt: encrypt,
    );

    _uploadQueue.add(task);

    final state = SyncState(
      localPath: localPath,
      remotePath: remoteKey,
      bucket: remoteBucket,
      status: SyncStatus.notSynced,
    );
    await LocalStorageService.instance.addSyncState(state);
    _notifyListeners(localPath, SyncStatus.notSynced);
    
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
    // Process uploads sequentially with delays to keep UI responsive
    while (_uploadQueue.isNotEmpty) {
      // Check if we can start a new upload
      if (_activeUploads >= maxParallelUploads) {
        // Wait a bit and check again
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      
      final task = _uploadQueue.removeAt(0);
      _activeUploads++;
      
      // Throttle upload starts - wait at least 100ms between starts
      final timeSinceLastStart = DateTime.now().difference(_lastUploadStart);
      if (timeSinceLastStart.inMilliseconds < 100) {
        await Future.delayed(Duration(milliseconds: 100 - timeSinceLastStart.inMilliseconds));
      }
      _lastUploadStart = DateTime.now();
      
      // Start upload without awaiting - let it run in background
      _executeUpload(task).whenComplete(() {
        _activeUploads--;
      });
      
      // Yield to UI thread periodically
      await Future.delayed(const Duration(milliseconds: 50));
    }
    
    // Wait for all active uploads to complete
    while (_activeUploads > 0) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
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
      }

      _activeSync.remove(task.localPath);
    } catch (e, stack) {
      debugPrint('Upload failed: $e');
      debugPrint('Stack: $stack');
      
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

      _activeSync.remove(task.localPath);
      rethrow;
    }
  }
  
  final Set<String> _verifiedBuckets = {};
  
  Future<void> _ensureBucketExists(String bucket) async {
    // Skip if we've already verified this bucket exists
    if (_verifiedBuckets.contains(bucket)) return;
    
    try {
      final exists = await FulaApiService.instance.bucketExists(bucket);
      if (!exists) {
        debugPrint('Creating bucket: $bucket');
        await FulaApiService.instance.createBucket(bucket);
      }
      _verifiedBuckets.add(bucket);
    } catch (e) {
      debugPrint('Error ensuring bucket exists: $e');
      // If bucket already exists, that's fine
      if (e.toString().contains('BucketAlreadyExists') || 
          e.toString().contains('BucketAlreadyOwnedByYou')) {
        _verifiedBuckets.add(bucket);
        return;
      }
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
    _isProcessingUpload = false;
    _activeUploads = 0;
    await LocalStorageService.instance.clearAllSyncStates();
  }
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
