// Device-free unit tests for the pure playlist cloud-merge + tombstone parse.
//
// These cover the bug-prone Type-B v8 logic (v8-wins-by-id, subtract-tombstones-
// AFTER-combine, tombstone-key parsing) WITHOUT a device/SDK — the service flows
// themselves call the non-injectable FulaApiService singleton and are covered by
// the resolver + guard-wiring tests instead.
//
// Run: flutter test test/unit/core/services/playlist_merge_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/core/services/playlist_service.dart';

Playlist _pl(String id, {String? name}) =>
    Playlist(id: id, name: name ?? 'pl-$id');

void main() {
  group('mergePlaylists (pure cloud [v8, legacy] merge)', () {
    test('union of v8-only and legacy-only ids', () {
      final merged = mergePlaylists(
        v8: [_pl('a')],
        legacy: [_pl('b')],
        tombstoned: const <String>{},
      );
      expect(merged.map((p) => p.id).toSet(), {'a', 'b'});
    });

    test('same id present in both: v8 wins', () {
      final merged = mergePlaylists(
        v8: [_pl('a', name: 'from-v8')],
        legacy: [_pl('a', name: 'from-legacy')],
        tombstoned: const <String>{},
      );
      expect(merged, hasLength(1));
      expect(merged.single.name, 'from-v8');
    });

    test('a tombstoned id is dropped even if still listed in v8 and/or legacy', () {
      final merged = mergePlaylists(
        v8: [_pl('a'), _pl('b')],
        legacy: [_pl('a'), _pl('c')],
        tombstoned: const <String>{'a'},
      );
      expect(merged.map((p) => p.id).toSet(), {'b', 'c'});
    });

    test('empty tombstone set ⇒ no subtraction (today\'s behaviour)', () {
      final merged = mergePlaylists(
        v8: const <Playlist>[],
        legacy: [_pl('a')],
        tombstoned: const <String>{},
      );
      expect(merged.map((p) => p.id).toSet(), {'a'});
    });

    test('subtract happens AFTER combine — a tombstoned v8 winner is still removed', () {
      final merged = mergePlaylists(
        v8: [_pl('a', name: 'from-v8')],
        legacy: [_pl('a', name: 'from-legacy')],
        tombstoned: const <String>{'a'},
      );
      expect(merged, isEmpty);
    });

    test('all empty ⇒ empty', () {
      expect(
        mergePlaylists(
          v8: const <Playlist>[],
          legacy: const <Playlist>[],
          tombstoned: const <String>{},
        ),
        isEmpty,
      );
    });
  });

  group('parseTombstonedPlaylistIds', () {
    test('extracts ids from playlist-deleted/{id}.json keys', () {
      final ids = parseTombstonedPlaylistIds(const [
        'playlist-deleted/aaa.json',
        'playlist-deleted/bbb.json',
      ]);
      expect(ids, {'aaa', 'bbb'});
    });

    test('ignores non-json / directory-ish / empty keys without throwing', () {
      final ids = parseTombstonedPlaylistIds(const [
        'playlist-deleted/ok.json',
        'playlist-deleted/', // directory-ish (no basename)
        'playlist-deleted/nope.txt', // wrong suffix
        '', // empty
      ]);
      expect(ids, {'ok'});
    });
  });
}
