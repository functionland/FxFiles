// Pure-function tests for the on-device tag suggester. Exercises the
// containment scoring, host-intent table, stop-word + ML-label filters,
// applied/dismissed exclusion, and the empty-input edge cases. No
// Riverpod / no Hive — the suggester is a static method over plain
// models, so these run as pure unit tests with `flutter test`.

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/shelf_tag_suggester.dart';

FileTag _tag(String id, String name) => FileTag(
      id: id,
      name: name,
      colorValue: 0xFF000000,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

ShelfItem _item({
  String id = 'd1',
  String originalName = 'item.bin',
  ShelfCategory category = ShelfCategory.other,
  String? autoTitle,
  String? autoDescription,
  String? textPayload,
  List<String> mlLabels = const <String>[],
  ShelfEnrichmentStatus enrichmentStatus = ShelfEnrichmentStatus.done,
}) =>
    ShelfItem(
      id: id,
      receivedAt: DateTime(2026, 5, 24),
      originalName: originalName,
      sizeBytes: 1024,
      localCachePath: '/tmp/$id',
      category: category,
      contentSha: 'sha-$id',
      autoTitle: autoTitle,
      autoDescription: autoDescription,
      textPayload: textPayload,
      mlLabels: mlLabels,
      enrichmentStatus: enrichmentStatus,
    );

void main() {
  group('ShelfTagSuggester.suggest', () {
    test('IMDb link → must_watch via host-intent table', () {
      final tags = [_tag('t1', 'must_watch'), _tag('t2', 'recipes')];
      final item = _item(
        category: ShelfCategory.link,
        textPayload: 'https://www.imdb.com/title/tt1234567/',
        autoTitle: 'Dune: Part Two (2024) - IMDb',
        autoDescription: 'Dune: Part Two: Directed by Denis Villeneuve.',
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result.map((s) => s.tag.id), ['t1']);
    });

    test('Netflix link with no enriched text passes via host endorsement', () {
      final tags = [_tag('t1', 'must_watch')];
      final item = _item(
        category: ShelfCategory.link,
        textPayload: 'https://www.netflix.com/title/12345',
        autoTitle: null,
        autoDescription: null,
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      // Netflix's intent set includes "watch"; the must_watch tag's
      // "watch" token endorses it — passes regardless of zero text
      // containment. This is the user's "share a movie link → tag it
      // must_watch automatically" flow.
      expect(result.map((s) => s.tag.id), ['t1']);
    });

    test('Spotify link with "music" tag passes via host endorsement', () {
      final tags = [_tag('t1', 'music')];
      final item = _item(
        category: ShelfCategory.link,
        textPayload: 'https://open.spotify.com/track/xyz',
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      // Single-token "music" tag matches Spotify's intent set — passes
      // even with no enriched text. The intent table is curated so
      // unrelated tags (recipes, pets) don't trigger on Spotify URLs.
      expect(result.map((s) => s.tag.id), ['t1']);
    });

    test('Host endorsement does NOT trigger unrelated tags', () {
      // Tags whose tokens don't appear in Spotify's intent set must
      // not be suggested for a Spotify URL — confirms host-endorsement
      // is gated by tag-intent overlap, not "any tag on a known host".
      final tags = [_tag('t1', 'recipes'), _tag('t2', 'pets')];
      final item = _item(
        category: ShelfCategory.link,
        textPayload: 'https://open.spotify.com/track/xyz',
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result, isEmpty);
    });

    test('Spotify link with both text and host signal passes', () {
      final tags = [_tag('t1', 'music')];
      final item = _item(
        category: ShelfCategory.link,
        textPayload: 'https://open.spotify.com/track/xyz',
        autoTitle: 'Some Song · Music · Spotify',
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result.map((s) => s.tag.id), contains('t1'));
    });

    test('ML labels match a tag — generic labels filtered', () {
      final tags = [_tag('t1', 'pets'), _tag('t2', 'art')];
      final item = _item(
        category: ShelfCategory.image,
        originalName: 'IMG_4242.jpg',
        autoTitle: 'Pets',
        mlLabels: const ['Pets', 'Cat', 'Rectangle', 'Font'],
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      // "Rectangle" and "Font" are blacklisted; the tile shouldn't
      // suggest the user's "art" tag just because the labeler picked
      // those up.
      expect(result.map((s) => s.tag.id), ['t1']);
    });

    test('Note containing tag-name token in autoTitle matches', () {
      final tags = [_tag('t1', 'recipes')];
      final item = _item(
        category: ShelfCategory.note,
        autoTitle: 'Sourdough recipe',
        autoDescription: 'Mix flour, water, salt, starter...',
        textPayload: 'Sourdough recipe\nMix flour, water, salt, starter...',
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result.map((s) => s.tag.id), ['t1']);
    });

    test('Already-applied tags are excluded', () {
      final tags = [_tag('t1', 'must_watch')];
      final item = _item(
        category: ShelfCategory.link,
        textPayload: 'https://www.imdb.com/title/tt1234567/',
        autoTitle: 'Dune: Part Two (2024) - IMDb',
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{'t1'},
        dismissedTagIds: const <String>{},
      );
      expect(result, isEmpty);
    });

    test('Dismissed tags are excluded', () {
      final tags = [_tag('t1', 'must_watch')];
      final item = _item(
        category: ShelfCategory.link,
        textPayload: 'https://www.imdb.com/title/tt1234567/',
        autoTitle: 'Dune: Part Two (2024) - IMDb',
      );
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{'t1'},
      );
      expect(result, isEmpty);
    });

    test('Stop-word-only tags are skipped (the, and, …)', () {
      final tags = [_tag('t1', 'the')];
      final item = _item(autoTitle: 'The Quick Brown Fox');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result, isEmpty);
    });

    test('Short tag tokens (<3 chars) dropped — "a" tag does not match', () {
      final tags = [_tag('t1', 'a')];
      final item = _item(autoTitle: 'a regular phrase');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result, isEmpty);
    });

    test('Stemming: tag "movie" matches haystack "movies"', () {
      final tags = [_tag('t1', 'movie')];
      final item = _item(autoTitle: 'Top 10 movies of 2024');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result.map((s) => s.tag.id), ['t1']);
    });

    test('Stemming respects length delta (movie does not match moviegoer)', () {
      final tags = [_tag('t1', 'movie')];
      final item = _item(autoTitle: 'Reflections of a moviegoer');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      // delta = 4 — outside the stem allowance, so no match.
      expect(result, isEmpty);
    });

    test('Multi-token tag requires both tokens to clear threshold', () {
      final tags = [_tag('t1', 'must_watch')];
      // Only one of two tag tokens present, no host signal.
      final item = _item(autoTitle: 'My to-watch list');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result, isEmpty);
    });

    test('Top-N capping — at most three suggestions returned', () {
      final tags = [
        for (var i = 0; i < 6; i++) _tag('t$i', 'kitchen'),
      ];
      final item = _item(autoTitle: 'kitchen knives');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result.length, lessThanOrEqualTo(3));
    });

    test('Empty tag list returns empty', () {
      final item = _item(autoTitle: 'anything');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: const <FileTag>[],
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result, isEmpty);
    });

    test('Empty haystack returns empty even with tags', () {
      final tags = [_tag('t1', 'something')];
      final item = _item(originalName: '');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      expect(result, isEmpty);
    });

    test('Sort order is by score desc, then tag name asc on ties', () {
      final tags = [
        _tag('t1', 'zeta'),
        _tag('t2', 'alpha'),
      ];
      final item = _item(autoTitle: 'alpha zeta');
      final result = ShelfTagSuggester.suggest(
        item: item,
        allTags: tags,
        appliedTagIds: const <String>{},
        dismissedTagIds: const <String>{},
      );
      // Same score (single-token tag, single hit). Name asc → alpha
      // first.
      expect(result.map((s) => s.tag.id), ['t2', 't1']);
    });
  });
}
