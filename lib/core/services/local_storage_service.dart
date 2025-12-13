import 'package:hive_flutter/hive_flutter.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/models/recent_file.dart';

class LocalStorageService {
  LocalStorageService._();
  static final LocalStorageService instance = LocalStorageService._();

  late Box<dynamic> _settingsBox;
  late Box<SyncState> _syncStateBox;
  late Box<RecentFile> _recentFilesBox;
  late Box<String> _starredFilesBox;

  Future<void> init() async {
    await Hive.initFlutter();
    
    // Register adapters
    Hive.registerAdapter(SyncStatusAdapter());
    Hive.registerAdapter(SyncStateAdapter());
    Hive.registerAdapter(RecentFileAdapter());

    // Open boxes
    _settingsBox = await Hive.openBox('settings');
    _syncStateBox = await Hive.openBox<SyncState>('sync_states');
    _recentFilesBox = await Hive.openBox<RecentFile>('recent_files');
    _starredFilesBox = await Hive.openBox<String>('starred_files');
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

  // Cleanup
  Future<void> clearAll() async {
    await _settingsBox.clear();
    await _syncStateBox.clear();
    await _recentFilesBox.clear();
    await _starredFilesBox.clear();
  }
}
