import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/web/services/web_playlist_write_logic.dart';

/// Unit tests for the pure web playlist-WRITE transforms (#21). The cloud IO
/// glue (encrypt + upload) is in web_playlist_service.dart; here we guard the
/// part that must stay byte-compatible with what native reads/writes.
void main() {
  AudioTrack track(String path, {String? name}) =>
      AudioTrack(path: path, name: name ?? path);

  test('playlistCloudKey matches the native key scheme', () {
    expect(playlistCloudKey('abc123'), 'user-playlists/abc123.json');
  });

  test('buildNewPlaylist sets id/name/tracks and equal timestamps', () {
    final now = DateTime.utc(2026, 6, 14, 12);
    final p = buildNewPlaylist(
        id: 'p1', name: 'Faves', tracks: [track('/a.mp3')], now: now);
    expect(p.id, 'p1');
    expect(p.name, 'Faves');
    expect(p.tracks.single.path, '/a.mp3');
    expect(p.createdAt, now);
    expect(p.updatedAt, now);
  });

  test('upload bytes round-trip through Playlist.fromJson (format fidelity)',
      () {
    final now = DateTime.utc(2026, 6, 14, 12);
    final p = buildNewPlaylist(
      id: 'p1',
      name: 'Faves',
      tracks: [track('/a.mp3', name: 'A'), track('/b.mp3', name: 'B')],
      now: now,
    );
    final restored = Playlist.fromJson(
        jsonDecode(utf8.decode(playlistUploadBytes(p)))
            as Map<String, dynamic>);
    expect(restored.id, 'p1');
    expect(restored.name, 'Faves');
    expect(restored.tracks.map((t) => t.path), ['/a.mp3', '/b.mp3']);
    expect(restored.createdAt, now);
    expect(restored.updatedAt, now);
  });

  group('appendTrack', () {
    test('appends a new track and bumps updatedAt', () {
      final created = DateTime.utc(2026, 6, 14, 12);
      final later = DateTime.utc(2026, 6, 14, 13);
      final p = buildNewPlaylist(
          id: 'p1', name: 'P', tracks: [track('/a.mp3')], now: created);
      final added = appendTrack(p, track('/b.mp3'), later);
      expect(added, isTrue);
      expect(p.tracks.map((t) => t.path), ['/a.mp3', '/b.mp3']);
      expect(p.updatedAt, later);
    });

    test('dedups by path (no change, no timestamp bump)', () {
      final created = DateTime.utc(2026, 6, 14, 12);
      final later = DateTime.utc(2026, 6, 14, 13);
      final p = buildNewPlaylist(
          id: 'p1', name: 'P', tracks: [track('/a.mp3')], now: created);
      final added = appendTrack(p, track('/a.mp3'), later);
      expect(added, isFalse);
      expect(p.tracks.length, 1);
      expect(p.updatedAt, created); // unchanged
    });
  });

  group('cleanPlaylistName', () {
    test('trims surrounding whitespace but keeps inner spaces', () {
      expect(cleanPlaylistName('  My Mix  '), 'My Mix');
    });

    test('returns null for blank or whitespace-only input', () {
      expect(cleanPlaylistName(''), isNull);
      expect(cleanPlaylistName('   '), isNull);
    });
  });
}
