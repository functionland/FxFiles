import 'package:hive_flutter/hive_flutter.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/core/models/folder_sync.dart';

class LocalStorageService {
  LocalStorageService._();
  static final LocalStorageService instance = LocalStorageService._();

  late Box<dynamic> _settingsBox;
  late Box<SyncState> _syncStateBox;
  late Box<RecentFile> _recentFilesBox;
  late Box<String> _starredFilesBox;
  late Box<FolderSync> _folderSyncBox;

  Future<void> init() async {
    await Hive.initFlutter();
    
    // Register adapters (check if not already registered)
    // Type IDs: SyncStatus=0, SyncState=1, RecentFile=2, FolderSyncStatus=4, FolderSync=5
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

    // Open boxes
    _settingsBox = await Hive.openBox('settings');
    _syncStateBox = await Hive.openBox<SyncState>('sync_states');
    _recentFilesBox = await Hive.openBox<RecentFile>('recent_files');
    _starredFilesBox = await Hive.openBox<String>('starred_files');
    _folderSyncBox = await Hive.openBox<FolderSync>('folder_syncs');
  }

  // Settings
  Future<void> saveSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  T? getSetting<T>(String key, {T? defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue) as T?;
  }

  // Sync States
  Future<void> addSyncState(SyncState state) async {
    await _syncStateBox.put(state.localPath, state);
  }

  SyncState? getSyncState(String localPath) {
    return _syncStateBox.get(localPath);
  }

  List<SyncState> getAllSyncStates() {
    return _syncStateBox.values.toList();
  }

  Future<void> deleteSyncState(String localPath) async {
    await _syncStateBox.delete(localPath);
  }

  Future<void> clearAllSyncStates() async {
    await _syncStateBox.clear();
  }

  // Recent Files
  Future<void> addRecentFile(RecentFile file) async {
    // Remove if already exists
    final existing = _recentFilesBox.values.where((f) => f.path == file.path);
    for (final f in existing) {
      await f.delete();
    }
    
    // Add new
    await _recentFilesBox.add(file);
    
    // Keep only last 30
    if (_recentFilesBox.length > 30) {
      final toDelete = _recentFilesBox.values.toList()
        ..sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
      for (var i = 0; i < _recentFilesBox.length - 30; i++) {
        await toDelete[i].delete();
      }
    }
  }

  List<RecentFile> getRecentFiles({int limit = 30}) {
    final files = _recentFilesBox.values.toList()
      ..sort((a, b) => b.accessedAt.compareTo(a.accessedAt));
    return files.take(limit).toList();
  }

  Future<void> clearRecentFiles() async {
    await _recentFilesBox.clear();
  }

  // Starred Files
  Future<void> starFile(String path) async {
    if (!_starredFilesBox.values.contains(path)) {
      await _starredFilesBox.add(path);
    }
  }

  Future<void> unstarFile(String path) async {
    final key = _starredFilesBox.keys.firstWhere(
      (k) => _starredFilesBox.get(k) == path,
      orElse: () => null,
    );
    if (key != null) {
      await _starredFilesBox.delete(key);
    }
  }

  bool isStarred(String path) {
    return _starredFilesBox.values.contains(path);
  }

  Future<void> toggleStar(String path) async {
    if (isStarred(path)) {
      await unstarFile(path);
    } else {
      await starFile(path);
    }
  }

  List<String> getStarredFiles() {
    return _starredFilesBox.values.toList();
  }

  Future<void> clearStarredFiles() async {
    await _starredFilesBox.clear();
  }

  // Folder Sync
  Future<void> addFolderSync(FolderSync folderSync) async {
    await _folderSyncBox.put(folderSync.path, folderSync);
  }

  FolderSync? getFolderSync(String path) {
    return _folderSyncBox.get(path);
  }

  List<FolderSync> getAllFolderSyncs() {
    return _folderSyncBox.values.toList();
  }

  List<FolderSync> getEnabledFolderSyncs() {
    return _folderSyncBox.values
        .where((fs) => fs.status != FolderSyncStatus.disabled)
        .toList();
  }

  Future<void> updateFolderSyncStatus(String path, FolderSyncStatus status, {
    int? totalFiles,
    int? syncedFiles,
    String? errorMessage,
  }) async {
    final existing = _folderSyncBox.get(path);
    if (existing != null) {
      await _folderSyncBox.put(path, existing.copyWith(
        status: status,
        totalFiles: totalFiles,
        syncedFiles: syncedFiles,
        errorMessage: errorMessage,
        lastSyncedAt: status == FolderSyncStatus.synced ? DateTime.now() : null,
      ));
    }
  }

  Future<void> deleteFolderSync(String path) async {
    await _folderSyncBox.delete(path);
  }

  bool isFolderSyncEnabled(String path) {
    final sync = _folderSyncBox.get(path);
    return sync != null && sync.isEnabled;
  }

  // Cleanup
  Future<void> clearAll() async {
    await _settingsBox.clear();
    await _syncStateBox.clear();
    await _recentFilesBox.clear();
    await _starredFilesBox.clear();
    await _folderSyncBox.clear();
  }
}
