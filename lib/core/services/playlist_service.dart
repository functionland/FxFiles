import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

class PlaylistService {
  PlaylistService._();
  static final PlaylistService instance = PlaylistService._();

  static const String _playlistBucket = 'playlists';
  static const String _playlistPrefix = 'user-playlists/';

  late Box<Playlist> _playlistBox;
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

    _playlistBox = await Hive.openBox<Playlist>('playlists');
    _isInitialized = true;
    debugPrint('PlaylistService initialized with ${_playlistBox.length} playlists');
  }

  // ============================================================================
  // LOCAL PLAYLIST OPERATIONS
  // ============================================================================

  List<Playlist> getAllPlaylists() {
    return _playlistBox.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Playlist? getPlaylist(String id) {
    return _playlistBox.get(id);
  }

  Future<Playlist> createPlaylist(String name, {List<AudioTrack>? tracks}) async {
    final playlist = Playlist(
      id: _uuid.v4(),
      name: name,
      tracks: tracks,
    );
    await _playlistBox.put(playlist.id, playlist);
    debugPrint('Created playlist: ${playlist.name} with ${playlist.trackCount} tracks');

    // Auto-sync to cloud if configured
    _autoSyncPlaylist(playlist.id);

    return playlist;
  }

  Future<void> updatePlaylist(Playlist playlist) async {
    playlist.updatedAt = DateTime.now();
    await _playlistBox.put(playlist.id, playlist);
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
    final playlist = _playlistBox.get(id);
    if (playlist != null) {
      // Delete from cloud if synced
      if (playlist.cloudKey != null && FulaApiService.instance.isConfigured) {
        try {
          await FulaApiService.instance.deleteObject(_playlistBucket, playlist.cloudKey!);
        } catch (e) {
          debugPrint('Error deleting playlist from cloud: $e');
        }
      }
      await _playlistBox.delete(id);
      debugPrint('Deleted playlist: ${playlist.name}');
    }
  }

  Future<void> renamePlaylist(String id, String newName) async {
    final playlist = _playlistBox.get(id);
    if (playlist != null) {
      playlist.name = newName;
      playlist.updatedAt = DateTime.now();
      await _playlistBox.put(id, playlist);
      debugPrint('Renamed playlist to: $newName');
      _autoSyncPlaylist(id);
    }
  }

  Future<void> addTrackToPlaylist(String playlistId, AudioTrack track) async {
    final playlist = _playlistBox.get(playlistId);
    if (playlist != null) {
      playlist.addTrack(track);
      await _playlistBox.put(playlistId, playlist);
      debugPrint('Added track to playlist: ${track.name}');
      _autoSyncPlaylist(playlistId);
    }
  }

  Future<void> addTracksToPlaylist(String playlistId, List<AudioTrack> tracks) async {
    final playlist = _playlistBox.get(playlistId);
    if (playlist != null) {
      playlist.addTracks(tracks);
      await _playlistBox.put(playlistId, playlist);
      debugPrint('Added ${tracks.length} tracks to playlist');
      _autoSyncPlaylist(playlistId);
    }
  }

  Future<void> removeTrackFromPlaylist(String playlistId, int trackIndex) async {
    final playlist = _playlistBox.get(playlistId);
    if (playlist != null) {
      playlist.removeTrackAt(trackIndex);
      await _playlistBox.put(playlistId, playlist);
      debugPrint('Removed track at index $trackIndex from playlist');
      _autoSyncPlaylist(playlistId);
    }
  }

  Future<void> reorderTrackInPlaylist(String playlistId, int oldIndex, int newIndex) async {
    final playlist = _playlistBox.get(playlistId);
    if (playlist != null) {
      playlist.reorderTrack(oldIndex, newIndex);
      await _playlistBox.put(playlistId, playlist);
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

    final playlist = _playlistBox.get(playlistId);
    if (playlist == null) {
      throw PlaylistServiceException('Playlist not found');
    }

    final encryptionKey = await _getEncryptionKey();
    if (encryptionKey == null) {
      throw PlaylistServiceException('User not authenticated');
    }

    try {
      // Ensure bucket exists
      final bucketExists = await FulaApiService.instance.bucketExists(_playlistBucket);
      if (!bucketExists) {
        await FulaApiService.instance.createBucket(_playlistBucket);
      }

      // Convert playlist to JSON
      final playlistJson = jsonEncode(playlist.toJson());
      final data = Uint8List.fromList(utf8.encode(playlistJson));

      // Generate cloud key if not exists
      final cloudKey = playlist.cloudKey ?? '$_playlistPrefix${playlist.id}.json';

      // Encrypt and upload
      await FulaApiService.instance.encryptAndUpload(
        _playlistBucket,
        cloudKey,
        data,
        encryptionKey,
        originalFilename: '${playlist.name}.json',
        contentType: 'application/json',
      );

      // Update local playlist with cloud info
      playlist.cloudKey = cloudKey;
      playlist.isSyncedToCloud = true;
      await _playlistBox.put(playlistId, playlist);

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

    final cloudPlaylists = <Playlist>[];

    try {
      // Check if bucket exists
      final bucketExists = await FulaApiService.instance.bucketExists(_playlistBucket);
      if (!bucketExists) {
        debugPrint('Playlist bucket does not exist');
        return cloudPlaylists;
      }

      // List all playlists in cloud
      final objects = await FulaApiService.instance.listObjects(
        _playlistBucket,
        prefix: _playlistPrefix,
      );

      for (final obj in objects) {
        if (obj.isDirectory || !obj.key.endsWith('.json')) continue;

        try {
          // Download and decrypt
          final data = await FulaApiService.instance.downloadAndDecrypt(
            _playlistBucket,
            obj.key,
            encryptionKey,
          );

          final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
          final playlist = Playlist.fromJson(json);
          playlist.cloudKey = obj.key;
          playlist.isSyncedToCloud = true;

          cloudPlaylists.add(playlist);
        } catch (e) {
          debugPrint('Error loading playlist ${obj.key}: $e');
        }
      }

      debugPrint('Fetched ${cloudPlaylists.length} playlists from cloud');
      return cloudPlaylists;
    } catch (e) {
      throw PlaylistServiceException('Failed to fetch playlists: $e');
    }
  }

  Future<void> restorePlaylistsFromCloud() async {
    final cloudPlaylists = await fetchPlaylistsFromCloud();

    for (final cloudPlaylist in cloudPlaylists) {
      final localPlaylist = _playlistBox.get(cloudPlaylist.id);

      if (localPlaylist == null) {
        // New playlist from cloud
        await _playlistBox.put(cloudPlaylist.id, cloudPlaylist);
        debugPrint('Restored playlist from cloud: ${cloudPlaylist.name}');
      } else if (cloudPlaylist.updatedAt.isAfter(localPlaylist.updatedAt)) {
        // Cloud version is newer
        await _playlistBox.put(cloudPlaylist.id, cloudPlaylist);
        debugPrint('Updated playlist from cloud: ${cloudPlaylist.name}');
      }
    }
  }

  Future<void> deletePlaylistFromCloud(String cloudKey) async {
    if (!FulaApiService.instance.isConfigured) {
      throw PlaylistServiceException('Cloud storage not configured');
    }

    try {
      await FulaApiService.instance.deleteObject(_playlistBucket, cloudKey);
      debugPrint('Deleted playlist from cloud: $cloudKey');
    } catch (e) {
      throw PlaylistServiceException('Failed to delete playlist from cloud: $e');
    }
  }

  // ============================================================================
  // UTILITY METHODS
  // ============================================================================

  bool playlistExists(String name) {
    return _playlistBox.values.any(
      (p) => p.name.toLowerCase() == name.toLowerCase(),
    );
  }

  int get playlistCount => _playlistBox.length;

  Future<void> clearAllPlaylists() async {
    await _playlistBox.clear();
    debugPrint('Cleared all playlists');
  }
}

class PlaylistServiceException implements Exception {
  final String message;
  PlaylistServiceException(this.message);

  @override
  String toString() => 'PlaylistServiceException: $message';
}
