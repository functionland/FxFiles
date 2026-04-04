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

  // Listeners for sync status changes
  final _statusController = StreamController<CollabSyncStatus>.broadcast();
  Stream<CollabSyncStatus> get onStatusChange => _statusController.stream;

  /// Initialize: restore syncs for all groups with syncEnabled
  Future<void> init() async {
    try {
      final service = CollaborationService.instance;
      final outgoing = await service.getOutgoingCollaborations();
      final accepted = await service.getAcceptedCollaborations();

      for (final c in outgoing) {
        if (c.syncEnabled && c.localFolderPath != null) {
          await startSync(c.id);
        }
      }
      for (final c in accepted) {
        if (c.syncEnabled && c.localFolderPath != null) {
          await startSync(c.id);
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

    // Update persistence
    await CollaborationService.instance.updateFolderAssignment(
      groupId,
      folderPath: folderPath,
      syncEnabled: true,
    );

    // Initial download of existing files
    await _pollForNewFiles(groupId);

    // Start watching + polling
    await startSync(groupId);

    _emitStatus(groupId, CollabSyncState.synced);
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
    // Prevent duplicates
    await stopSync(groupId);

    final info = await _getGroupInfo(groupId);
    if (info == null || info.folderPath == null) return;

    final folderPath = info.folderPath!;

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

      // Find files not yet downloaded
      final filesToDownload = group.files.where((f) {
        if (f.contentType == 'application/x-directory') return false; // skip folder markers
        return !syncMeta.containsKey(f.id);
      }).toList();

      if (filesToDownload.isEmpty) {
        // No changes — back off poll interval (double, up to max)
        final current = _currentPollInterval[groupId] ?? _minPollInterval;
        if (current < _maxPollInterval) {
          _currentPollInterval[groupId] = Duration(
            seconds: (current.inSeconds * 2).clamp(
              _minPollInterval.inSeconds,
              _maxPollInterval.inSeconds,
            ),
          );
        }
        return;
      }

      // Changes found — reset to fast polling
      _currentPollInterval[groupId] = _minPollInterval;

      debugPrint('[CollabFolderSync] Downloading ${filesToDownload.length} files for $groupId');

      for (final file in filesToDownload) {
        try {
          final data = await CollaborationService.instance.downloadCollabFile(groupId, file);

          // Determine local file path (handle pathScope subfolders)
          final localPath = _resolveLocalPath(folderPath, file);
          final localFile = File(localPath);

          // Ensure parent directory exists
          await localFile.parent.create(recursive: true);
          await localFile.writeAsBytes(data);

          // Track in sync metadata
          syncMeta[file.id] = _SyncedFileEntry(
            fileName: file.fileName,
            direction: 'download',
            syncedAt: DateTime.now(),
          );

          debugPrint('[CollabFolderSync] Downloaded: ${file.fileName}');
        } catch (e) {
          debugPrint('[CollabFolderSync] Download failed (${file.fileName}): $e');
          // Track 404 failures to avoid retrying missing files every poll
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

      await _writeSyncMeta(folderPath, groupId, syncMeta);
    } catch (e) {
      debugPrint('[CollabFolderSync] Poll error ($groupId): $e');
    } finally {
      _syncing[groupId] = false;
      // Reschedule next poll (only if sync is still active for this group)
      if (_watchers.containsKey(groupId)) {
        _schedulePoll(groupId);
      }
    }
  }

  // ============================================================================
  // UPLOAD SYNC (local → remote)
  // ============================================================================

  void _handleLocalFileChange(String groupId, FileSystemEvent event) {
    // Only handle file creation/modification
    if (event is! FileSystemCreateEvent && event is! FileSystemModifyEvent) return;

    final path = event.path;
    final fileName = path.split(Platform.pathSeparator).last;

    // Skip sync metadata and hidden files
    if (fileName == _syncMetaFile || fileName.startsWith('.')) return;

    // Skip directories
    if (FileSystemEntity.isDirectorySync(path)) return;

    // Debounce: cancel any pending upload for this path, reschedule
    _uploadDebounce[path]?.cancel();
    _uploadDebounce[path] = Timer(const Duration(seconds: 3), () {
      _uploadDebounce.remove(path);
      _uploadLocalFileIfNew(groupId, path);
    });
  }

  Future<void> _uploadLocalFileIfNew(String groupId, String filePath) async {
    try {
      final info = await _getGroupInfo(groupId);
      if (info == null || info.folderPath == null || info.linkSecretKey == null) return;

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

      // Skip if any entry with same fileName already uploaded
      final alreadyUploaded = syncMeta.values.any(
        (e) => e.fileName == fileName && e.direction == 'upload',
      );
      if (alreadyUploaded) return;

      // Also skip if the file was just downloaded (avoid re-uploading downloads)
      final justDownloaded = syncMeta.values.any(
        (e) => e.fileName == fileName && e.direction == 'download',
      );
      if (justDownloaded) return;

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
