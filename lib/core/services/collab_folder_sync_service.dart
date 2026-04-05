import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/services/collaboration_service.dart';

/// Bidirectional sync between local folders and collab groups.
///
/// Download: polls manifest periodically, downloads new files to local folder.
/// Upload: watches local folder for new files, encrypts + uploads to collab.
class CollabFolderSyncService {
  CollabFolderSyncService._();
  static final CollabFolderSyncService instance = CollabFolderSyncService._();

  static const Duration _minPollInterval = Duration(seconds: 60);
  static const Duration _maxPollInterval = Duration(minutes: 5);
  static const int _maxFileSize = 100 * 1024 * 1024; // 100MB (server limit)
  static const String _syncMetaFile = '.collab-sync.json';

  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
  final Map<String, Timer> _pollTimers = {};
  final Map<String, bool> _syncing = {};
  final Map<String, Duration> _currentPollInterval = {}; // adaptive per group
  final Map<String, Timer> _uploadDebounce = {}; // debounce per file path
  final Set<String> _permanentlyFailed = {}; // files that failed with non-retryable errors (413, etc.)
  DateTime? _lastResumeTime; // cooldown for onAppResumed

  // Listeners for sync status changes
  final _statusController = StreamController<CollabSyncStatus>.broadcast();
  Stream<CollabSyncStatus> get onStatusChange => _statusController.stream;

  /// Initialize: restore syncs for all groups with syncEnabled
  Future<void> init() async {
    try {
      final service = CollaborationService.instance;
      final outgoing = await service.getOutgoingCollaborations();
      final accepted = await service.getAcceptedCollaborations();

      // Collect all groups that need sync, deduplicating by folder path
      // (multiple collabs may point to the same folder — only watch once per folder)
      final groupsToSync = <String, String>{}; // groupId → folderPath
      for (final c in outgoing) {
        if (c.syncEnabled && c.localFolderPath != null) {
          if (groupsToSync.values.contains(c.localFolderPath)) {
            debugPrint('[CollabFolderSync] Skipping duplicate folder for outgoing "${c.name}" → ${c.localFolderPath}');
            continue;
          }
          groupsToSync[c.id] = c.localFolderPath!;
        }
      }
      for (final c in accepted) {
        if (c.syncEnabled && c.localFolderPath != null) {
          if (groupsToSync.values.contains(c.localFolderPath)) {
            debugPrint('[CollabFolderSync] Skipping duplicate folder for accepted "${c.name}" → ${c.localFolderPath}');
            continue;
          }
          groupsToSync[c.id] = c.localFolderPath!;
        }
      }

      // Start sync for each group, catching per-group errors so one failure
      // doesn't abort the rest (SecureStorage file locks can cause transient errors)
      for (final entry in groupsToSync.entries) {
        try {
          await _startSyncDirect(entry.key, entry.value);
        } catch (e) {
          debugPrint('[CollabFolderSync] Failed to start sync for ${entry.key}: $e');
        }
      }
      debugPrint('[CollabFolderSync] Initialized. Active syncs: ${_watchers.length}');
    } catch (e) {
      debugPrint('[CollabFolderSync] Init error: $e');
    }
  }

  /// Assign a local folder to a collab group, download files, start sync.
  Future<void> assignFolder(String groupId, String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Clear stale sync metadata from a previous collab group on this folder
    await _resetSyncMetaIfDifferentGroup(groupId, folderPath);

    // Update persistence
    await CollaborationService.instance.updateFolderAssignment(
      groupId,
      folderPath: folderPath,
      syncEnabled: true,
    );

    // Start watching + polling immediately so the caller isn't blocked
    await startSync(groupId);

    // Download remote files and upload existing local files in the background.
    // The collab link is valid immediately — files appear as they're synced.
    unawaited(_initialSyncInBackground(groupId, folderPath));
  }

  /// Runs the initial download + upload scan without blocking [assignFolder].
  Future<void> _initialSyncInBackground(String groupId, String folderPath) async {
    try {
      _emitStatus(groupId, CollabSyncState.syncing);

      // Download any existing remote files first
      await _pollForNewFiles(groupId);

      // Then upload local files not yet in the manifest
      await _scanAndUploadExistingFiles(groupId, folderPath);

      _emitStatus(groupId, CollabSyncState.synced);
    } catch (e) {
      debugPrint('[CollabFolderSync] Background initial sync error ($groupId): $e');
      _emitStatus(groupId, CollabSyncState.error);
    }
  }

  /// Remove folder assignment and stop sync.
  Future<void> unassignFolder(String groupId) async {
    await stopSync(groupId);
    await CollaborationService.instance.updateFolderAssignment(
      groupId,
      syncEnabled: false,
    );
    _emitStatus(groupId, CollabSyncState.idle);
  }

  /// Start watching and polling for a group.
  Future<void> startSync(String groupId) async {
    final info = await _getGroupInfo(groupId);
    if (info == null || info.folderPath == null) return;
    await _startSyncDirect(groupId, info.folderPath!);
  }

  /// Start watching and polling with a known folder path (avoids SecureStorage re-read).
  Future<void> _startSyncDirect(String groupId, String folderPath) async {
    // Prevent duplicates
    await stopSync(groupId);

    // Start directory watcher
    final dir = Directory(folderPath);
    if (await dir.exists()) {
      try {
        final watcher = dir.watch(recursive: true).listen(
          (event) => _handleLocalFileChange(groupId, event),
          onError: (e) => debugPrint('[CollabFolderSync] Watcher error ($groupId): $e'),
        );
        _watchers[groupId] = watcher;
        debugPrint('[CollabFolderSync] Watching: $folderPath');
      } catch (e) {
        debugPrint('[CollabFolderSync] Failed to watch $folderPath: $e');
      }
    }

    // Start poll timer with adaptive interval
    _currentPollInterval[groupId] = _minPollInterval;
    _schedulePoll(groupId);

    _emitStatus(groupId, CollabSyncState.synced);
  }

  /// Stop watching and polling for a group.
  Future<void> stopSync(String groupId) async {
    await _watchers[groupId]?.cancel();
    _watchers.remove(groupId);
    _pollTimers[groupId]?.cancel();
    _pollTimers.remove(groupId);
    _currentPollInterval.remove(groupId);
  }

  /// Restart all active watchers after app resume.
  /// Windows directory watchers can go stale after sleep/wake cycles.
  /// Debounced to avoid excessive restarts from rapid focus changes on Windows.
  Future<void> onAppResumed() async {
    final now = DateTime.now();
    if (_lastResumeTime != null && now.difference(_lastResumeTime!) < const Duration(seconds: 30)) {
      return; // cooldown — skip if resumed within last 30s
    }
    _lastResumeTime = now;

    final activeGroupIds = _watchers.keys.toList();
    if (activeGroupIds.isEmpty) return;
    debugPrint('[CollabFolderSync] onAppResumed - restarting ${activeGroupIds.length} watchers');
    for (final groupId in activeGroupIds) {
      await startSync(groupId);
    }
  }

  /// Trigger a manual sync (poll + download).
  Future<void> syncNow(String groupId) async {
    _currentPollInterval[groupId] = _minPollInterval; // reset to fast polling
    _emitStatus(groupId, CollabSyncState.syncing);
    await _pollForNewFiles(groupId);
    _emitStatus(groupId, CollabSyncState.synced);
  }

  /// Check if sync is active for a group.
  bool isSyncActive(String groupId) => _watchers.containsKey(groupId);

  /// Get the local folder path for a group.
  Future<String?> getFolderPath(String groupId) async {
    final info = await _getGroupInfo(groupId);
    return info?.folderPath;
  }

  // ============================================================================
  // DOWNLOAD SYNC (remote → local)
  // ============================================================================

  /// Schedule the next poll using the current adaptive interval for this group.
  void _schedulePoll(String groupId) {
    _pollTimers[groupId]?.cancel();
    final interval = _currentPollInterval[groupId] ?? _minPollInterval;
    _pollTimers[groupId] = Timer(interval, () {
      _pollForNewFiles(groupId);
    });
  }

  Future<void> _pollForNewFiles(String groupId) async {
    if (_syncing[groupId] == true) return;
    _syncing[groupId] = true;

    try {
      // Refresh manifest from cloud
      await CollaborationService.instance.refreshGroup(groupId);

      final info = await _getGroupInfo(groupId);
      if (info == null || info.folderPath == null) return;

      final folderPath = info.folderPath!;
      final group = info.group;
      final syncMeta = await _readSyncMeta(folderPath);
      bool hasChanges = false;

      // --- Download new files ---
      final filesToDownload = group.files.where((f) {
        if (f.contentType == 'application/x-directory') return false;
        return !syncMeta.containsKey(f.id);
      }).toList();

      if (filesToDownload.isNotEmpty) {
        hasChanges = true;
        debugPrint('[CollabFolderSync] Downloading ${filesToDownload.length} files for $groupId');

        for (final file in filesToDownload) {
          try {
            final data = await CollaborationService.instance.downloadCollabFile(groupId, file);
            final localPath = _resolveLocalPath(folderPath, file);
            final localFile = File(localPath);
            await localFile.parent.create(recursive: true);
            await localFile.writeAsBytes(data);

            syncMeta[file.id] = _SyncedFileEntry(
              fileName: file.fileName,
              direction: 'download',
              syncedAt: DateTime.now(),
            );
            debugPrint('[CollabFolderSync] Downloaded: ${file.fileName}');
          } catch (e) {
            debugPrint('[CollabFolderSync] Download failed (${file.fileName}): $e');
            final errStr = e.toString();
            if (errStr.contains('404')) {
              syncMeta[file.id] = _SyncedFileEntry(
                fileName: file.fileName,
                direction: 'download_failed',
                syncedAt: DateTime.now(),
              );
            }
          }
        }
      }

      // --- Propagate remote deletions (tombstones) to local ---
      final removedIds = group.removedFileIds.toSet();
      if (removedIds.isNotEmpty) {
        final entriesToRemove = <String>[];
        for (final entry in syncMeta.entries) {
          if (entry.value.direction == 'download_failed') continue;
          if (removedIds.contains(entry.key)) {
            final localPath = '$folderPath${Platform.pathSeparator}${entry.value.fileName}';
            final localFile = File(localPath);
            if (await localFile.exists()) {
              try {
                await localFile.delete();
                debugPrint('[CollabFolderSync] Deleted local file (remote removal): ${entry.value.fileName}');
                hasChanges = true;
              } catch (e) {
                debugPrint('[CollabFolderSync] Failed to delete local file: $localPath: $e');
              }
            }
            entriesToRemove.add(entry.key);
          }
        }
        for (final id in entriesToRemove) {
          syncMeta.remove(id);
        }
      }

      // --- Adjust poll interval ---
      if (hasChanges) {
        _currentPollInterval[groupId] = _minPollInterval;
        await _writeSyncMeta(folderPath, groupId, syncMeta);
      } else {
        final current = _currentPollInterval[groupId] ?? _minPollInterval;
        if (current < _maxPollInterval) {
          _currentPollInterval[groupId] = Duration(
            seconds: (current.inSeconds * 2).clamp(
              _minPollInterval.inSeconds,
              _maxPollInterval.inSeconds,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[CollabFolderSync] Poll error ($groupId): $e');
    } finally {
      _syncing[groupId] = false;
      if (_watchers.containsKey(groupId)) {
        _schedulePoll(groupId);
      }
    }
  }

  // ============================================================================
  // UPLOAD SYNC (local → remote)
  // ============================================================================

  /// Scan existing files in the folder and upload any not yet in the manifest.
  Future<void> _scanAndUploadExistingFiles(String groupId, String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) return;

    debugPrint('[CollabFolderSync] Scanning existing files in $folderPath');
    int uploaded = 0;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final fileName = entity.path.split(Platform.pathSeparator).last;
      if (fileName == _syncMetaFile || fileName.startsWith('.')) continue;

      await _uploadLocalFileIfNew(groupId, entity.path);
      uploaded++;
    }

    debugPrint('[CollabFolderSync] Scan complete: processed $uploaded files');
  }

  void _handleLocalFileChange(String groupId, FileSystemEvent event) {
    // Handle file creation, modification, and deletion
    if (event is! FileSystemCreateEvent &&
        event is! FileSystemModifyEvent &&
        event is! FileSystemDeleteEvent) return;

    final path = event.path;
    final fileName = path.split(Platform.pathSeparator).last;

    // Skip sync metadata and hidden files
    if (fileName == _syncMetaFile || fileName.startsWith('.')) return;

    // Handle deletions immediately (file no longer exists on disk)
    if (event is FileSystemDeleteEvent) {
      debugPrint('[CollabFolderSync] File deletion detected: $fileName for group $groupId');
      _handleLocalFileDeletion(groupId, path);
      return;
    }

    // Skip directories (only for create/modify — deleted paths can't be checked)
    if (FileSystemEntity.isDirectorySync(path)) return;

    debugPrint('[CollabFolderSync] File change detected: $fileName (${event.runtimeType}) for group $groupId');

    // Debounce: cancel any pending upload for this path, reschedule
    _uploadDebounce[path]?.cancel();
    _uploadDebounce[path] = Timer(const Duration(seconds: 3), () {
      _uploadDebounce.remove(path);
      _uploadLocalFileIfNew(groupId, path);
    });
  }

  /// Handle deletion of a local file: find its collab ID from sync metadata,
  /// remove from the collaboration manifest, and clean up sync metadata.
  Future<void> _handleLocalFileDeletion(String groupId, String filePath) async {
    try {
      final info = await _getGroupInfo(groupId);
      if (info == null || info.folderPath == null) return;

      final folderPath = info.folderPath!;
      final fileName = filePath.split(Platform.pathSeparator).last;
      final syncMeta = await _readSyncMeta(folderPath);

      // Find the file ID by matching fileName in sync metadata
      String? matchedFileId;
      for (final entry in syncMeta.entries) {
        if (entry.value.fileName == fileName &&
            (entry.value.direction == 'upload' || entry.value.direction == 'download')) {
          matchedFileId = entry.key;
          break;
        }
      }

      // If not in sync metadata, fall back to searching the manifest by fileName
      // (handles files added before sync metadata tracking or after a metadata reset)
      if (matchedFileId == null) {
        debugPrint('[CollabFolderSync] File not in sync metadata, checking manifest: $fileName');
        final group = info.group;
        for (final f in group.files) {
          if (f.fileName == fileName) {
            matchedFileId = f.id;
            break;
          }
        }
      }

      if (matchedFileId == null) {
        debugPrint('[CollabFolderSync] Deleted file not found in sync metadata or manifest: $fileName');
        return;
      }

      debugPrint('[CollabFolderSync] Propagating deletion: $fileName (fileId=$matchedFileId)');
      _emitStatus(groupId, CollabSyncState.syncing);

      await CollaborationService.instance.removeFileFromGroup(
        groupId: groupId,
        fileId: matchedFileId,
      );

      syncMeta.remove(matchedFileId);
      await _writeSyncMeta(folderPath, groupId, syncMeta);

      debugPrint('[CollabFolderSync] Deletion propagated: $fileName');
      _emitStatus(groupId, CollabSyncState.synced);
    } catch (e) {
      debugPrint('[CollabFolderSync] Deletion propagation error ($filePath): $e');
      _emitStatus(groupId, CollabSyncState.error);
    }
  }

  Future<void> _uploadLocalFileIfNew(String groupId, String filePath) async {
    try {
      final info = await _getGroupInfo(groupId);
      if (info == null || info.folderPath == null || info.linkSecretKey == null) {
        debugPrint('[CollabFolderSync] Skipping upload: group info missing (info=${info != null}, folder=${info?.folderPath != null}, key=${info?.linkSecretKey != null})');
        return;
      }

      final folderPath = info.folderPath!;
      final file = File(filePath);
      if (!await file.exists()) return;

      final fileSize = await file.length();
      if (fileSize == 0 || fileSize > _maxFileSize) {
        debugPrint('[CollabFolderSync] Skipping file (size=$fileSize): $filePath');
        return;
      }

      // Check if already synced (by filename match in sync metadata)
      final syncMeta = await _readSyncMeta(folderPath);
      final fileName = filePath.split(Platform.pathSeparator).last;

      // Find any existing sync entry for this fileName
      String? existingSyncId;
      _SyncedFileEntry? existingEntry;
      for (final entry in syncMeta.entries) {
        if (entry.value.fileName == fileName) {
          existingSyncId = entry.key;
          existingEntry = entry.value;
          break;
        }
      }

      if (existingEntry != null && existingSyncId != null) {
        // Check if this file was tombstoned (deleted from manifest).
        // If so, clear the stale sync metadata so the re-add is treated as new.
        final tombstoned = info.group.removedFileIds.contains(existingSyncId);
        if (tombstoned) {
          debugPrint('[CollabFolderSync] Clearing stale sync entry for re-added file: $fileName');
          syncMeta.remove(existingSyncId);
          await _writeSyncMeta(folderPath, groupId, syncMeta);
        } else if (existingEntry.direction == 'upload') {
          debugPrint('[CollabFolderSync] Skipping $fileName: already uploaded');
          return;
        } else if (existingEntry.direction == 'download') {
          debugPrint('[CollabFolderSync] Skipping $fileName: was downloaded');
          return;
        }
      }

      // Skip files that previously failed with non-retryable errors
      if (_permanentlyFailed.contains(filePath)) return;

      debugPrint('[CollabFolderSync] Uploading new file: $fileName (${(fileSize / 1024).toStringAsFixed(1)} KB)');
      _emitStatus(groupId, CollabSyncState.syncing);

      final fileData = await file.readAsBytes();
      final contentType = lookupMimeType(fileName);

      // Compute pathScope relative to folder root
      final relativePath = filePath.substring(folderPath.length + 1);
      final parts = relativePath.split(Platform.pathSeparator);
      final pathScope = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : null;

      // Use collab encryption upload (works for both sender and receiver)
      final collabFile = await CollaborationService.instance.uploadCollabFileFromLocal(
        groupId: groupId,
        fileName: fileName,
        fileData: fileData,
        linkSecretKey: info.linkSecretKey!,
        contentType: contentType,
        pathScope: pathScope,
      );

      // Track in sync metadata
      syncMeta[collabFile.id] = _SyncedFileEntry(
        fileName: fileName,
        direction: 'upload',
        syncedAt: DateTime.now(),
      );
      await _writeSyncMeta(folderPath, groupId, syncMeta);

      debugPrint('[CollabFolderSync] Uploaded: $fileName');
      _emitStatus(groupId, CollabSyncState.synced);
    } catch (e) {
      debugPrint('[CollabFolderSync] Upload error ($filePath): $e');
      // Don't retry non-retryable server errors (413 = payload too large, 400 = bad request)
      final errStr = e.toString();
      if (errStr.contains('413') || errStr.contains('400')) {
        _permanentlyFailed.add(filePath);
        debugPrint('[CollabFolderSync] File permanently failed (non-retryable): $filePath');
      }
      _emitStatus(groupId, CollabSyncState.error);
    }
  }

  // ============================================================================
  // HELPERS
  // ============================================================================

  String _resolveLocalPath(String folderPath, CollaborationFile file) {
    if (file.pathScope != null && file.pathScope!.isNotEmpty) {
      return '$folderPath${Platform.pathSeparator}${file.pathScope!.replaceAll('/', Platform.pathSeparator)}${Platform.pathSeparator}${file.fileName}';
    }
    return '$folderPath${Platform.pathSeparator}${file.fileName}';
  }

  Future<_GroupInfo?> _getGroupInfo(String groupId) async {
    final service = CollaborationService.instance;
    final outgoingList = await service.getOutgoingCollaborations();
    for (final c in outgoingList) {
      if (c.id == groupId) {
        return _GroupInfo(
          group: c.group,
          folderPath: c.localFolderPath,
          linkSecretKey: c.linkSecretKey,
          isOwner: true,
        );
      }
    }

    final acceptedList = await service.getAcceptedCollaborations();
    for (final c in acceptedList) {
      if (c.id == groupId) {
        return _GroupInfo(
          group: c.group,
          folderPath: c.localFolderPath,
          linkSecretKey: c.linkSecretKey,
          isOwner: false,
        );
      }
    }

    return null;
  }

  /// Clear sync metadata if it belongs to a different collab group.
  /// This prevents stale entries from a previous group on the same folder
  /// from blocking uploads for the new group.
  Future<void> _resetSyncMetaIfDifferentGroup(String groupId, String folderPath) async {
    final file = File('$folderPath${Platform.pathSeparator}$_syncMetaFile');
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final storedGroupId = json['groupId'] as String?;
      if (storedGroupId != null && storedGroupId != groupId) {
        debugPrint('[CollabFolderSync] Clearing stale sync meta (was group $storedGroupId, now $groupId)');
        await file.delete();
      }
    } catch (e) {
      debugPrint('[CollabFolderSync] Failed to check sync meta group: $e');
    }
  }

  Future<Map<String, _SyncedFileEntry>> _readSyncMeta(String folderPath) async {
    final file = File('$folderPath${Platform.pathSeparator}$_syncMetaFile');
    if (!await file.exists()) return {};
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final synced = json['syncedFiles'] as Map<String, dynamic>? ?? {};
      return synced.map((k, v) => MapEntry(k, _SyncedFileEntry.fromJson(v as Map<String, dynamic>)));
    } catch (e) {
      debugPrint('[CollabFolderSync] Failed to read sync meta: $e');
      return {};
    }
  }

  Future<void> _writeSyncMeta(String folderPath, String groupId, Map<String, _SyncedFileEntry> syncMeta) async {
    final file = File('$folderPath${Platform.pathSeparator}$_syncMetaFile');
    final json = {
      'groupId': groupId,
      'syncedFiles': syncMeta.map((k, v) => MapEntry(k, v.toJson())),
      'lastPollAt': DateTime.now().toIso8601String(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  }

  void _emitStatus(String groupId, CollabSyncState state) {
    _statusController.add(CollabSyncStatus(groupId: groupId, state: state));
  }

  void dispose() {
    _currentPollInterval.clear();
    for (final w in _watchers.values) {
      w.cancel();
    }
    _watchers.clear();
    for (final t in _pollTimers.values) {
      t.cancel();
    }
    _pollTimers.clear();
    for (final t in _uploadDebounce.values) {
      t.cancel();
    }
    _uploadDebounce.clear();
    _permanentlyFailed.clear();
    _statusController.close();
  }
}

// ============================================================================
// Helper types
// ============================================================================

class _GroupInfo {
  final CollaborationGroup group;
  final String? folderPath;
  final Uint8List? linkSecretKey;
  final bool isOwner;

  _GroupInfo({
    required this.group,
    this.folderPath,
    this.linkSecretKey,
    required this.isOwner,
  });
}

class _SyncedFileEntry {
  final String fileName;
  final String direction; // 'upload' or 'download'
  final DateTime syncedAt;

  _SyncedFileEntry({required this.fileName, required this.direction, required this.syncedAt});

  Map<String, dynamic> toJson() => {
    'fileName': fileName,
    'direction': direction,
    'syncedAt': syncedAt.toIso8601String(),
  };

  factory _SyncedFileEntry.fromJson(Map<String, dynamic> json) => _SyncedFileEntry(
    fileName: json['fileName'] as String,
    direction: json['direction'] as String,
    syncedAt: DateTime.parse(json['syncedAt'] as String),
  );
}

enum CollabSyncState { idle, syncing, synced, error }

class CollabSyncStatus {
  final String groupId;
  final CollabSyncState state;

  CollabSyncStatus({required this.groupId, required this.state});
}
