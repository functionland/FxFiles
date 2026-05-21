import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_storage_service.dart';

/// Singleton-backed provider for the Dump storage service. Kept simple
/// (no `family`, no dispose) so the same instance is shared with the
/// background-isolate code path.
final dumpStorageServiceProvider = Provider<DumpStorageService>(
  (_) => DumpStorageService.instance,
);

/// Live list of dump items, streamed from the Hive `dump_items` box.
/// Re-emits the full list on every box mutation.
final dumpItemsProvider = StreamProvider<List<DumpItem>>((ref) {
  final service = ref.watch(dumpStorageServiceProvider);
  return service.watch();
});

/// Filter state for the Dump screen. Tag filtering (R17 of the Dump
/// plan + Phase 7c) is added in Session 3b — the `tagIds` field is
/// deliberately omitted here so this slice can land in Session 1
/// without forward-referencing the tag system.
@immutable
class DumpFilter {
  final Set<DumpCategory> categories;
  final DateTimeRange? dateRange;

  const DumpFilter({
    this.categories = const <DumpCategory>{},
    this.dateRange,
  });

  bool get isEmpty => categories.isEmpty && dateRange == null;

  DumpFilter copyWith({
    Set<DumpCategory>? categories,
    DateTimeRange? dateRange,
    bool clearDateRange = false,
  }) {
    return DumpFilter(
      categories: categories ?? this.categories,
      dateRange: clearDateRange ? null : (dateRange ?? this.dateRange),
    );
  }
}

class DumpFilterNotifier extends Notifier<DumpFilter> {
  @override
  DumpFilter build() => const DumpFilter();

  void toggleCategory(DumpCategory c) {
    final next = Set<DumpCategory>.from(state.categories);
    if (!next.add(c)) next.remove(c);
    state = state.copyWith(categories: next);
  }

  void clearCategories() {
    state = state.copyWith(categories: const <DumpCategory>{});
  }

  void setDateRange(DateTimeRange? range) {
    state = state.copyWith(
      dateRange: range,
      clearDateRange: range == null,
    );
  }

  void reset() => state = const DumpFilter();
}

final dumpFilterProvider = NotifierProvider<DumpFilterNotifier, DumpFilter>(
  DumpFilterNotifier.new,
);

class DumpSearchNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
  void clear() => state = '';
}

final dumpSearchProvider = NotifierProvider<DumpSearchNotifier, String>(
  DumpSearchNotifier.new,
);

/// Synchronous filtered + searched view over the current `dumpItemsProvider`
/// snapshot. Returns an empty list while the stream is loading or in error
/// (R17: do NOT double-wrap `AsyncValue`).
final filteredDumpItemsProvider = Provider<List<DumpItem>>((ref) {
  final asyncItems = ref.watch(dumpItemsProvider);
  final items = asyncItems.maybeWhen(
    data: (v) => v,
    orElse: () => const <DumpItem>[],
  );
  final filter = ref.watch(dumpFilterProvider);
  final query = ref.watch(dumpSearchProvider).trim().toLowerCase();

  Iterable<DumpItem> result = items;

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
