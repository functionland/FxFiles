import 'dart:convert';
import 'dart:typed_data';

import 'package:fula_files/core/models/playlist.dart';

/// Pure, VM-testable transforms behind the web cloud playlist WRITE path
/// (#21). No `package:web` / FulaApiService imports so this — and its unit
/// tests — run under the VM; the IO glue (encrypt + upload + bucket ensure)
/// lives in `web_playlist_service.dart`.
///
/// CRITICAL: the on-disk shape must stay byte-compatible with what native
/// `PlaylistService` writes and `WebFeatures.loadPlaylists` reads, so this
/// goes through the shared `Playlist`/`AudioTrack` models' `toJson` only.

/// The playlist object-key prefix native uses (PlaylistService._playlistPrefix).
const String kPlaylistPrefix = 'user-playlists/';

/// Cloud object key for a playlist id — must match native exactly.
String playlistCloudKey(String id) => '$kPlaylistPrefix$id.json';

/// Exact upload bytes native reads: `Playlist.toJson()` → UTF-8 JSON.
Uint8List playlistUploadBytes(Playlist p) =>
    Uint8List.fromList(utf8.encode(jsonEncode(p.toJson())));

/// A new playlist matching native `createPlaylist` (caller supplies the
/// uuid id; createdAt == updatedAt == [now]).
Playlist buildNewPlaylist({
  required String id,
  required String name,
  required List<AudioTrack> tracks,
  required DateTime now,
}) =>
    Playlist(
      id: id,
      name: name,
      tracks: tracks,
      createdAt: now,
      updatedAt: now,
    );

/// Append [track] to [p] (dedup by path, like native `Playlist.addTrack`) and
/// bump `updatedAt` to [now]. Returns false (no change) if the path is already
/// present. [now] is injected rather than `DateTime.now()` for testability.
bool appendTrack(Playlist p, AudioTrack track, DateTime now) {
  if (p.tracks.contains(track)) return false; // AudioTrack == is by path
  p.tracks.add(track);
  p.updatedAt = now;
  return true;
}

/// Trim a user-entered playlist name; null when it's empty after trimming so
/// callers reject blank names uniformly (#23).
String? cleanPlaylistName(String raw) {
  final t = raw.trim();
  return t.isEmpty ? null : t;
}
