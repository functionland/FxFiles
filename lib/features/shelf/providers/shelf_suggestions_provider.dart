import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_suggestion_dismissals_service.dart';
import 'package:fula_files/core/services/shelf_tag_suggester.dart';
import 'package:fula_files/features/shelf/providers/shelf_providers.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Internal monotonically-incrementing counter that ticks every time
/// the dismissals box mutates. Providers watch this so they
/// re-evaluate when a tag is dismissed/undismissed without us having
/// to plumb a per-key stream out of Hive.
final shelfDismissalsVersionProvider = NotifierProvider<_DismissalsVersionNotifier, int>(
  _DismissalsVersionNotifier.new,
);

class _DismissalsVersionNotifier extends Notifier<int> {
  VoidCallback? _listener;

  @override
  int build() {
    _listener = () {
      // Hive listener fires on the same isolate; this is safe to
      // mutate state directly.
      state = state + 1;
    };
    ShelfSuggestionDismissalsService.instance.addListener(_listener!);
    ref.onDispose(() {
      if (_listener != null) {
        ShelfSuggestionDismissalsService.instance.removeListener(_listener!);
      }
    });
    return 0;
  }
}

/// Suggested tags for a single dump. Reads:
///   * `shelfItemsProvider` → live list of items (find the one matching [dumpId])
///   * `tagProvider` → all user tags + load state
///   * `fileTagsProvider` for this dump → tag ids already applied
///   * `shelfDismissalsVersionProvider` → re-evaluate after dismiss/undismiss
///
/// Returns an empty list while inputs are loading or when the item is
/// gone. The pure matcher in [ShelfTagSuggester] does all the work; this
/// provider's only job is to wire its inputs to Riverpod's reactivity.
final shelfSuggestionsProvider =
    Provider.family<List<TagSuggestion>, String>((ref, dumpId) {
  final tagState = ref.watch(tagProvider);
  if (tagState.tags.isEmpty) return const <TagSuggestion>[];

  final itemsAsync = ref.watch(shelfItemsProvider);
  final items = itemsAsync.maybeWhen(
    data: (v) => v,
    orElse: () => const <ShelfItem>[],
  );
  if (items.isEmpty) return const <TagSuggestion>[];
  ShelfItem? item;
  for (final candidate in items) {
    if (candidate.id == dumpId) {
      item = candidate;
      break;
    }
  }
  if (item == null) return const <TagSuggestion>[];

  // Don't propose tags until the enricher has at least had a chance to
  // populate autoTitle / autoDescription / mlLabels. For failed
  // enrichments we still try (falls back to originalName + textPayload
  // which often carry useful signal for links).
  if (item.enrichmentStatus == ShelfEnrichmentStatus.pending) {
    return const <TagSuggestion>[];
  }

  final appliedAsync = ref.watch(
    fileTagsProvider(FileTagQuery(localPath: 'dump://$dumpId')),
  );
  final appliedTagIds = appliedAsync.maybeWhen(
    data: (tags) => tags.map((t) => t.id).toSet(),
    orElse: () => const <String>{},
  );

  ref.watch(shelfDismissalsVersionProvider);
  final dismissed = ShelfSuggestionDismissalsService.instance.getDismissedFor(dumpId);

  return ShelfTagSuggester.suggest(
    item: item,
    allTags: tagState.tags,
    appliedTagIds: appliedTagIds,
    dismissedTagIds: dismissed,
  );
});
