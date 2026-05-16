import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/core/utils/safe_path.dart';

/// Download-only folder sync for accepted shares (one-way mirror).
///
/// Mirrors [CollabFolderSyncService] for the parts that apply to a one-way
/// share: adaptive polling, server → local download, sync metadata in a
/// `.share-sync.json` file at the folder root. Deliberately omits everything
/// collab needs for the writer side — no `Directory.watch`, no upload, no
/// debounce-and-publish, no manifest writes back.
///
/// Local additions are left alone (per design): if the recipient drops their
/// own files into the synced folder, they stay; we only download what comes
/// from the share. Name collisions skip with a log line rather than
/// overwriting user-owned files.
class ShareFolderSyncService {
  ShareFolderSyncService._();
  static final ShareFolderSyncService instance = ShareFolderSyncService._();

  static const Duration _minPollInterval = Duration(seconds: 60);
  static const Duration _maxPollInterval = Duration(minutes: 5);
  static const String _syncMetaFile = '.share-sync.json';

  final Map<String, Timer> _pollTimers = {};
  final Set<String> _activeShareIds = {};
  final Map<String, bool> _syncing = {};
  final Set<String> _startingSync = {};
  final Map<String, Duration> _currentPollInterval = {};

  // Per-share in-memory share handles. Acquired from
  // FulaApiService.acceptShareToken on demand; lost on app restart and
  // refreshed lazily by [_ensureShareHandle].
  final Map<String, fula.AcceptedShareHandle> _handles = {};

  final _statusController = StreamController<ShareSyncStatus>.broadcast();
  Stream<ShareSyncStatus> get onStatusChange => _statusController.stream;

  /// Initialise: restore syncs for every accepted share with
  /// `syncEnabled == true && localFolderPath != null`.
  Future<void> init() async {
    try {
      final shares = await SharingService.instance.getAcceptedShares();
      final toSync = <String, String>{}; // shareId → folderPath
      for (final s in shares) {
        if (!s.syncEnabled) continue;
        final path = s.localFolderPath;
        if (path == null || path.isEmpty) continue;
        // De-dupe by folder path so two shares pointing at the same folder
        // don't fight each other on the wire. Last share wins (matches
        // CollabFolderSyncService's contains() guard).
        if (toSync.values.contains(path)) {
          debugPrint(
              '[ShareFolderSync] Skipping duplicate folder for share "${s.token.id}" → $path');
          continue;
        }
        toSync[s.token.id] = path;
      }
      for (final entry in toSync.entries) {
        try {
          await _startSyncDirect(entry.key, entry.value);
        } catch (e) {
          debugPrint(
              '[ShareFolderSync] Failed to start sync for ${entry.key}: $e');
        }
      }
      debugPrint(
          '[ShareFolderSync] Initialized. Active syncs: ${_activeShareIds.length}');
    } catch (e) {
      debugPrint('[ShareFolderSync] Init error: $e');
    }
  }

  /// Assign a local folder to an accepted share, download files, start
  /// background sync. The "Accept & Start Sync" button calls this.
  Future<void> assignFolder(String shareId, String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Clear stale sync metadata from a previous share on this folder so the
    // first poll re-downloads from scratch instead of treating an unrelated
    // entry as "already synced".
    await _resetSyncMetaIfDifferentShare(shareId, folderPath);

    await SharingService.instance.updateAcceptedShareFolderAssignment(
      shareId,
      folderPath: folderPath,
      syncEnabled: true,
    );

    await startSync(shareId);

    // Initial download happens in the background so the AcceptShareScreen
    // can pop immediately. The share appears in the Accepted-Shares tab with
    // a "syncing…" status until the first poll completes.
    unawaited(_initialSyncInBackground(shareId, folderPath));
  }

  Future<void> _initialSyncInBackground(String shareId, String folderPath) async {
    try {
      _emitStatus(shareId, ShareSyncState.syncing);
      await _pollForNewFiles(shareId);
      _emitStatus(shareId, ShareSyncState.synced);
    } catch (e) {
      debugPrint('[ShareFolderSync] Background initial sync error ($shareId): $e');
      _emitStatus(shareId, ShareSyncState.error);
    }
  }

  /// Remove the folder assignment and stop polling for this share.
  Future<void> unassignFolder(String shareId) async {
    await stopSync(shareId);
    await SharingService.instance.updateAcceptedShareFolderAssignment(
      shareId,
      folderPath: '', // empty clears the field
      syncEnabled: false,
    );
    _emitStatus(shareId, ShareSyncState.idle);
  }

  /// Start polling for a share. Idempotent; concurrent calls are deduped via
  /// [_startingSync].
  Future<void> startSync(String shareId) async {
    if (_startingSync.contains(shareId)) return;
    _startingSync.add(shareId);
    try {
      final info = await _getShareInfo(shareId);
      if (info == null || info.folderPath == null) return;
      await _startSyncDirect(shareId, info.folderPath!);
    } finally {
      _startingSync.remove(shareId);
    }
  }

  Future<void> _startSyncDirect(String shareId, String folderPath) async {
    await stopSync(shareId);
    _activeShareIds.add(shareId);
    _currentPollInterval[shareId] = _minPollInterval;
    _schedulePoll(shareId);
    _emitStatus(shareId, ShareSyncState.synced);
  }

  /// Stop polling for a share. Safe to call when no sync is active.
  Future<void> stopSync(String shareId) async {
    _activeShareIds.remove(shareId);
    _pollTimers[shareId]?.cancel();
    _pollTimers.remove(shareId);
    _currentPollInterval.remove(shareId);
  }

  /// Trigger an immediate sync (used by the "Sync now" action on the
  /// AcceptedShareCard).
  Future<void> syncNow(String shareId) async {
    _currentPollInterval[shareId] = _minPollInterval;
    _emitStatus(shareId, ShareSyncState.syncing);
    await _pollForNewFiles(shareId);
    _emitStatus(shareId, ShareSyncState.synced);
  }

  /// Whether background polling is currently active for [shareId].
  bool isSyncActive(String shareId) => _activeShareIds.contains(shareId);

  /// Resolve the local folder for a share, or null when not assigned.
  Future<String?> getFolderPath(String shareId) async {
    final info = await _getShareInfo(shareId);
    return info?.folderPath;
  }

  /// Refresh active watchers after an app resume (mirrors collab service so
  /// callers can plumb a single lifecycle hook for both).
  Future<void> onAppResumed() async {
    final ids = List<String>.from(_activeShareIds);
    if (ids.isEmpty) return;
    debugPrint('[ShareFolderSync] onAppResumed - re-polling ${ids.length} shares');
    for (final id in ids) {
      _currentPollInterval[id] = _minPollInterval;
      _schedulePoll(id);
    }
  }

  // ============================================================================
  // DOWNLOAD SYNC (remote → local). No upload counterpart for one-way shares.
  // ============================================================================

  void _schedulePoll(String shareId) {
    _pollTimers[shareId]?.cancel();
    final interval = _currentPollInterval[shareId] ?? _minPollInterval;
    _pollTimers[shareId] = Timer(interval, () {
      _pollForNewFiles(shareId);
    });
  }

  Future<void> _pollForNewFiles(String shareId) async {
    if (_syncing[shareId] == true) return;
    _syncing[shareId] = true;

    try {
      final info = await _getShareInfo(shareId);
      if (info == null || info.folderPath == null) return;
      if (info.share.isExpired || info.share.isRevoked) {
        debugPrint(
            '[ShareFolderSync] Share $shareId is expired/revoked — pausing sync');
        await stopSync(shareId);
        _emitStatus(shareId, ShareSyncState.error);
        return;
      }

      final folderPath = info.folderPath!;
      final syncMeta = await _readSyncMeta(folderPath);
      bool hasChanges = false;

      final share = info.share;
      final handle = await _ensureShareHandle(share);
      if (handle == null) {
        debugPrint(
            '[ShareFolderSync] Cannot acquire share handle for $shareId — skipping poll');
        return;
      }

      // List every object inside the share's pathScope. fula_client honours
      // the recipient's accepted-share handle internally, so this returns
      // exactly the files the recipient is entitled to.
      final List<FulaObject> objects;
      try {
        objects = await FulaApiService.instance.listObjects(
          share.bucket,
          prefix: share.pathScope,
        );
      } catch (e) {
        debugPrint('[ShareFolderSync] listObjects failed ($shareId): $e');
        return;
      }
      final fileObjects = objects.where((o) => !o.isDirectory).toList();

      for (final obj in fileObjects) {
        // Key against the object's path; same key in syncMeta = already
        // downloaded. v1 doesn't detect content-only updates (no etag check)
        // — that's a future enhancement.
        final entry = syncMeta[obj.key];
        if (entry != null && entry.direction == 'download') continue;

        final localPath = _resolveLocalPath(folderPath, share.pathScope, obj.key);
        if (localPath == null) {
          syncMeta[obj.key] = _SyncedFileEntry(
            fileName: obj.name,
            direction: 'download_failed',
            syncedAt: DateTime.now(),
          );
          continue;
        }

        // Refuse to overwrite a file the recipient placed in the folder
        // themselves. Skip + log, leaving the user's copy intact.
        final localFile = File(localPath);
        if (localFile.existsSync() && entry == null) {
          debugPrint(
              '[ShareFolderSync] Skip (local file already exists, not from share): ${obj.key}');
          syncMeta[obj.key] = _SyncedFileEntry(
            fileName: obj.name,
            direction: 'skipped_collision',
            syncedAt: DateTime.now(),
          );
          continue;
        }

        try {
          final data = await FulaApiService.instance.downloadSharedFile(
            share.bucket,
            obj.storageKey ?? obj.key,
            obj.key,
            handle,
          );
          await localFile.parent.create(recursive: true);
          await localFile.writeAsBytes(data);
          syncMeta[obj.key] = _SyncedFileEntry(
            fileName: obj.name,
            direction: 'download',
            syncedAt: DateTime.now(),
          );
          hasChanges = true;
          debugPrint('[ShareFolderSync] Downloaded: ${obj.key}');
        } catch (e) {
          debugPrint('[ShareFolderSync] Download failed (${obj.key}): $e');
          // Only persist a failure marker for non-transient errors so a flaky
          // network doesn't permanently lock the file out.
          final errStr = e.toString();
          if (errStr.contains('404') || errStr.contains('410')) {
            syncMeta[obj.key] = _SyncedFileEntry(
              fileName: obj.name,
              direction: 'download_failed',
              syncedAt: DateTime.now(),
            );
          }
        }
      }

      if (hasChanges) {
        _currentPollInterval[shareId] = _minPollInterval;
        await _writeSyncMeta(folderPath, shareId, syncMeta);
      } else {
        final current = _currentPollInterval[shareId] ?? _minPollInterval;
        if (current < _maxPollInterval) {
          _currentPollInterval[shareId] = Duration(
            seconds: (current.inSeconds * 2).clamp(
              _minPollInterval.inSeconds,
              _maxPollInterval.inSeconds,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[ShareFolderSync] Poll error ($shareId): $e');
    } finally {
      _syncing[shareId] = false;
      if (_activeShareIds.contains(shareId)) {
        _schedulePoll(shareId);
      }
    }
  }

  // ============================================================================
  // HELPERS
  // ============================================================================

  /// Returns the local target path for a remote object, or null when the
  /// supplied key would escape [folderPath] (defence-in-depth against
  /// hostile manifest entries even though fula_client should already scope
  /// to [pathScope]).
  String? _resolveLocalPath(String folderPath, String pathScope, String objectKey) {
    // Strip the share's pathScope prefix so the local mirror starts at the
    // share root (`<folder>/<file>` rather than `<folder>/<bucket>/<...>`).
    String relative = objectKey;
    if (relative.startsWith(pathScope)) {
      relative = relative.substring(pathScope.length);
    }
    final parts = <String>[];
    for (final segment in relative.split(RegExp(r'[\\/]'))) {
      final s = sanitizeFileName(segment);
      if (s.isEmpty) continue;
      parts.add(s);
    }
    if (parts.isEmpty) return null;
    try {
      return safeJoin(folderPath, parts.join(Platform.pathSeparator));
    } on FormatException catch (e) {
      debugPrint('[ShareFolderSync] Skipping unsafe path: ${e.message}');
      return null;
    }
  }

  Future<fula.AcceptedShareHandle?> _ensureShareHandle(AcceptedShare share) async {
    final cached = _handles[share.token.id];
    if (cached != null) return cached;
    final tokenJson = share.fulaShareToken ?? share.token.fulaShareToken;
    if (tokenJson == null) {
      debugPrint(
          '[ShareFolderSync] Share ${share.token.id} has no fula token — '
          'cannot sync');
      return null;
    }
    try {
      final handle = await FulaApiService.instance.acceptShareToken(tokenJson);
      _handles[share.token.id] = handle;
      return handle;
    } catch (e) {
      debugPrint(
          '[ShareFolderSync] acceptShareToken failed for ${share.token.id}: $e');
      return null;
    }
  }

  Future<_ShareInfo?> _getShareInfo(String shareId) async {
    final share = await SharingService.instance.findAcceptedShare(shareId);
    if (share == null) return null;
    return _ShareInfo(share: share, folderPath: share.localFolderPath);
  }

  Future<void> _resetSyncMetaIfDifferentShare(
      String shareId, String folderPath) async {
    final file = File('$folderPath${Platform.pathSeparator}$_syncMetaFile');
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final storedShareId = json['shareId'] as String?;
      if (storedShareId != null && storedShareId != shareId) {
        debugPrint(
            '[ShareFolderSync] Clearing stale sync meta (was share $storedShareId, now $shareId)');
        await file.delete();
      }
    } catch (e) {
      debugPrint('[ShareFolderSync] Failed to check sync meta share: $e');
    }
  }

  Future<Map<String, _SyncedFileEntry>> _readSyncMeta(String folderPath) async {
    final file = File('$folderPath${Platform.pathSeparator}$_syncMetaFile');
    if (!await file.exists()) return {};
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final synced = json['syncedFiles'] as Map<String, dynamic>? ?? {};
      return synced.map(
          (k, v) => MapEntry(k, _SyncedFileEntry.fromJson(v as Map<String, dynamic>)));
    } catch (e) {
      debugPrint('[ShareFolderSync] Failed to read sync meta: $e');
      return {};
    }
  }

  Future<void> _writeSyncMeta(
      String folderPath, String shareId, Map<String, _SyncedFileEntry> syncMeta) async {
    final file = File('$folderPath${Platform.pathSeparator}$_syncMetaFile');
    final json = {
      'shareId': shareId,
      'syncedFiles': syncMeta.map((k, v) => MapEntry(k, v.toJson())),
      'lastPollAt': DateTime.now().toIso8601String(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  }

  void _emitStatus(String shareId, ShareSyncState state) {
    _statusController.add(ShareSyncStatus(shareId: shareId, state: state));
  }

  void dispose() {
    _currentPollInterval.clear();
    for (final t in _pollTimers.values) {
      t.cancel();
    }
    _pollTimers.clear();
    _activeShareIds.clear();
    _handles.clear();
    _statusController.close();
  }
}

class _ShareInfo {
  final AcceptedShare share;
  final String? folderPath;
  _ShareInfo({required this.share, this.folderPath});
}

class _SyncedFileEntry {
  final String fileName;
  final String direction; // 'download', 'download_failed', 'skipped_collision'
  final DateTime syncedAt;

  _SyncedFileEntry({
    required this.fileName,
    required this.direction,
    required this.syncedAt,
  });

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'direction': direction,
        'syncedAt': syncedAt.toIso8601String(),
      };

  factory _SyncedFileEntry.fromJson(Map<String, dynamic> json) =>
      _SyncedFileEntry(
        fileName: json['fileName'] as String,
        direction: json['direction'] as String,
        syncedAt: DateTime.parse(json['syncedAt'] as String),
      );
}

enum ShareSyncState { idle, syncing, synced, error }

class ShareSyncStatus {
  final String shareId;
  final ShareSyncState state;
  ShareSyncStatus({required this.shareId, required this.state});
}
