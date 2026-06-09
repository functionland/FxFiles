import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

class PlaylistService {
  PlaylistService._();
  static final PlaylistService instance = PlaylistService._();

  static const String _playlistBucket = 'playlists';
  static const String _playlistPrefix = 'user-playlists/';

  /// Reserved prefix (OUTSIDE `_playlistPrefix`, so the playlist list-scan
  /// never parses these as playlists) for per-id delete tombstones. One
  /// independent object per delete → no read-modify-write race across devices.
  static const String _playlistTombstonePrefix = 'playlist-deleted/';

  /// The bucket playlist WRITES/DELETES route to: `playlists-v8` once the
  /// legacy (gc-damaged) forest is v8-managed, else `playlists`. Reads MERGE
  /// both. No-op until `playlists` joins the managed set.
  String get _writeBucket =>
      BucketVersionResolver.writeBucket(_playlistBucket);

  Box<Playlist>? _playlistBox;
  bool _isInitialized = false;

  final _uuid = const Uuid();

  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;

    // Register adapters if not already registered
    if (!Hive.isAdapterRegistered(6)) {
      Hive.registerAdapter(AudioTrackAdapter());
    }
    if (!Hive.isAdapterRegistered(7)) {
      Hive.registerAdapter(PlaylistAdapter());
    }

    // Open box with timeout (can hang on iOS 26+)
    try {
      _playlistBox = await Hive.openBox<Playlist>('playlists')
          .timeout(const Duration(milliseconds: 1500));
      debugPrint('PlaylistService initialized with ${_playlistBox?.length ?? 0} playlists');
    } catch (e) {
      debugPrint('PlaylistService failed to open playlists box: $e');
    }

    _isInitialized = true;
  }

  // ============================================================================
  // LOCAL PLAYLIST OPERATIONS
  // ============================================================================

  List<Playlist> getAllPlaylists() {
    final box = _playlistBox;
    if (box == null) return [];

    return box.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Playlist? getPlaylist(String id) {
    return _playlistBox?.get(id);
  }

  Future<Playlist> createPlaylist(String name, {List<AudioTrack>? tracks}) async {
    final playlist = Playlist(
      id: _uuid.v4(),
      name: name,
      tracks: tracks,
    );
    await _playlistBox?.put(playlist.id, playlist);
    debugPrint('Created playlist: ${playlist.name} with ${playlist.trackCount} tracks');

    // Auto-sync to cloud if configured
    _autoSyncPlaylist(playlist.id);

    return playlist;
  }

  Future<void> updatePlaylist(Playlist playlist) async {
    playlist.updatedAt = DateTime.now();
    await _playlistBox?.put(playlist.id, playlist);
    debugPrint('Updated playlist: ${playlist.name}');

    // Auto-sync to cloud if configured
    _autoSyncPlaylist(playlist.id);
  }

  /// Auto-sync playlist to cloud in background (fire and forget)
  void _autoSyncPlaylist(String playlistId) {
    if (!FulaApiService.instance.isConfigured) return;

    // Run sync in background, don't wait for it
    Future(() async {
      try {
        await syncPlaylistToCloud(playlistId);
      } catch (e) {
        debugPrint('Auto-sync playlist failed: $e');
      }
    });
  }

  Future<void> deletePlaylist(String id) async {
    final box = _playlistBox;
    if (box == null) return;

    final playlist = box.get(id);
    if (playlist != null) {
      // Write the tombstone + delete the cloud object BEFORE removing locally,
      // so a failure can't leave a resurrectable cloud copy with no tombstone.
      // Tombstone unconditionally (when configured) — a copy may exist in the
      // cloud from another device even if this device never set `cloudKey`.
      if (FulaApiService.instance.isConfigured) {
        await _tombstonePlaylist(id);
        final cloudKey = playlist.cloudKey ?? '$_playlistPrefix$id.json';
        try {
          await FulaApiService.instance.deleteObject(_writeBucket, cloudKey);
        } catch (e) {
          debugPrint('Error deleting playlist from cloud: $e');
        }
      }
      await box.delete(id);
      debugPrint('Deleted playlist: ${playlist.name}');
    }
  }

  Future<void> renamePlaylist(String id, String newName) async {
    final box = _playlistBox;
    if (box == null) return;

    final playlist = box.get(id);
    if (playlist != null) {
      playlist.name = newName;
      playlist.updatedAt = DateTime.now();
      await box.put(id, playlist);
      debugPrint('Renamed playlist to: $newName');
      _autoSyncPlaylist(id);
    }
  }

  Future<void> addTrackToPlaylist(String playlistId, AudioTrack track) async {
    final box = _playlistBox;
    if (box == null) return;

    final playlist = box.get(playlistId);
    if (playlist != null) {
      playlist.addTrack(track);
      await box.put(playlistId, playlist);
      debugPrint('Added track to playlist: ${track.name}');
      _autoSyncPlaylist(playlistId);
    }
  }

  Future<void> addTracksToPlaylist(String playlistId, List<AudioTrack> tracks) async {
    final box = _playlistBox;
    if (box == null) return;

    final playlist = box.get(playlistId);
    if (playlist != null) {
      playlist.addTracks(tracks);
      await box.put(playlistId, playlist);
      debugPrint('Added ${tracks.length} tracks to playlist');
      _autoSyncPlaylist(playlistId);
    }
  }

  Future<void> removeTrackFromPlaylist(String playlistId, int trackIndex) async {
    final box = _playlistBox;
    if (box == null) return;

    final playlist = box.get(playlistId);
    if (playlist != null) {
      playlist.removeTrackAt(trackIndex);
      await box.put(playlistId, playlist);
      debugPrint('Removed track at index $trackIndex from playlist');
      _autoSyncPlaylist(playlistId);
    }
  }

  Future<void> reorderTrackInPlaylist(String playlistId, int oldIndex, int newIndex) async {
    final box = _playlistBox;
    if (box == null) return;

    final playlist = box.get(playlistId);
    if (playlist != null) {
      playlist.reorderTrack(oldIndex, newIndex);
      await box.put(playlistId, playlist);
      debugPrint('Reordered track from $oldIndex to $newIndex');
      _autoSyncPlaylist(playlistId);
    }
  }

  // ============================================================================
  // CLOUD SYNC OPERATIONS
  // ============================================================================

  Future<Uint8List?> _getEncryptionKey() async {
    // Get encryption key from AuthService (derived during login)
    return await AuthService.instance.getEncryptionKey();
  }

  Future<void> syncPlaylistToCloud(String playlistId) async {
    if (!FulaApiService.instance.isConfigured) {
      throw PlaylistServiceException('Cloud storage not configured');
    }

    final playlist = _playlistBox?.get(playlistId);
    if (playlist == null) {
      throw PlaylistServiceException('Playlist not found');
    }

    final encryptionKey = await _getEncryptionKey();
    if (encryptionKey == null) {
      throw PlaylistServiceException('User not authenticated');
    }

    try {
      // Ensure bucket exists (the v8 write target once managed)
      final bucketExists = await FulaApiService.instance.bucketExists(_writeBucket);
      if (!bucketExists) {
        await FulaApiService.instance.createBucket(_writeBucket);
      }

      // Convert playlist to JSON
      final playlistJson = jsonEncode(playlist.toJson());
      final data = Uint8List.fromList(utf8.encode(playlistJson));

      // Generate cloud key if not exists
      final cloudKey = playlist.cloudKey ?? '$_playlistPrefix${playlist.id}.json';

      // Upload playlist (key must match what downloadAndDecrypt uses)
      await FulaApiService.instance.encryptAndUpload(
        _writeBucket,
        cloudKey,
        data,
        encryptionKey,
        // NOTE: Don't pass originalFilename - it overrides the key path!
        contentType: 'application/json',
      );

      // Update local playlist with cloud info
      playlist.cloudKey = cloudKey;
      playlist.isSyncedToCloud = true;
      await _playlistBox?.put(playlistId, playlist);

      debugPrint('Synced playlist to cloud: ${playlist.name}');
    } catch (e) {
      throw PlaylistServiceException('Failed to sync playlist: $e');
    }
  }

  Future<void> syncAllPlaylistsToCloud() async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('Cloud storage not configured, skipping sync');
      return;
    }

    final playlists = getAllPlaylists();
    for (final playlist in playlists) {
      try {
        await syncPlaylistToCloud(playlist.id);
      } catch (e) {
        debugPrint('Error syncing playlist ${playlist.name}: $e');
      }
    }
  }

  Future<List<Playlist>> fetchPlaylistsFromCloud() async {
    if (!FulaApiService.instance.isConfigured) {
      throw PlaylistServiceException('Cloud storage not configured');
    }

    final encryptionKey = await _getEncryptionKey();
    if (encryptionKey == null) {
      throw PlaylistServiceException('User not authenticated');
    }

    try {
      // MERGE legacy + v8 — the legacy forest is gc-damaged, new writes land in
      // `playlists-v8`. Iterate LEGACY FIRST (the frozen source of truth): a
      // hard legacy error surfaces (we never silently return a v8-only view),
      // while an absent v8 bucket (not created yet) is simply skipped. Drop the
      // single `bucketExists` gate — a per-bucket list tolerant of NoSuchBucket
      // never drops the OTHER bucket when one is absent.
      final legacyBucket = _playlistBucket;
      final v8Bucket = _writeBucket;
      final buckets = v8Bucket == legacyBucket
          ? <String>[legacyBucket]
          : <String>[legacyBucket, v8Bucket];

      final v8Playlists = <Playlist>[];
      final legacyPlaylists = <Playlist>[];

      for (final bucket in buckets) {
        final isLegacy = bucket == legacyBucket;

        List<FulaObject> objects;
        try {
          objects = await FulaApiService.instance
              .listObjects(bucket, prefix: _playlistPrefix);
        } catch (e) {
          if (_isNotFoundError(e)) {
            debugPrint('PlaylistService: $bucket absent, skipping: $e');
            continue;
          }
          if (isLegacy) rethrow; // hard error on the source of truth → surface
          debugPrint('PlaylistService: v8 list failed, using legacy only: $e');
          continue; // hard error on v8 → tolerate as empty
        }

        final target = isLegacy ? legacyPlaylists : v8Playlists;
        for (final obj in objects) {
          if (obj.isDirectory || !obj.key.endsWith('.json')) continue;
          try {
            final data = await FulaApiService.instance
                .downloadAndDecrypt(bucket, obj.key, encryptionKey);
            final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
            final playlist = Playlist.fromJson(json);
            playlist.cloudKey = obj.key;
            playlist.isSyncedToCloud = true;
            target.add(playlist);
          } catch (e) {
            debugPrint('Error loading playlist ${obj.key}: $e');
          }
        }
      }

      final tombstoned = await _fetchTombstonedIds();
      final merged = mergePlaylists(
        v8: v8Playlists,
        legacy: legacyPlaylists,
        tombstoned: tombstoned,
      );

      debugPrint('Fetched ${merged.length} playlists from cloud '
          '(v8=${v8Playlists.length} legacy=${legacyPlaylists.length} '
          'tombstoned=${tombstoned.length})');
      return merged;
    } catch (e) {
      if (e is PlaylistServiceException) rethrow;
      throw PlaylistServiceException('Failed to fetch playlists: $e');
    }
  }

  Future<void> restorePlaylistsFromCloud() async {
    final box = _playlistBox;
    if (box == null) return;

    final cloudPlaylists = await fetchPlaylistsFromCloud();

    for (final cloudPlaylist in cloudPlaylists) {
      final localPlaylist = box.get(cloudPlaylist.id);

      if (localPlaylist == null) {
        // New playlist from cloud
        await box.put(cloudPlaylist.id, cloudPlaylist);
        debugPrint('Restored playlist from cloud: ${cloudPlaylist.name}');
      } else if (cloudPlaylist.updatedAt.isAfter(localPlaylist.updatedAt)) {
        // Cloud version is newer
        await box.put(cloudPlaylist.id, cloudPlaylist);
        debugPrint('Updated playlist from cloud: ${cloudPlaylist.name}');
      }
    }
  }

  Future<void> deletePlaylistFromCloud(String cloudKey) async {
    if (!FulaApiService.instance.isConfigured) {
      throw PlaylistServiceException('Cloud storage not configured');
    }

    // Tombstone by the id embedded in the key so a legacy-only copy can't
    // resurrect via the list-merge, then delete the v8 object.
    final fileName = cloudKey.split('/').last;
    final id = fileName.endsWith('.json')
        ? fileName.substring(0, fileName.length - '.json'.length)
        : fileName;
    if (id.isNotEmpty) await _tombstonePlaylist(id);

    try {
      await FulaApiService.instance.deleteObject(_writeBucket, cloudKey);
      debugPrint('Deleted playlist from cloud: $cloudKey');
    } catch (e) {
      if (_isNotFoundError(e)) {
        debugPrint('PlaylistService: no cloud object to delete: $cloudKey');
        return;
      }
      throw PlaylistServiceException('Failed to delete playlist from cloud: $e');
    }
  }

  /// Write a per-id delete tombstone to the v8 bucket so a deleted playlist
  /// whose (immortal) legacy copy still lists can't resurrect via the merge.
  /// One independent object per delete — no read-modify-write race across
  /// devices (unlike a central deleted-ids manifest). No-op while unmanaged
  /// (tombstones live only in v8). Best-effort: a failure may let the playlist
  /// reappear until it is re-deleted online (parity with today's 410'd delete).
  Future<void> _tombstonePlaylist(String id) async {
    final v8Bucket = _writeBucket;
    if (v8Bucket == _playlistBucket) return; // unmanaged → tombstones not used
    try {
      final body = jsonEncode({'deletedAt': DateTime.now().toIso8601String()});
      await FulaApiService.instance.uploadObject(
        v8Bucket,
        '$_playlistTombstonePrefix$id.json',
        Uint8List.fromList(utf8.encode(body)),
        contentType: 'application/json',
      );
      debugPrint('PlaylistService: tombstoned playlist $id');
    } catch (e) {
      debugPrint('PlaylistService: tombstone write failed for $id: $e');
    }
  }

  /// Read the set of tombstoned (deleted) playlist ids from the v8 bucket.
  /// Tombstones are written ONLY to v8 (legacy is write-damaged), so this reads
  /// v8 alone. A missing v8 bucket (fresh user, no syncs yet) → empty set; a
  /// HARD error rethrows so a transient gateway failure can't silently drop the
  /// filter and permanently resurrect a deleted playlist (the additive restore
  /// never re-removes it).
  Future<Set<String>> _fetchTombstonedIds() async {
    final v8Bucket = _writeBucket;
    if (v8Bucket == _playlistBucket) return <String>{}; // unmanaged → none
    List<FulaObject> objects;
    try {
      objects = await FulaApiService.instance
          .listObjects(v8Bucket, prefix: _playlistTombstonePrefix);
    } catch (e) {
      if (_isNotFoundError(e)) return <String>{}; // v8 bucket not created yet
      rethrow;
    }
    return parseTombstonedPlaylistIds(
      objects.where((o) => !o.isDirectory).map((o) => o.key),
    );
  }

  /// True if [e] looks like a "missing object/bucket" rather than a hard
  /// transport/server error (matches the FulaApiService merge-read heuristic).
  static bool _isNotFoundError(Object e) {
    final s = e.toString();
    return s.contains('NoSuchKey') ||
        s.contains('NoSuchBucket') ||
        s.contains('bucket not found') ||
        s.contains('404') ||
        s.contains('not found');
  }

  // ============================================================================
  // UTILITY METHODS
  // ============================================================================

  bool playlistExists(String name) {
    final box = _playlistBox;
    if (box == null) return false;

    return box.values.any(
      (p) => p.name.toLowerCase() == name.toLowerCase(),
    );
  }

  int get playlistCount => _playlistBox?.length ?? 0;

  Future<void> clearAllPlaylists() async {
    await _playlistBox?.clear();
    debugPrint('Cleared all playlists');
  }
}

/// Pure cloud-side merge of playlists across the `[v8, legacy]` buckets.
/// Combine by `playlist.id` — **v8 wins** a conflicting id (post-migration
/// writes only land in v8, so its copy is always at least as new) — then drop
/// any id that has a delete tombstone (a deleted playlist whose legacy copy is
/// immortal). Subtraction happens AFTER the combine so a tombstoned v8 winner
/// is still removed. Resolver-independent ⇒ device-free testable.
List<Playlist> mergePlaylists({
  required List<Playlist> v8,
  required List<Playlist> legacy,
  required Set<String> tombstoned,
}) {
  final byId = <String, Playlist>{};
  for (final p in v8) {
    byId.putIfAbsent(p.id, () => p);
  }
  for (final p in legacy) {
    byId.putIfAbsent(p.id, () => p); // v8 already present ⇒ v8 wins
  }
  for (final id in tombstoned) {
    byId.remove(id);
  }
  return byId.values.toList();
}

/// Extract deleted playlist ids from tombstone object keys of the shape
/// `playlist-deleted/{id}.json` (the basename minus `.json`). Skips
/// directories / non-json / empty without throwing. Pure ⇒ device-free testable.
Set<String> parseTombstonedPlaylistIds(Iterable<String> keys) {
  const suffix = '.json';
  final ids = <String>{};
  for (final key in keys) {
    final fileName = key.split('/').last;
    if (!fileName.endsWith(suffix)) continue;
    final id = fileName.substring(0, fileName.length - suffix.length);
    if (id.isNotEmpty) ids.add(id);
  }
  return ids;
}

class PlaylistServiceException implements Exception {
  final String message;
  PlaylistServiceException(this.message);

  @override
  String toString() => 'PlaylistServiceException: $message';
}
