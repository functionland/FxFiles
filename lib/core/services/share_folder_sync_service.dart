import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:http/http.dart' as http;
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
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

      // ─── Fetch + parse the share manifest from pinning-webui's
      //    share-aware endpoint (cross-account safe).
      //
      //    Why this replaces the prior `listObjects(share.bucket, ...)`:
      //    `listObjects` hits master with the recipient's JWT and is
      //    user-scoped — it returns the recipient's namespace, not the
      //    owner's. For ANY cross-account share, that returns either
      //    empty or NoSuchBucket. The manifest at
      //    `/api/share/v2/manifest/{shareId}` is uploaded by the owner
      //    at share-creation time (see
      //    `sharing_service.dart::_postManifest`) and validated by
      //    share-id/expiry, not by JWT — so the recipient can fetch
      //    it cross-account.
      final manifest = await _fetchAndParseManifest(share);
      if (manifest == null) {
        debugPrint(
            '[ShareFolderSync] Manifest unavailable for $shareId — skipping poll');
        return;
      }

      final bucket = (manifest['bucket'] as String?) ?? share.bucket;
      final pathScope =
          (manifest['pathScope'] as String?) ?? share.pathScope;
      final files = (manifest['files'] as List?) ?? const [];

      // Determine which secret unwraps each per-file share token:
      //   * Type 1/2 (public link / password): URL-embedded
      //     `linkSecretKey` (`AcceptedShare.linkSecretKey`). Each
      //     per-file token in the manifest was wrapped to the link's
      //     ephemeral pubkey at owner-side creation time, so the
      //     matching ephemeral private key is what unwraps.
      //   * Type 3 (specific recipient): the recipient's signed-in
      //     master KEK. Per-file tokens were wrapped to recipient's
      //     pubkey, which derives from master KEK.
      //
      // Both paths target the same SDK call (`fula.getWithToken`); the
      // only difference is which secret seeds the ephemeral
      // fula_client. The proxy at `/api/share/v2/fetch` doesn't
      // user-scope, so both cases work cross-account.
      final Uint8List secretKey;
      if (share.linkSecretKey != null) {
        secretKey = share.linkSecretKey!;
      } else {
        final k = await AuthService.instance.getEncryptionKey();
        if (k == null) {
          debugPrint(
              '[ShareFolderSync] No encryption key for Type 3 share $shareId — '
              'skipping poll (user must be signed in)');
          return;
        }
        secretKey = k;
      }

      // Build ONE ephemeral fula_client pointed at the share proxy and
      // reuse it for every file in this poll. The proxy is share-token
      // aware (validates by token, not JWT), so cross-account works.
      final shareClient = await _buildShareClient(secretKey);

      for (final entry in files) {
        if (entry is! Map) continue;
        // Manifest entry shape (see
        // `sharing_service.dart::_buildManifestEntries`): keys are
        // intentionally single-letter to keep the encrypted blob small.
        final displayName = entry['n'] as String?;
        final storageKey = entry['c'] as String?;
        final tokenJson = entry['t'] as String?;
        if (displayName == null ||
            storageKey == null ||
            tokenJson == null) {
          continue;
        }

        // Skip files already downloaded in a prior poll. Keyed by
        // displayName because that's stable across polls (storageKey
        // depends on the per-file DEK and HMAC).
        final entryRecord = syncMeta[displayName];
        if (entryRecord != null && entryRecord.direction == 'download') {
          continue;
        }

        // Reconstruct the full key path for _resolveLocalPath (it
        // strips pathScope off the front to produce the local relative
        // path). The manifest's displayName is ALREADY pathScope-
        // stripped, so we re-prepend pathScope before passing through.
        final String reconstructedKey;
        if (pathScope.isEmpty || displayName.startsWith(pathScope)) {
          reconstructedKey = displayName;
        } else if (pathScope.endsWith('/')) {
          reconstructedKey = '$pathScope$displayName';
        } else {
          reconstructedKey = '$pathScope/$displayName';
        }

        final localPath =
            _resolveLocalPath(folderPath, pathScope, reconstructedKey);
        if (localPath == null) {
          syncMeta[displayName] = _SyncedFileEntry(
            fileName: displayName,
            direction: 'download_failed',
            syncedAt: DateTime.now(),
          );
          continue;
        }

        // Refuse to overwrite a file the recipient placed in the folder
        // themselves. Skip + log, leaving the user's copy intact.
        final localFile = File(localPath);
        if (localFile.existsSync() && entryRecord == null) {
          debugPrint(
              '[ShareFolderSync] Skip (local file already exists, not from share): $displayName');
          syncMeta[displayName] = _SyncedFileEntry(
            fileName: displayName,
            direction: 'skipped_collision',
            syncedAt: DateTime.now(),
          );
          continue;
        }

        try {
          // Per-file share token is wrapped to the recipient's pubkey
          // (Type 3) or to the link-ephemeral pubkey (Type 1/2). The
          // ephemeral fula_client we built above has the matching
          // secret, so `getWithToken` accepts internally and decrypts.
          //
          // `storageKey` doubles as both the path and the originalKey:
          // the FFI's `create_share_token_with_mode` sets the token's
          // `path_scope = storage_key`, so `is_path_allowed(originalKey)`
          // only passes when both args are equal. Mirrors the
          // collab + plain-share fix in `sharing_service.dart`.
          final data = await fula.getWithToken(
            client: shareClient,
            bucket: bucket,
            storageKey: storageKey,
            originalKey: storageKey,
            tokenJson: tokenJson,
          );
          await localFile.parent.create(recursive: true);
          await localFile.writeAsBytes(Uint8List.fromList(data));
          syncMeta[displayName] = _SyncedFileEntry(
            fileName: displayName,
            direction: 'download',
            syncedAt: DateTime.now(),
          );
          hasChanges = true;
          debugPrint('[ShareFolderSync] Downloaded: $displayName');
        } catch (e) {
          debugPrint('[ShareFolderSync] Download failed ($displayName): $e');
          // Only persist a failure marker for non-transient errors so a flaky
          // network doesn't permanently lock the file out.
          final errStr = e.toString();
          if (errStr.contains('404') || errStr.contains('410')) {
            syncMeta[displayName] = _SyncedFileEntry(
              fileName: displayName,
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

  /// Fetch the share manifest from pinning-webui's
  /// `/api/share/v2/manifest/{shareId}` endpoint and decrypt if needed.
  ///
  /// The owner uploads the manifest at share-creation time (see
  /// `sharing_service.dart::_postManifest`). For Type 1/2 (public link
  /// / password) the manifest body has the shape:
  ///   ```
  ///   { encryptedManifest: "ENC1:<base64>", expiresAt: "..." }
  ///   ```
  /// and the recipient decrypts it with their linkSecretKey (which
  /// came from the URL fragment). For Type 3 (recipient-specific) the
  /// manifest is plaintext:
  ///   ```
  ///   { bucket, pathScope, tokenJson, files: [...], shareMode, expiresAt }
  ///   ```
  /// because the per-file share tokens inside `files` already encrypt
  /// the DEK to the recipient's pubkey, so the file LIST being public
  /// is acceptable. Defence-in-depth (file CONTENTS still require
  /// recipient secret to decrypt via the share-token unwrap).
  ///
  /// Returns the manifest map (with `files: List`) on success, or null
  /// on any failure. Caller logs + skips.
  Future<Map<String, dynamic>?> _fetchAndParseManifest(
      AcceptedShare share) async {
    try {
      final url =
          '$kShareGatewayBaseUrl/api/share/v2/manifest/${share.token.id}';
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        debugPrint(
            '[ShareFolderSync] Manifest fetch status=${response.statusCode} for ${share.token.id}');
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      // Encrypted shape (Type 1/2). Manifest is AEAD-wrapped under
      // `HKDF(linkSecretKey, shareId)`; we need the URL-embedded
      // ephemeral private key from `AcceptedShare.linkSecretKey`
      // (persisted at acceptance time by
      // `SharingService.acceptShare(token, linkSecretKey: ...)`).
      final enc = body['encryptedManifest'];
      if (enc is String) {
        if (share.linkSecretKey == null) {
          debugPrint(
              '[ShareFolderSync] Manifest is encrypted (Type 1/2) but share '
              '${share.token.id} has no linkSecretKey. The share was either '
              'accepted before the Type 1/2 plumbing landed (re-accept the '
              'link) or it is password-protected (password flow not yet wired).');
          return null;
        }
        return await CollaborationService.instance.decryptManifestPayload(
          enc,
          share.linkSecretKey!,
          share.token.id,
        );
      }

      // Plaintext shape (Type 3)
      if (body['files'] is List) {
        return body;
      }

      debugPrint(
          '[ShareFolderSync] Unexpected manifest shape for ${share.token.id}: '
          'missing both encryptedManifest and files');
      return null;
    } catch (e) {
      debugPrint(
          '[ShareFolderSync] Manifest fetch error (${share.token.id}): $e');
      return null;
    }
  }

  /// Build an ephemeral fula_client pointed at the share-fetch proxy.
  /// Mirrors `sharing_service.dart::downloadSharedFile` and
  /// `collaboration_service.dart::downloadFile`. The `secretKey`
  /// passed here is what unwraps the per-file share token DEKs:
  /// today that's the signed-in user's master KEK (Type 3 only). See
  /// the comment in `_pollForNewFiles` for Type 1/2 follow-up scope.
  Future<fula.EncryptedClientHandle> _buildShareClient(
      Uint8List secretKey) async {
    final config = fula.FulaConfig(
      endpoint: '$kShareGatewayBaseUrl/api/share/v2/fetch',
      timeoutSeconds: BigInt.from(120),
      maxRetries: 3,
      perChunkDownloadTimeoutSeconds: BigInt.from(300),
      bufferedDownloadMaxBytes: BigInt.from(256 * 1024 * 1024),
      healthGateEnabled: true,
      healthGateTtlSeconds: BigInt.from(30),
      // Cache off: share fetches don't fit the user-scoped offline path.
      blockCacheEnabled: false,
      blockCachePath: '',
      blockCacheMaxBytes: BigInt.from(256 * 1024 * 1024),
      // Gateway fallback off: share tokens validated by the proxy.
      gatewayFallbackEnabled: false,
      gatewayFallbackUrls: const [],
      gatewayRaceConcurrency: 3,
      // Cold-start doesn't apply to ephemeral share-fetch client.
      usersIndexChainRpcUrl: '',
      usersIndexAnchorAddress: '',
      usersIndexIpnsName: '',
      usersIndexUserKey: '',
      usersIndexIpnsGatewayUrls: const [],
      usersIndexIpfsGatewayUrls: const [],
      walkableV8WriterEnabled: true,
    );
    final encConfig = fula.EncryptionConfig(
      secretKey: secretKey,
      enableMetadataPrivacy: true,
      obfuscationMode: fula.ObfuscationMode.flatNamespace,
    );
    return await fula.createEncryptedClient(
      config: config,
      encryption: encConfig,
    );
  }

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

  /// Folder-level share-token acceptance is unused by the manifest-
  /// driven download path: each FILE in the manifest carries its own
  /// per-file share token, which the ephemeral fula_client built in
  /// `_buildShareClient` accepts inline via `fula.getWithToken`. The
  /// helper + `_handles` cache are kept here for backward-reference
  /// only; remove when the Type 1/2 desktop folder-sync follow-up
  /// settles on whether per-share handles are needed at all.
  // ignore: unused_element
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
