import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_playlist_write_logic.dart';

/// Web cloud playlist WRITE path (#21): create a playlist / add a track,
/// persisted as the SAME encrypted `user-playlists/<id>.json` object the
/// native app reads & writes — so playlists round-trip across web and mobile.
///
/// Minimal blast radius by construction: only ever PUTs a single per-id
/// playlist object through the shared `encryptAndUpload` with native-identical
/// bucket / key / format / contentType. It never deletes and never writes
/// tombstones — those stay native-only. The pure transforms
/// (build / append / serialize) live in web_playlist_write_logic.dart and are
/// VM-unit-tested; this file is the cloud IO glue.
class WebPlaylistService {
  WebPlaylistService._();
  static final WebPlaylistService instance = WebPlaylistService._();

  static const _uuid = Uuid();

  /// The bucket writes route to — the SAME resolver native uses, so the
  /// write always lands in a bucket the read-merge covers (`playlists-v8`
  /// once managed, else legacy `playlists`).
  String get _writeBucket => BucketVersionResolver.writeBucket('playlists');

  Future<Uint8List> _kek() async {
    final b64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (b64 == null || b64.isEmpty) {
      throw StateError('No session encryption key');
    }
    return Uint8List.fromList(base64Decode(b64));
  }

  Future<void> _ensureBucket(String bucket) async {
    // Propagate failures to the caller (which surfaces a snackbar) rather
    // than swallowing and uploading into a missing/forbidden bucket — clearer
    // errors, and matches native syncPlaylistToCloud (advisor: Gemini).
    // createBucket itself tolerates an already-existing bucket.
    if (!await FulaApiService.instance.bucketExists(bucket)) {
      await FulaApiService.instance.createBucket(bucket);
    }
  }

  Future<void> _put(Playlist p, Uint8List kek) async {
    final bucket = _writeBucket;
    await _ensureBucket(bucket);
    await FulaApiService.instance.encryptAndUpload(
      bucket,
      playlistCloudKey(p.id), // canonical key → always in a read-merged bucket
      playlistUploadBytes(p),
      kek,
      contentType: 'application/json',
    );
  }

  /// Create a new playlist (optionally seeded with [tracks]) and upload it.
  Future<Playlist> createPlaylist(String name,
      {List<AudioTrack> tracks = const []}) async {
    final kek = await _kek();
    final p = buildNewPlaylist(
      id: _uuid.v4(),
      name: name,
      tracks: List<AudioTrack>.from(tracks),
      now: DateTime.now(),
    );
    await _put(p, kek);
    return p;
  }

  /// Add [track] to an existing playlist (by id): load the current cloud
  /// copy, append (dedup by path), re-upload. Returns false if the playlist
  /// is missing or the track was already present (no upload).
  Future<bool> addTrackToPlaylist(String playlistId, AudioTrack track) async {
    final kek = await _kek();
    final all = await WebFeatures.loadPlaylists();
    Playlist? target;
    for (final p in all) {
      if (p.id == playlistId) {
        target = p;
        break;
      }
    }
    if (target == null) return false;
    if (!appendTrack(target, track, DateTime.now())) return false;
    await _put(target, kek);
    return true;
  }
}
