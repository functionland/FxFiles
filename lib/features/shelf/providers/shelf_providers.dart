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

/// Synchronous filtered + searched view over the current `shelfItemsProvider`
/// snapshot. Returns an empty list while the stream is loading or in error
/// (R17: do NOT double-wrap `AsyncValue`).
final filteredShelfItemsProvider = Provider<List<ShelfItem>>((ref) {
  final asyncItems = ref.watch(shelfItemsProvider);
  final items = asyncItems.maybeWhen(
    data: (v) => v,
    orElse: () => const <ShelfItem>[],
  );
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

  final sorted = result.toList()
    ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  return sorted;
});
