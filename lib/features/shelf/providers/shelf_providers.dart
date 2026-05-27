import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';

/// Singleton-backed provider for the Shelf storage service. Kept simple
/// (no `family`, no dispose) so the same instance is shared with the
/// background-isolate code path.
final shelfStorageServiceProvider = Provider<ShelfStorageService>(
  (_) => ShelfStorageService.instance,
);

/// Live list of dump items, streamed from the Hive `dump_items` box.
/// Re-emits the full list on every box mutation.
final shelfItemsProvider = StreamProvider<List<ShelfItem>>((ref) {
  final service = ref.watch(shelfStorageServiceProvider);
  return service.watch();
});

/// Live snapshot of the persisted user-defined display order. Emits an
/// empty list when no reorder has been done yet.
final shelfOrderProvider = StreamProvider<List<String>>((ref) {
  final service = ref.watch(shelfStorageServiceProvider);
  return service.watchOrder();
});

/// Item ids awaiting cloud-side cleanup. Rendered as a Set for O(1)
/// containment checks inside [sortedShelfItemsProvider]. The set
/// shrinks as `ShelfService.retryPendingDeletes` finishes their cloud
/// cleanups in the background.
final shelfPendingDeletesProvider = StreamProvider<Set<String>>((ref) {
  final service = ref.watch(shelfStorageServiceProvider);
  return service.watchPendingDeleteIds();
});

/// `true` while the user is mid-drag on a Shelf tile. While set, the
/// [sortedShelfItemsProvider] returns the snapshot captured at the
/// start of the drag so a list mutation (e.g. a share arriving from
/// another app) doesn't shift the grid out from under the user's
/// finger. The drag-end callback flips this back to `false`.
///
/// Modeled as a `NotifierProvider<ShelfDraggingNotifier, bool>` rather
/// than `StateProvider` because Riverpod 3.x removed the latter; the
/// notifier exposes a single `setDragging` mutator to keep the
/// surface obvious.
class ShelfDraggingNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setDragging(bool isDragging) => state = isDragging;
}

final shelfDraggingProvider =
    NotifierProvider<ShelfDraggingNotifier, bool>(ShelfDraggingNotifier.new);

/// Items sorted by the user's persisted display order, with pending-
/// delete tombstones filtered out. This is the input to
/// [filteredShelfItemsProvider]; filter + search apply on top of this
/// pre-sorted list.
///
/// During a drag (`shelfDraggingProvider == true`) this returns the
/// last list it computed BEFORE the drag started — so the order of
/// underlying ShelfItems doesn't shift under the user's finger while
/// a `ReorderableGridView` is interpreting drop indices.
final sortedShelfItemsProvider =
    NotifierProvider<SortedShelfItemsNotifier, List<ShelfItem>>(
  SortedShelfItemsNotifier.new,
);

class SortedShelfItemsNotifier extends Notifier<List<ShelfItem>> {
  /// Last computed snapshot, kept so we can return it verbatim while
  /// dragging is active. The notifier instance is stable across
  /// `build()` calls so this survives rebuilds.
  List<ShelfItem> _lastNonDraggingSnapshot = const <ShelfItem>[];

  @override
  List<ShelfItem> build() {
    final isDragging = ref.watch(shelfDraggingProvider);
    if (isDragging) {
      // Freeze: do NOT read items/order/pending — that would create a
      // dependency-changed rebuild as soon as any of those streams
      // ticks, defeating the freeze. Returning the cached snapshot
      // verbatim is the whole point.
      return _lastNonDraggingSnapshot;
    }

    final items = ref.watch(shelfItemsProvider).maybeWhen(
          data: (v) => v,
          orElse: () => const <ShelfItem>[],
        );
    final order = ref.watch(shelfOrderProvider).maybeWhen(
          data: (v) => v,
          orElse: () => const <String>[],
        );
    final pending = ref.watch(shelfPendingDeletesProvider).maybeWhen(
          data: (v) => v,
          orElse: () => const <String>{},
        );

    final visible =
        items.where((i) => !pending.contains(i.id)).toList(growable: false);
    final byId = <String, ShelfItem>{for (final i in visible) i.id: i};

    final result = <ShelfItem>[];
    final used = <String>{};
    for (final id in order) {
      final i = byId[id];
      if (i != null) {
        result.add(i);
        used.add(id);
      }
    }
    // Defensive: items missing from the order list (e.g. a partial
    // restore where `'order'` was a v1 payload absent). Append them
    // sorted by receivedAt desc so the screen still has a sensible
    // shape even before the user reorders.
    if (used.length < visible.length) {
      final missing = visible.where((i) => !used.contains(i.id)).toList()
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      result.addAll(missing);
    }

    _lastNonDraggingSnapshot = result;
    return result;
  }
}

/// Filter state for the Shelf screen. Tag filtering (R17 of the Shelf
/// plan + Phase 7c) is added in Session 3b — the `tagIds` field is
/// deliberately omitted here so this slice can land in Session 1
/// without forward-referencing the tag system.
@immutable
class ShelfFilter {
  final Set<ShelfCategory> categories;
  final DateTimeRange? dateRange;

  const ShelfFilter({
    this.categories = const <ShelfCategory>{},
    this.dateRange,
  });

  bool get isEmpty => categories.isEmpty && dateRange == null;

  ShelfFilter copyWith({
    Set<ShelfCategory>? categories,
    DateTimeRange? dateRange,
    bool clearDateRange = false,
  }) {
    return ShelfFilter(
      categories: categories ?? this.categories,
      dateRange: clearDateRange ? null : (dateRange ?? this.dateRange),
    );
  }
}

class ShelfFilterNotifier extends Notifier<ShelfFilter> {
  @override
  ShelfFilter build() => const ShelfFilter();

  void toggleCategory(ShelfCategory c) {
    final next = Set<ShelfCategory>.from(state.categories);
    if (!next.add(c)) next.remove(c);
    state = state.copyWith(categories: next);
  }

  void clearCategories() {
    state = state.copyWith(categories: const <ShelfCategory>{});
  }

  void setDateRange(DateTimeRange? range) {
    state = state.copyWith(
      dateRange: range,
      clearDateRange: range == null,
    );
  }

  void reset() => state = const ShelfFilter();
}

final shelfFilterProvider = NotifierProvider<ShelfFilterNotifier, ShelfFilter>(
  ShelfFilterNotifier.new,
);

class ShelfSearchNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
  void clear() => state = '';
}

final shelfSearchProvider = NotifierProvider<ShelfSearchNotifier, String>(
  ShelfSearchNotifier.new,
);

/// Synchronous filtered + searched view over the user-ordered list
/// from [sortedShelfItemsProvider]. Filter + search apply on TOP of
/// the user-defined order — items keep their persisted positions
/// within the filtered subset. Returns an empty list while upstream
/// streams are still loading (R17: no double-wrapped AsyncValue).
final filteredShelfItemsProvider = Provider<List<ShelfItem>>((ref) {
  final items = ref.watch(sortedShelfItemsProvider);
  final filter = ref.watch(shelfFilterProvider);
  final query = ref.watch(shelfSearchProvider).trim().toLowerCase();

  Iterable<ShelfItem> result = items;

  if (filter.categories.isNotEmpty) {
    result = result.where((i) => filter.categories.contains(i.category));
  }

  final range = filter.dateRange;
  if (range != null) {
    final startMs = range.start.millisecondsSinceEpoch;
    final endMs = range.end
        .add(const Duration(days: 1))
        .subtract(const Duration(milliseconds: 1))
        .millisecondsSinceEpoch;
    result = result.where((i) {
      final ms = i.receivedAt.millisecondsSinceEpoch;
      return ms >= startMs && ms <= endMs;
    });
  }

  if (query.isNotEmpty) {
    result = result.where((i) {
      if (i.originalName.toLowerCase().contains(query)) return true;
      final at = i.autoTitle?.toLowerCase();
      if (at != null && at.contains(query)) return true;
      final ad = i.autoDescription?.toLowerCase();
      if (ad != null && ad.contains(query)) return true;
      final tp = i.textPayload?.toLowerCase();
      if (tp != null && tp.contains(query)) return true;
      for (final l in i.mlLabels) {
        if (l.toLowerCase().contains(query)) return true;
      }
      return false;
    });
  }

  // Order is already applied by sortedShelfItemsProvider — no extra
  // sort here. (The previous receivedAt-desc sort was the implicit
  // default before user reorder existed.)
  return result.toList(growable: false);
});
