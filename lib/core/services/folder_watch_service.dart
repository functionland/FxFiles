import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'package:fula_files/core/models/folder_sync.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/services/media_service.dart';

const String folderSyncTaskName = 'com.functionland.fxfiles.folderSync';
const String folderSyncPeriodicTaskName = 'com.functionland.fxfiles.folderSyncPeriodic';

typedef FolderSyncCallback = void Function(String path, FolderSyncStatus status);

class FolderWatchService {
  FolderWatchService._();
  static final FolderWatchService instance = FolderWatchService._();

  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
  final List<FolderSyncCallback> _listeners = [];
  bool _isInitialized = false;
  
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
    for (final listener in _listeners) {
      listener(path, status);
    }
  }

  Future<void> init() async {
    if (_isInitialized) return;
    
    // Initialize workmanager for background tasks
    await Workmanager().initialize(
      callbackDispatcher,
    );
    
    // Start watching all enabled folder syncs
    final enabledSyncs = LocalStorageService.instance.getEnabledFolderSyncs();
    for (final sync in enabledSyncs) {
      await _startWatching(sync.path);
    }
    
    _isInitialized = true;
    debugPrint('FolderWatchService initialized with ${enabledSyncs.length} watched folders');
  }

  Future<void> enableFolderSync({
    required String path,
    required String targetBucket,
    String? categoryName,
    bool isCategory = false,
  }) async {
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
    
    // Trigger initial sync
    await syncFolder(path);
    
    // Register periodic background task
    await _registerPeriodicSync();
    
    debugPrint('Enabled folder sync for: $path');
  }

  Future<void> disableFolderSync(String path) async {
    // Stop watching
    await _stopWatching(path);
    
    // Update status
    await LocalStorageService.instance.updateFolderSyncStatus(
      path,
      FolderSyncStatus.disabled,
    );
    _notifyListeners(path, FolderSyncStatus.disabled);
    
    debugPrint('Disabled folder sync for: $path');
  }

  Future<void> _startWatching(String path) async {
    if (_watchers.containsKey(path)) return;
    
    // Category paths (e.g., "category:images") are not real directories
    // They use MediaService/FileService to get files, so no watching needed
    if (path.startsWith('category:')) {
      debugPrint('Skipping directory watch for category path: $path');
      return;
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
    // Only handle file creation and modification
    if (event is FileSystemCreateEvent || event is FileSystemModifyEvent) {
      final file = File(event.path);
      if (file.existsSync() && !FileSystemEntity.isDirectorySync(event.path)) {
        debugPrint('File changed in watched folder: ${event.path}');
        _queueFileUpload(folderPath, event.path);
      }
    }
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
      final relativePath = pending.filePath.substring(pending.folderPath.length + 1);
      final folderName = pending.folderPath.split('/').last;
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

  Future<void> syncFolder(String path) async {
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
      
      // Collect all files
      final files = <File>[];
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          files.add(entity);
        }
      }
      
      // Update total count
      await LocalStorageService.instance.updateFolderSyncStatus(
        path,
        FolderSyncStatus.syncing,
        totalFiles: files.length,
        syncedFiles: 0,
      );
      
      final folderName = path.split('/').last;
      int syncedCount = 0;
      
      // Queue all files for upload with parallel processing
      for (final file in files) {
        // Check if already synced
        final syncState = LocalStorageService.instance.getSyncState(file.path);
        if (syncState?.isSynced == true) {
          syncedCount++;
          continue;
        }
        
        // Calculate remote key
        final relativePath = file.path.substring(path.length + 1);
        final remoteKey = folderSync.isCategory
            ? relativePath.replaceAll('\\', '/')
            : '$folderName/$relativePath'.replaceAll('\\', '/');
        
        // Determine bucket based on file type for categories, or use target bucket
        String bucket;
        if (folderSync.isCategory) {
          final category = FileCategory.fromPath(file.path);
          bucket = category.bucketName;
        } else {
          bucket = folderSync.targetBucket;
        }
        
        await SyncService.instance.queueUpload(
          localPath: file.path,
          remoteBucket: bucket,
          remoteKey: remoteKey,
        );
      }
      
      // Listen for sync completion
      SyncService.instance.addListener((localPath, status) {
        if (localPath.startsWith(path) && status == SyncStatus.synced) {
          syncedCount++;
          LocalStorageService.instance.updateFolderSyncStatus(
            path,
            FolderSyncStatus.syncing,
            syncedFiles: syncedCount,
          );
          
          // Check if all done
          if (syncedCount >= files.length) {
            LocalStorageService.instance.updateFolderSyncStatus(
              path,
              FolderSyncStatus.synced,
              syncedFiles: syncedCount,
            );
            _notifyListeners(path, FolderSyncStatus.synced);
          }
        }
      });
      
      debugPrint('Started syncing $path: ${files.length} files');
      
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
    // Extract category name from path (e.g., "category:images" -> "images")
    final categoryName = path.substring('category:'.length);
    final category = _categoryFromString(categoryName);
    
    try {
      // Get all files for this category using MediaService
      final result = await MediaService.instance.getMediaByCategory(
        category,
        offset: 0,
        limit: 10000, // Get all files
        sortBy: 'date',
        ascending: false,
      );
      
      final files = result.files;
      
      // Update total count
      await LocalStorageService.instance.updateFolderSyncStatus(
        path,
        FolderSyncStatus.syncing,
        totalFiles: files.length,
        syncedFiles: 0,
      );
      
      int syncedCount = 0;
      final bucket = folderSync.targetBucket;
      final trackedPaths = <String>{};
      
      // Queue all files for upload
      for (final file in files) {
        trackedPaths.add(file.path);
        
        // Check if already synced
        final syncState = LocalStorageService.instance.getSyncState(file.path);
        if (syncState?.isSynced == true) {
          syncedCount++;
          continue;
        }
        
        // Use file name as remote key for categories
        final remoteKey = file.name;
        
        await SyncService.instance.queueUpload(
          localPath: file.path,
          remoteBucket: bucket,
          remoteKey: remoteKey,
        );
      }
      
      // Listen for sync completion
      SyncService.instance.addListener((localPath, status) {
        if (trackedPaths.contains(localPath) && status == SyncStatus.synced) {
          syncedCount++;
          LocalStorageService.instance.updateFolderSyncStatus(
            path,
            FolderSyncStatus.syncing,
            syncedFiles: syncedCount,
          );
          
          // Check if all done
          if (syncedCount >= files.length) {
            LocalStorageService.instance.updateFolderSyncStatus(
              path,
              FolderSyncStatus.synced,
              syncedFiles: syncedCount,
            );
            _notifyListeners(path, FolderSyncStatus.synced);
          }
        }
      });
      
      debugPrint('Started category sync for $categoryName: ${files.length} files');
      
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
    await Workmanager().cancelByUniqueName(folderSyncPeriodicTaskName);
    debugPrint('Cancelled periodic folder sync task');
  }

  FolderSync? getFolderSync(String path) {
    return LocalStorageService.instance.getFolderSync(path);
  }

  List<FolderSync> getAllFolderSyncs() {
    return LocalStorageService.instance.getAllFolderSyncs();
  }

  void dispose() {
    for (final subscription in _watchers.values) {
      subscription.cancel();
    }
    _watchers.clear();
    _listeners.clear();
  }
}

class _PendingUpload {
  final String folderPath;
  final String filePath;

  _PendingUpload({required this.folderPath, required this.filePath});
}

// Workmanager callback dispatcher - must be top-level function
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    debugPrint('Background task executing: $task');
    
    try {
      // Initialize services needed for background sync
      await LocalStorageService.instance.init();
      
      // Get all enabled folder syncs and sync them
      final enabledSyncs = LocalStorageService.instance.getEnabledFolderSyncs();
      for (final sync in enabledSyncs) {
        await FolderWatchService.instance.syncFolder(sync.path);
      }
      
      return true;
    } catch (e) {
      debugPrint('Background task failed: $e');
      return false;
    }
  });
}
