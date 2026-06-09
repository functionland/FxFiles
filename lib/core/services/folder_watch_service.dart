import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fula_files/core/models/folder_sync.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/services/media_service.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

const String folderSyncTaskName = 'com.functionland.fxfiles.folderSync';
const String folderSyncPeriodicTaskName = 'com.functionland.fxfiles.folderSyncPeriodic';

typedef FolderSyncCallback = void Function(String path, FolderSyncStatus status);

class FolderWatchService {
  FolderWatchService._();
  static final FolderWatchService instance = FolderWatchService._();

  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
  final List<FolderSyncCallback> _listeners = [];
  bool _isInitialized = false;

  // Track cancelled syncs to prevent queuing after disable
  final Set<String> _cancelledSyncs = {};

  // Track active sync listeners for cleanup in dispose()
  final Set<SyncStatusCallback> _activeSyncListeners = {};

  // Cloud sync for folder configs
  static const String _metadataBucket = 'fula-metadata';

  /// The bucket folder-sync configs are WRITTEN to: `fula-metadata-v8` once the
  /// shared bucket is v8-managed (the legacy forest is gc-damaged), else
  /// `fula-metadata`. Reads MERGE both via `downloadMetadataMerged`. No-op
  /// until `fula-metadata` joins the managed set.
  String get _writeBucket =>
      BucketVersionResolver.writeBucket(_metadataBucket);

  bool _cloudSyncScheduled = false;
  static const _cloudSyncDebounce = Duration(seconds: 5);

  // Parallel upload configuration
  static const int maxParallelUploads = 4;
  int _activeUploads = 0;
  final List<_PendingUpload> _pendingUploads = [];

  void addListener(FolderSyncCallback callback) {
    _listeners.add(callback);
  }

  void removeListener(FolderSyncCallback callback) {
    _listeners.remove(callback);
  }

  void _notifyListeners(String path, FolderSyncStatus status) {
    for (final listener in List.of(_listeners)) {
      try {
        listener(path, status);
      } catch (e) {
        debugPrint('FolderWatchService: listener error for $path: $e');
      }
    }
  }

  Future<void> init() async {
    if (_isInitialized) return;

    // Workmanager is initialised by BackgroundSyncService — DO NOT
    // call `Workmanager().initialize` again here. Workmanager supports
    // only one callback dispatcher per process; a second initialize()
    // overrode the main one and silently broke every task that wasn't
    // a folder-sync (model download, upload, periodic sync, etc.) —
    // they fired but ran the folder-sync code path instead of their
    // own logic. The `folderSyncTaskName` case now lives in
    // background_sync_service.dart's switch alongside everything else.

    // Start watching all enabled folder syncs
    final enabledSyncs = LocalStorageService.instance.getEnabledFolderSyncs();
    for (final sync in enabledSyncs) {
      await _startWatching(sync.path);
    }
    
    _isInitialized = true;
    debugPrint('FolderWatchService initialized with ${enabledSyncs.length} watched folders');
  }

  /// Called when app returns to foreground. Restarts watchers and
  /// scans for files that may have been missed while backgrounded.
  Future<void> onAppResumed() async {
    if (!_isInitialized) return;

    final enabledSyncs = LocalStorageService.instance.getEnabledFolderSyncs();
    if (enabledSyncs.isEmpty) return;

    debugPrint('FolderWatchService: onAppResumed - checking ${enabledSyncs.length} folders');

    for (final sync in enabledSyncs) {
      // Restart watcher (cancel stale, start fresh)
      await _stopWatching(sync.path);
      await _startWatching(sync.path);

      // Lightweight re-scan: only queue files modified since last sync
      if (sync.path.startsWith('category:')) {
        // Category syncs re-trigger full sync (skips already-synced files)
        syncFolder(sync.path);
      } else {
        _scanForNewFiles(sync.path, sync.lastSyncedAt);
      }
    }
  }

  /// Scan a directory for files modified after the given timestamp.
  /// Queues any new/modified files that haven't been synced yet.
  Future<void> _scanForNewFiles(String path, DateTime? since) async {
    final dir = Directory(path);
    if (!await dir.exists()) return;

    final threshold = since ?? DateTime.fromMillisecondsSinceEpoch(0);

    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)
          .handleError((error) {
        debugPrint('Resume scan error in $path: $error');
      })) {
        if (entity is! File) continue;

        try {
          final stat = await entity.stat();
          if (stat.modified.isAfter(threshold)) {
            final syncState = LocalStorageService.instance.getSyncState(entity.path);
            if (syncState?.isSynced != true) {
              _queueFileUpload(path, entity.path);
            }
          }
        } catch (e) {
          debugPrint('Error statting file during resume scan: $e');
        }
      }
    } catch (e) {
      debugPrint('Resume scan failed for $path: $e');
    }
  }

  Future<void> enableFolderSync({
    required String path,
    required String targetBucket,
    String? categoryName,
    bool isCategory = false,
  }) async {
    // Clear from cancelled set if re-enabling
    _cancelledSyncs.remove(path);
    SyncService.instance.clearCancelledBucket(targetBucket);

    // Check if user is authenticated
    if (!AuthService.instance.isAuthenticated) {
      throw Exception('User must be signed in to enable folder sync');
    }

    // Create folder sync entry
    final folderSync = FolderSync(
      path: path,
      categoryName: categoryName,
      targetBucket: targetBucket,
      status: FolderSyncStatus.enabled,
      isCategory: isCategory,
    );
    
    await LocalStorageService.instance.addFolderSync(folderSync);
    _notifyListeners(path, FolderSyncStatus.enabled);
    
    // Start watching
    await _startWatching(path);

    // Register periodic background task
    await _registerPeriodicSync();

    debugPrint('Enabled folder sync for: $path');
    _scheduleSyncToCloud();

    // Trigger initial sync - DON'T AWAIT, let it run in background
    // This returns control to UI immediately while sync happens async
    syncFolder(path);
  }

  Future<void> disableFolderSync(String path) async {
    // Mark as cancelled FIRST to stop any ongoing sync operations
    _cancelledSyncs.add(path);

    // Get the folder sync info to find target bucket
    final folderSync = LocalStorageService.instance.getFolderSync(path);

    // Stop watching
    await _stopWatching(path);

    // Cancel any pending uploads for this folder's bucket
    if (folderSync != null) {
      await SyncService.instance.cancelUploadsForBucket(folderSync.targetBucket);
    }

    // Update status
    await LocalStorageService.instance.updateFolderSyncStatus(
      path,
      FolderSyncStatus.disabled,
    );
    _notifyListeners(path, FolderSyncStatus.disabled);

    debugPrint('Disabled folder sync for: $path');
    _scheduleSyncToCloud();
  }

  Future<void> _startWatching(String path) async {
    if (_watchers.containsKey(path)) return;

    // Category paths (e.g., "category:images") are not real directories
    // They use MediaService/FileService to get files, so no watching needed
    if (path.startsWith('category:')) {
      debugPrint('Skipping directory watch for category path: $path');
      return;
    }

    // iOS restriction: Can only watch directories within app sandbox
    if (Platform.isIOS) {
      final appDocDir = await getApplicationDocumentsDirectory();
      if (!path.startsWith(appDocDir.path)) {
        debugPrint('iOS: Cannot watch external directory: $path (outside app sandbox)');
        return;
      }
    }

    final dir = Directory(path);
    if (!await dir.exists()) {
      debugPrint('Cannot watch non-existent directory: $path');
      return;
    }

    try {
      final watcher = dir.watch(events: FileSystemEvent.all, recursive: true);
      _watchers[path] = watcher.listen((event) {
        _handleFileSystemEvent(path, event);
      });
      debugPrint('Started watching: $path');
    } catch (e) {
      debugPrint('Failed to start watching $path: $e');
    }
  }

  Future<void> _stopWatching(String path) async {
    final subscription = _watchers.remove(path);
    await subscription?.cancel();
    debugPrint('Stopped watching: $path');
  }

  void _handleFileSystemEvent(String folderPath, FileSystemEvent event) {
    if (event is FileSystemCreateEvent || event is FileSystemModifyEvent) {
      final file = File(event.path);
      if (file.existsSync() && !FileSystemEntity.isDirectorySync(event.path)) {
        debugPrint('File changed in watched folder: ${event.path}');
        _queueFileUpload(folderPath, event.path);
      }
    } else if (event is FileSystemMoveEvent) {
      // File was renamed or moved within the watched directory
      final destination = event.destination;
      if (destination != null) {
        final file = File(destination);
        if (file.existsSync() && !FileSystemEntity.isDirectorySync(destination)) {
          debugPrint('File moved/renamed in watched folder: ${event.path} -> $destination');
          _queueFileUpload(folderPath, destination);
        }
      }
    }
  }

  /// Strip trailing path separator to avoid off-by-one in substring calculations.
  String _normalizePath(String path) {
    if (path.endsWith(Platform.pathSeparator)) {
      return path.substring(0, path.length - 1);
    }
    if (Platform.isWindows && path.endsWith('/')) {
      return path.substring(0, path.length - 1);
    }
    return path;
  }

  void _queueFileUpload(String folderPath, String filePath) {
    final pending = _PendingUpload(folderPath: folderPath, filePath: filePath);
    _pendingUploads.add(pending);
    _processUploadQueue();
  }

  void _processUploadQueue() {
    while (_activeUploads < maxParallelUploads && _pendingUploads.isNotEmpty) {
      final pending = _pendingUploads.removeAt(0);
      _activeUploads++;
      _uploadFile(pending).whenComplete(() {
        _activeUploads--;
        _processUploadQueue();
      });
    }
  }

  Future<void> _uploadFile(_PendingUpload pending) async {
    try {
      final folderSync = LocalStorageService.instance.getFolderSync(pending.folderPath);
      if (folderSync == null || !folderSync.isEnabled) return;
      
      final file = File(pending.filePath);
      if (!await file.exists()) return;
      
      // Calculate remote key
      final normalizedFolder = _normalizePath(pending.folderPath);
      final relativePath = pending.filePath.substring(normalizedFolder.length + 1);
      final folderName = normalizedFolder.split(Platform.pathSeparator).last;
      final remoteKey = folderSync.isCategory 
          ? relativePath.replaceAll('\\', '/')
          : '$folderName/$relativePath'.replaceAll('\\', '/');
      
      // Determine bucket
      final bucket = folderSync.targetBucket;
      
      await SyncService.instance.queueUpload(
        localPath: pending.filePath,
        remoteBucket: bucket,
        remoteKey: remoteKey,
      );
      
      debugPrint('Queued auto-upload: ${pending.filePath} -> $bucket/$remoteKey');
    } catch (e) {
      debugPrint('Auto-upload failed for ${pending.filePath}: $e');
    }
  }

  /// Queue a batch of files individually so one failure doesn't lose the rest.
  Future<void> _queueBatch(List<_FileQueueItem> batch) async {
    for (final item in batch) {
      try {
        await SyncService.instance.queueUpload(
          localPath: item.localPath,
          remoteBucket: item.bucket,
          remoteKey: item.remoteKey,
        );
      } catch (e) {
        debugPrint('Failed to queue ${item.localPath}: $e');
      }
    }
  }

  Future<void> syncFolder(String path) async {
    // Check if sync was cancelled before starting
    if (_cancelledSyncs.contains(path)) {
      debugPrint('Sync cancelled for $path, skipping');
      return;
    }

    final folderSync = LocalStorageService.instance.getFolderSync(path);
    if (folderSync == null) return;

    // Update status to syncing
    await LocalStorageService.instance.updateFolderSyncStatus(
      path,
      FolderSyncStatus.syncing,
    );
    _notifyListeners(path, FolderSyncStatus.syncing);

    try {
      // Handle category-based sync (e.g., "category:images")
      if (path.startsWith('category:')) {
        await _syncCategory(path, folderSync);
        return;
      }

      // Regular directory sync
      final dir = Directory(path);
      if (!await dir.exists()) {
        throw Exception('Directory does not exist: $path');
      }

      final normalizedPath = _normalizePath(path);
      final folderName = normalizedPath.split(Platform.pathSeparator).last;
      int syncedCount = 0;
      int totalFiles = 0;
      const batchSize = 25;
      final toQueue = <_FileQueueItem>[];

      // Collect files using stream (yields between iterations).
      // .handleError catches per-directory errors (e.g., permission denied on
      // a subdirectory) and lets the stream continue with remaining entries.
      int scanErrors = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)
          .handleError((error, stackTrace) {
        scanErrors++;
        debugPrint('Error scanning path during folder sync: $error');
      })) {
        // Check if cancelled during file collection
        if (_cancelledSyncs.contains(path)) {
          debugPrint('Sync cancelled during file scan for $path');
          return;
        }

        if (entity is! File) continue;

        totalFiles++;
        final file = entity;

        // Check if already synced (Hive sync read is fast)
        final syncState = LocalStorageService.instance.getSyncState(file.path);
        if (syncState?.isSynced == true) {
          syncedCount++;
          continue;
        }

        // Calculate remote key
        final relativePath = file.path.substring(normalizedPath.length + 1);
        final remoteKey = folderSync.isCategory
            ? relativePath.replaceAll('\\', '/')
            : '$folderName/$relativePath'.replaceAll('\\', '/');

        // Determine bucket based on file type for categories, or use target bucket
        final bucket = folderSync.isCategory
            ? FileCategory.fromPath(file.path).bucketName
            : folderSync.targetBucket;

        toQueue.add(_FileQueueItem(file.path, bucket, remoteKey));
      }

      final filesToSync = toQueue.length;

      // Update total count
      await LocalStorageService.instance.updateFolderSyncStatus(
        path,
        FolderSyncStatus.syncing,
        totalFiles: totalFiles,
        syncedFiles: syncedCount,
      );

      // Register listener BEFORE queueing so no completions are missed.
      // Dart's single-threaded event loop guarantees the listener is in place
      // before any completion callback can fire.
      if (filesToSync > 0) {
        int completedCount = 0;
        int failedCount = 0;
        late final SyncStatusCallback syncListener;
        syncListener = (localPath, status) {
          if (_cancelledSyncs.contains(path)) {
            SyncService.instance.removeListener(syncListener);
            _activeSyncListeners.remove(syncListener);
            return;
          }

          if (!localPath.startsWith(path)) return;

          if (status == SyncStatus.synced) {
            completedCount++;
            syncedCount++;
          } else if (status == SyncStatus.error) {
            failedCount++;
          } else {
            return;
          }

          LocalStorageService.instance.updateFolderSyncStatus(
            path,
            FolderSyncStatus.syncing,
            syncedFiles: syncedCount,
          );

          if (completedCount + failedCount >= filesToSync) {
            final finalStatus = failedCount > 0
                ? FolderSyncStatus.error
                : FolderSyncStatus.synced;
            final errorMsg = failedCount > 0
                ? '$failedCount file(s) failed to sync'
                : null;
            LocalStorageService.instance.updateFolderSyncStatus(
              path,
              finalStatus,
              syncedFiles: syncedCount,
              errorMessage: errorMsg,
            );
            _notifyListeners(path, finalStatus);
            SyncService.instance.removeListener(syncListener);
            _activeSyncListeners.remove(syncListener);
          }
        };
        SyncService.instance.addListener(syncListener);
        _activeSyncListeners.add(syncListener);
      }

      // Queue all files in small batches without blocking UI
      for (int i = 0; i < toQueue.length; i += batchSize) {
        if (_cancelledSyncs.contains(path)) {
          debugPrint('Sync cancelled during queue for $path');
          return;
        }

        final end = (i + batchSize < toQueue.length) ? i + batchSize : toQueue.length;
        final batch = toQueue.sublist(i, end);

        try {
          await _queueBatch(batch);
        } catch (e) {
          debugPrint('Error queuing batch for $path: $e');
        }

        await Future.delayed(Duration.zero);
      }

      if (filesToSync == 0) {
        // All files already synced — mark complete immediately
        await LocalStorageService.instance.updateFolderSyncStatus(
          path,
          FolderSyncStatus.synced,
          syncedFiles: syncedCount,
        );
        _notifyListeners(path, FolderSyncStatus.synced);
      }

      debugPrint('Folder sync scan for $path: $totalFiles files found, '
          '$syncedCount already synced, $filesToSync to queue, '
          '$scanErrors scan errors');
      
    } catch (e) {
      debugPrint('Folder sync failed for $path: $e');
      await LocalStorageService.instance.updateFolderSyncStatus(
        path,
        FolderSyncStatus.error,
        errorMessage: e.toString(),
      );
      _notifyListeners(path, FolderSyncStatus.error);
    }
  }
  
  /// Sync files for a category (images, videos, audio)
  /// Uses MediaService to get files from PhotoKit on iOS or FileService on Android
  Future<void> _syncCategory(String path, FolderSync folderSync) async {
    // Check if cancelled before starting
    if (_cancelledSyncs.contains(path)) {
      debugPrint('Category sync cancelled for $path, skipping');
      return;
    }

    // Extract category name from path (e.g., "category:images" -> "images")
    final categoryName = path.substring('category:'.length);
    final category = _categoryFromString(categoryName);

    try {
      // Show "syncing" immediately BEFORE file scan - gives user instant feedback
      await LocalStorageService.instance.updateFolderSyncStatus(
        path,
        FolderSyncStatus.syncing,
        totalFiles: 0, // Will update once scan completes
        syncedFiles: 0,
      );
      _notifyListeners(path, FolderSyncStatus.syncing);

      // Get all files for this category using paginated fetches
      const fetchLimit = 1000;
      int fetchOffset = 0;
      final allFiles = <LocalFile>[];

      while (true) {
        if (_cancelledSyncs.contains(path)) {
          debugPrint('Category sync cancelled during fetch for $path');
          return;
        }

        final result = await MediaService.instance.getMediaByCategory(
          category,
          offset: fetchOffset,
          limit: fetchLimit,
          sortBy: 'date',
          ascending: false,
        );

        allFiles.addAll(result.files);
        fetchOffset += result.files.length;

        if (!result.hasMore || result.files.isEmpty) break;
      }

      final files = allFiles;

      // Update with actual file count
      await LocalStorageService.instance.updateFolderSyncStatus(
        path,
        FolderSyncStatus.syncing,
        totalFiles: files.length,
        syncedFiles: 0,
      );

      int syncedCount = 0;
      final bucket = folderSync.targetBucket;
      final trackedPaths = <String>{};

      // Build list of files to queue (fast, non-blocking)
      final toQueue = <_FileQueueItem>[];
      for (final file in files) {
        // Check if cancelled during file processing
        if (_cancelledSyncs.contains(path)) {
          debugPrint('Category sync cancelled during processing for $path');
          return;
        }

        trackedPaths.add(file.path);

        // Check if already synced (Hive sync read is fast)
        final syncState = LocalStorageService.instance.getSyncState(file.path);
        if (syncState?.isSynced == true) {
          syncedCount++;
          continue;
        }

        // Use file name as remote key for categories
        toQueue.add(_FileQueueItem(file.path, bucket, file.name));
      }

      final filesToSync = toQueue.length;

      // Register listener BEFORE queueing so no completions are missed
      if (filesToSync > 0) {
        int completedCount = 0;
        int failedCount = 0;
        late final SyncStatusCallback syncListener;
        syncListener = (localPath, status) {
          if (_cancelledSyncs.contains(path)) {
            SyncService.instance.removeListener(syncListener);
            _activeSyncListeners.remove(syncListener);
            return;
          }

          if (!trackedPaths.contains(localPath)) return;

          if (status == SyncStatus.synced) {
            completedCount++;
            syncedCount++;
          } else if (status == SyncStatus.error) {
            failedCount++;
          } else {
            return;
          }

          LocalStorageService.instance.updateFolderSyncStatus(
            path,
            FolderSyncStatus.syncing,
            syncedFiles: syncedCount,
          );

          if (completedCount + failedCount >= filesToSync) {
            final finalStatus = failedCount > 0
                ? FolderSyncStatus.error
                : FolderSyncStatus.synced;
            final errorMsg = failedCount > 0
                ? '$failedCount file(s) failed to sync'
                : null;
            LocalStorageService.instance.updateFolderSyncStatus(
              path,
              finalStatus,
              syncedFiles: syncedCount,
              errorMessage: errorMsg,
            );
            _notifyListeners(path, finalStatus);
            SyncService.instance.removeListener(syncListener);
            _activeSyncListeners.remove(syncListener);
          }
        };
        SyncService.instance.addListener(syncListener);
        _activeSyncListeners.add(syncListener);
      }

      // Queue all files in small batches without blocking UI
      const batchSize = 25;
      for (int i = 0; i < toQueue.length; i += batchSize) {
        if (_cancelledSyncs.contains(path)) {
          debugPrint('Category sync cancelled during queue for $path');
          return;
        }

        final end = (i + batchSize < toQueue.length) ? i + batchSize : toQueue.length;
        final batch = toQueue.sublist(i, end);

        try {
          await _queueBatch(batch);
        } catch (e) {
          debugPrint('Error queuing batch for $path: $e');
        }

        await Future.delayed(Duration.zero);
      }

      if (filesToSync == 0) {
        // All files already synced — mark complete immediately
        await LocalStorageService.instance.updateFolderSyncStatus(
          path,
          FolderSyncStatus.synced,
          syncedFiles: syncedCount,
        );
        _notifyListeners(path, FolderSyncStatus.synced);
      }

      debugPrint('Category sync scan for $categoryName: ${files.length} files found, '
          '$syncedCount already synced, $filesToSync to queue');
      
    } catch (e) {
      debugPrint('Category sync failed for $path: $e');
      await LocalStorageService.instance.updateFolderSyncStatus(
        path,
        FolderSyncStatus.error,
        errorMessage: e.toString(),
      );
      _notifyListeners(path, FolderSyncStatus.error);
    }
  }
  
  FileCategory _categoryFromString(String cat) {
    switch (cat) {
      case 'images': return FileCategory.images;
      case 'videos': return FileCategory.videos;
      case 'audio': return FileCategory.audio;
      case 'documents': return FileCategory.documents;
      case 'downloads': return FileCategory.downloads;
      case 'archives': return FileCategory.archives;
      default: return FileCategory.other;
    }
  }

  Future<void> _registerPeriodicSync() async {
    if (!PlatformCapabilities.isMobile) return;
    await Workmanager().registerPeriodicTask(
      folderSyncPeriodicTaskName,
      folderSyncTaskName,
      frequency: const Duration(hours: 1),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
    );
    debugPrint('Registered periodic folder sync task');
  }

  Future<void> cancelPeriodicSync() async {
    if (!PlatformCapabilities.isMobile) return;
    await Workmanager().cancelByUniqueName(folderSyncPeriodicTaskName);
    debugPrint('Cancelled periodic folder sync task');
  }

  FolderSync? getFolderSync(String path) {
    return LocalStorageService.instance.getFolderSync(path);
  }

  List<FolderSync> getAllFolderSyncs() {
    return LocalStorageService.instance.getAllFolderSyncs();
  }

  /// Check if folder sync is supported for a given path on the current platform
  /// On iOS, only category syncs and app sandbox directories are supported
  Future<bool> isFolderSyncSupported(String path) async {
    // Category syncs are always supported (they use MediaService)
    if (path.startsWith('category:')) {
      return true;
    }

    // On iOS, only app sandbox directories can be watched
    if (Platform.isIOS) {
      final appDocDir = await getApplicationDocumentsDirectory();
      return path.startsWith(appDocDir.path);
    }

    // Android supports watching any directory with storage permission
    return true;
  }

  /// Check if arbitrary folder selection for sync is supported on this platform
  /// Returns false on iOS (can only sync categories or app sandbox)
  bool get canSelectArbitraryFolders => !Platform.isIOS;

  // ============================================================================
  // CLOUD PERSISTENCE — survive uninstall/reinstall
  // ============================================================================

  void _scheduleSyncToCloud() {
    if (_cloudSyncScheduled) return;
    _cloudSyncScheduled = true;
    Future.delayed(_cloudSyncDebounce, () async {
      _cloudSyncScheduled = false;
      await syncToCloud();
    });
  }

  Future<String?> _getUserId() async {
    try {
      final publicKey = await AuthService.instance.getPublicKeyString();
      if (publicKey == null || publicKey.isEmpty) return null;
      final bytes = utf8.encode(publicKey);
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 16);
    } catch (e) {
      debugPrint('FolderWatchService._getUserId error: $e');
      return null;
    }
  }

  Future<void> syncToCloud() async {
    if (!FulaApiService.instance.isConfigured) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final allSyncs = LocalStorageService.instance.getAllFolderSyncs();
      // Only persist enabled (non-disabled) configs — disabled means the user
      // removed it; there is nothing to restore.
      final configs = allSyncs
          .where((fs) => fs.isEnabled)
          .map((fs) => fs.toJson())
          .toList();

      final jsonStr = jsonEncode({
        'folderSyncs': configs,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final data = Uint8List.fromList(utf8.encode(jsonStr));

      try {
        await FulaApiService.instance.createBucket(_writeBucket);
      } catch (_) {
        // Ignore — bucket may already exist
      }
      final key = '.fula/folderSync/$userId.json';
      await FulaApiService.instance.encryptAndUpload(
        _writeBucket,
        key,
        data,
        encryptionKey,
        contentType: 'application/json',
      );
      debugPrint('FolderWatchService: synced ${configs.length} folder configs to cloud');
    } catch (e) {
      debugPrint('FolderWatchService: syncToCloud error: $e');
    }
  }

  Future<void> restoreFromCloud() async {
    if (!FulaApiService.instance.isConfigured) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final key = '.fula/folderSync/$userId.json';
      // MERGE legacy + v8 (additive, v8 wins a duplicate folder). Legacy holds
      // pre-migration configs, v8 the post-migration ones; a fresh install must
      // read BOTH or it would silently restore nothing once writes route to v8.
      final blobs = await FulaApiService.instance
          .downloadMetadataMerged(_metadataBucket, key, encryptionKey);
      if (blobs.isEmpty) {
        debugPrint('FolderWatchService: no cloud config found (new user)');
        return;
      }

      // Combine both manifests' configs, deduped by path (v8 first ⇒ wins).
      final byPath = <String, FolderSync>{};
      for (final data in blobs) {
        try {
          final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
          final configsList = json['folderSyncs'] as List<dynamic>? ?? [];
          for (final configJson in configsList) {
            try {
              final config =
                  FolderSync.fromJson(configJson as Map<String, dynamic>);
              byPath.putIfAbsent(config.path, () => config);
            } catch (e) {
              debugPrint('FolderWatchService: error parsing config: $e');
            }
          }
        } catch (e) {
          debugPrint('FolderWatchService: error parsing manifest: $e');
        }
      }

      // Only restore if local storage has no folder syncs (fresh install)
      final existingSyncs = LocalStorageService.instance.getAllFolderSyncs();
      if (existingSyncs.isNotEmpty) {
        debugPrint('FolderWatchService: local configs exist, skipping cloud restore');
        return;
      }

      var restored = 0;
      for (final config in byPath.values) {
        try {
          // Restore with "enabled" status so user can see them and trigger sync
          // Category syncs can always be restored; directory syncs need the path to exist
          if (config.isCategory || await Directory(config.path).exists()) {
            await LocalStorageService.instance.addFolderSync(config.copyWith(
              status: FolderSyncStatus.enabled,
              syncedFiles: 0,
              totalFiles: 0,
              errorMessage: null,
            ));
            await _startWatching(config.path);
            restored++;
          } else {
            debugPrint('FolderWatchService: skipping restore for missing dir: ${config.path}');
          }
        } catch (e) {
          debugPrint('FolderWatchService: error restoring config: $e');
        }
      }

      if (restored > 0) {
        debugPrint('FolderWatchService: restored $restored folder configs from cloud (merged)');
        // Trigger sync for all restored folders
        final restoredSyncs = LocalStorageService.instance.getEnabledFolderSyncs();
        for (final sync in restoredSyncs) {
          syncFolder(sync.path);
        }
      }
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('NoSuchKey') ||
          errorStr.contains('Object not found') ||
          errorStr.contains('404')) {
        debugPrint('FolderWatchService: no cloud config found (new user)');
      } else {
        debugPrint('FolderWatchService: restoreFromCloud error: $e');
      }
    }
  }

  void dispose() {
    for (final subscription in _watchers.values) {
      subscription.cancel();
    }
    _watchers.clear();

    // Remove all active sync listeners from SyncService
    for (final listener in _activeSyncListeners) {
      SyncService.instance.removeListener(listener);
    }
    _activeSyncListeners.clear();

    _listeners.clear();
  }
}

class _PendingUpload {
  final String folderPath;
  final String filePath;

  _PendingUpload({required this.folderPath, required this.filePath});
}

/// Helper class for batch file queueing
class _FileQueueItem {
  final String localPath;
  final String bucket;
  final String remoteKey;

  _FileQueueItem(this.localPath, this.bucket, this.remoteKey);
}

// NOTE: this file's callbackDispatcher was removed because Workmanager
// only supports one dispatcher per process. Having two `@pragma('vm:
// entry-point') void callbackDispatcher()` functions in the codebase
// meant whichever called `Workmanager().initialize` last won — and
// every other task (model download, upload, periodic sync, app backup)
// fired but ran THIS dispatcher's folder-sync code instead of its own
// logic. The folder-sync task body now lives in
// `background_sync_service.dart`'s `callbackDispatcher` switch under
// the `folderSyncTaskName` case.
