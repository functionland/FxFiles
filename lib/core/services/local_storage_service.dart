import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/core/models/folder_sync.dart';
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/core/models/sync_task.dart';

class LocalStorageService {
  LocalStorageService._();
  static final LocalStorageService instance = LocalStorageService._();

  Box<dynamic>? _settingsBox;
  Box<SyncState>? _syncStateBox;
  Box<RecentFile>? _recentFilesBox;
  Box<String>? _starredFilesBox;
  Box<FolderSync>? _folderSyncBox;
  Box<SyncTask>? _syncQueueBox;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;

    // Hive initialization with timeout (can hang on iOS 26+)
    try {
      await Hive.initFlutter().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('Hive.initFlutter failed: $e');
      return; // Can't proceed without Hive init
    }

    // Register adapters (check if not already registered)
    // Type IDs: SyncStatus=0, SyncState=1, RecentFile=2, FolderSyncStatus=4, FolderSync=5, AudioTrack=6, Playlist=7
    _registerAdapters();

    // Open boxes with individual timeout protection
    // This prevents one slow/hanging box from blocking the entire app
    const boxTimeout = Duration(milliseconds: 1500);

    try {
      _settingsBox = await Hive.openBox('settings').timeout(boxTimeout);
    } catch (e) {
      debugPrint('Failed to open settings box: $e');
    }

    try {
      _syncStateBox = await Hive.openBox<SyncState>('sync_states').timeout(boxTimeout);
    } catch (e) {
      debugPrint('Failed to open sync_states box: $e');
    }

    try {
      _recentFilesBox = await Hive.openBox<RecentFile>('recent_files').timeout(boxTimeout);
    } catch (e) {
      debugPrint('Failed to open recent_files box: $e');
    }

    try {
      _starredFilesBox = await Hive.openBox<String>('starred_files').timeout(boxTimeout);
    } catch (e) {
      debugPrint('Failed to open starred_files box: $e');
    }

    try {
      _folderSyncBox = await Hive.openBox<FolderSync>('folder_syncs').timeout(boxTimeout);
    } catch (e) {
      debugPrint('Failed to open folder_syncs box: $e');
    }

    try {
      _syncQueueBox = await Hive.openBox<SyncTask>('sync_queue').timeout(boxTimeout);
    } catch (e) {
      debugPrint('Failed to open sync_queue box: $e');
    }

    _isInitialized = true;
  }

  void _registerAdapters() {
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(SyncStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(SyncStateAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(RecentFileAdapter());
    }
    if (!Hive.isAdapterRegistered(4)) {
      Hive.registerAdapter(FolderSyncStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(5)) {
      Hive.registerAdapter(FolderSyncAdapter());
    }
    if (!Hive.isAdapterRegistered(6)) {
      Hive.registerAdapter(AudioTrackAdapter());
    }
    if (!Hive.isAdapterRegistered(7)) {
      Hive.registerAdapter(PlaylistAdapter());
    }
    // SyncTask adapters (typeIds 14, 15, 16)
    if (!Hive.isAdapterRegistered(14)) {
      Hive.registerAdapter(SyncTaskStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(15)) {
      Hive.registerAdapter(SyncTaskDirectionAdapter());
    }
    if (!Hive.isAdapterRegistered(16)) {
      Hive.registerAdapter(SyncTaskAdapter());
    }
  }

  // Settings
  Future<void> saveSetting(String key, dynamic value) async {
    await _settingsBox?.put(key, value);
  }

  T? getSetting<T>(String key, {T? defaultValue}) {
    return _settingsBox?.get(key, defaultValue: defaultValue) as T? ?? defaultValue;
  }

  // Sync States
  Future<void> addSyncState(SyncState state) async {
    final box = _syncStateBox;
    if (box == null) return;

    await box.put(state.localPath, state);
    // Also store by displayPath if provided (for iOS PhotoKit virtual path lookup)
    // Create a new instance to avoid Hive's "same instance with two keys" error
    if (state.displayPath != null && state.displayPath != state.localPath) {
      final displayState = SyncState(
        localPath: state.localPath,
        remotePath: state.remotePath,
        remoteKey: state.remoteKey,
        bucket: state.bucket,
        status: state.status,
        lastSyncedAt: state.lastSyncedAt,
        etag: state.etag,
        localSize: state.localSize,
        remoteSize: state.remoteSize,
        errorMessage: state.errorMessage,
        displayPath: state.displayPath,
        iosAssetId: state.iosAssetId,
      );
      await box.put(state.displayPath!, displayState);
    }
  }

  SyncState? getSyncState(String localPath) {
    return _syncStateBox?.get(localPath);
  }

  /// Get sync state by path, also checking displayPath entries
  /// This is useful for iOS where the display path differs from the actual file path
  SyncState? getSyncStateByDisplayPath(String displayPath) {
    final box = _syncStateBox;
    if (box == null) return null;

    // First try direct lookup
    final direct = box.get(displayPath);
    if (direct != null) return direct;

    // Search all states for matching displayPath
    for (final state in box.values) {
      if (state.displayPath == displayPath) {
        return state;
      }
    }
    return null;
  }

  /// Get sync state by iOS asset ID (most reliable for iOS PhotoKit files)
  SyncState? getSyncStateByIosAssetId(String iosAssetId) {
    final box = _syncStateBox;
    if (box == null) return null;

    for (final state in box.values) {
      if (state.iosAssetId == iosAssetId) {
        return state;
      }
    }
    return null;
  }

  /// Get sync state by remote key and bucket (for checking if cloud file is linked to local)
  SyncState? getSyncStateByRemoteKey(String remoteKey, String bucket) {
    final box = _syncStateBox;
    if (box == null) return null;

    for (final state in box.values) {
      if (state.remoteKey == remoteKey && state.bucket == bucket) {
        return state;
      }
    }
    return null;
  }

  /// Get a set of all remote keys that have sync states with local files
  /// This is used for efficient cloud-only detection
  Set<String> getLinkedRemoteKeys(String bucket) {
    final box = _syncStateBox;
    if (box == null) return {};

    final keys = <String>{};
    for (final state in box.values) {
      if (state.bucket == bucket && state.remoteKey != null) {
        keys.add(state.remoteKey!);
      }
    }
    return keys;
  }

  List<SyncState> getAllSyncStates() {
    return _syncStateBox?.values.toList() ?? [];
  }

  Future<void> deleteSyncState(String localPath) async {
    await _syncStateBox?.delete(localPath);
  }

  Future<void> clearAllSyncStates() async {
    await _syncStateBox?.clear();
  }

  // Recent Files
  Future<void> addRecentFile(RecentFile file) async {
    final box = _recentFilesBox;
    if (box == null) return;

    // Remove if already exists
    final existing = box.values.where((f) => f.path == file.path);
    for (final f in existing) {
      await f.delete();
    }

    // Add new
    await box.add(file);

    // Keep only last 30
    if (box.length > 30) {
      final toDelete = box.values.toList()
        ..sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
      for (var i = 0; i < box.length - 30; i++) {
        await toDelete[i].delete();
      }
    }
  }

  List<RecentFile> getRecentFiles({int limit = 30}) {
    final box = _recentFilesBox;
    if (box == null) return [];

    final files = box.values.toList()
      ..sort((a, b) => b.accessedAt.compareTo(a.accessedAt));
    return files.take(limit).toList();
  }

  Future<void> clearRecentFiles() async {
    await _recentFilesBox?.clear();
  }

  // Starred Files
  Future<void> starFile(String path) async {
    final box = _starredFilesBox;
    if (box == null) return;

    if (!box.values.contains(path)) {
      await box.add(path);
    }
  }

  Future<void> unstarFile(String path) async {
    final box = _starredFilesBox;
    if (box == null) return;

    final key = box.keys.firstWhere(
      (k) => box.get(k) == path,
      orElse: () => null,
    );
    if (key != null) {
      await box.delete(key);
    }
  }

  bool isStarred(String path) {
    return _starredFilesBox?.values.contains(path) ?? false;
  }

  Future<void> toggleStar(String path) async {
    if (isStarred(path)) {
      await unstarFile(path);
    } else {
      await starFile(path);
    }
  }

  List<String> getStarredFiles() {
    return _starredFilesBox?.values.toList() ?? [];
  }

  Future<void> clearStarredFiles() async {
    await _starredFilesBox?.clear();
  }

  // Folder Sync
  Future<void> addFolderSync(FolderSync folderSync) async {
    await _folderSyncBox?.put(folderSync.path, folderSync);
  }

  FolderSync? getFolderSync(String path) {
    return _folderSyncBox?.get(path);
  }

  List<FolderSync> getAllFolderSyncs() {
    return _folderSyncBox?.values.toList() ?? [];
  }

  List<FolderSync> getEnabledFolderSyncs() {
    final box = _folderSyncBox;
    if (box == null) return [];

    return box.values
        .where((fs) => fs.status != FolderSyncStatus.disabled)
        .toList();
  }

  Future<void> updateFolderSyncStatus(String path, FolderSyncStatus status, {
    int? totalFiles,
    int? syncedFiles,
    String? errorMessage,
  }) async {
    final box = _folderSyncBox;
    if (box == null) return;

    final existing = box.get(path);
    if (existing != null) {
      await box.put(path, existing.copyWith(
        status: status,
        totalFiles: totalFiles,
        syncedFiles: syncedFiles,
        errorMessage: errorMessage,
        lastSyncedAt: status == FolderSyncStatus.synced ? DateTime.now() : null,
      ));
    }
  }

  Future<void> deleteFolderSync(String path) async {
    await _folderSyncBox?.delete(path);
  }

  bool isFolderSyncEnabled(String path) {
    final sync = _folderSyncBox?.get(path);
    return sync != null && sync.isEnabled;
  }

  // Sync Queue (persistent upload/download queue)
  Future<void> addToSyncQueue(SyncTask task) async {
    await _syncQueueBox?.put(task.id, task);
  }

  Future<void> updateSyncTask(SyncTask task) async {
    await _syncQueueBox?.put(task.id, task);
  }

  SyncTask? getSyncTask(String id) {
    return _syncQueueBox?.get(id);
  }

  List<SyncTask> getPendingSyncTasks() {
    final box = _syncQueueBox;
    if (box == null) return [];

    return box.values
        .where((task) => task.status == SyncTaskStatus.pending ||
                         task.status == SyncTaskStatus.inProgress)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  List<SyncTask> getFailedSyncTasks() {
    final box = _syncQueueBox;
    if (box == null) return [];

    return box.values
        .where((task) => task.status == SyncTaskStatus.failed)
        .toList();
  }

  List<SyncTask> getAllSyncTasks() {
    return _syncQueueBox?.values.toList() ?? [];
  }

  Future<void> removeSyncTask(String id) async {
    await _syncQueueBox?.delete(id);
  }

  Future<void> clearCompletedSyncTasks() async {
    final box = _syncQueueBox;
    if (box == null) return;

    final completed = box.values
        .where((task) => task.status == SyncTaskStatus.completed)
        .toList();
    for (final task in completed) {
      await box.delete(task.id);
    }
  }

  Future<void> clearSyncQueue() async {
    await _syncQueueBox?.clear();
  }

  int get pendingSyncTaskCount {
    final box = _syncQueueBox;
    if (box == null) return 0;

    return box.values
        .where((task) => task.status == SyncTaskStatus.pending ||
                         task.status == SyncTaskStatus.inProgress)
        .length;
  }

  // Cleanup
  Future<void> clearAll() async {
    await _settingsBox?.clear();
    await _syncStateBox?.clear();
    await _recentFilesBox?.clear();
    await _starredFilesBox?.clear();
    await _folderSyncBox?.clear();
    await _syncQueueBox?.clear();
  }
}
