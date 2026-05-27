import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';
import 'package:fula_files/features/shelf/providers/shelf_providers.dart';
import 'package:fula_files/features/shelf/widgets/shelf_add_sheet.dart';
import 'package:fula_files/features/shelf/widgets/shelf_filter_bar.dart';
import 'package:fula_files/features/shelf/widgets/shelf_tile.dart';

/// Grid view over the user's dumps. Renders an empty-state when the
/// Hive box is empty, the populated grid otherwise. Tap a tile →
/// `/dump/:id`.
///
/// Filter chips + Date chip live in [ShelfFilterBar] and read/write
/// `shelfFilterProvider`. The expandable search TextField writes to
/// `shelfSearchProvider` after a 250 ms debounce. The composed view
/// (filter + search applied) is rendered via `filteredShelfItemsProvider`
/// — a synchronous `Provider<List<ShelfItem>>` (no double-wrapped
/// AsyncValue per R17).
class ShelfScreen extends ConsumerStatefulWidget {
  const ShelfScreen({super.key});

  @override
  ConsumerState<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends ConsumerState<ShelfScreen> {
  static const Duration _kSearchDebounce = Duration(milliseconds: 250);

  bool _isSearchOpen = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    // Recover from Android Activity-death during `pickImage` (H1).
    // If the OS killed the main process between camera launch and
    // return, the photo is held by `image_picker` and surfaces here
    // on the next foreground.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final lostPath =
          await ShelfLostDataHandler.instance.retrievePendingPhoto();
      if (lostPath == null || !mounted) return;
      context.push('/shelf/doodle', extra: lostPath);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_kSearchDebounce, () {
      if (!mounted) return;
      ref.read(shelfSearchProvider.notifier).set(value);
    });
  }

  void _closeSearch() {
    setState(() => _isSearchOpen = false);
    _searchController.clear();
    ref.read(shelfSearchProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final asyncItems = ref.watch(shelfItemsProvider);
    final filtered = ref.watch(filteredShelfItemsProvider);
    final filter = ref.watch(shelfFilterProvider);
    final hasQuery = ref.watch(shelfSearchProvider).isNotEmpty;

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => ShelfAddSheet.show(context),
        tooltip: 'Add to Shelf',
        child: const Icon(LucideIcons.plus),
      ),
      appBar: AppBar(
        title: _isSearchOpen
            ? TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  hintText: 'Search shelf',
                  border: InputBorder.none,
                ),
              )
            : const Text('Shelf'),
        actions: [
          if (_isSearchOpen)
            IconButton(
              icon: const Icon(LucideIcons.x),
              tooltip: 'Close search',
              onPressed: _closeSearch,
            )
          else
            IconButton(
              icon: const Icon(LucideIcons.search),
              tooltip: 'Search',
              onPressed: () => setState(() => _isSearchOpen = true),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: const ShelfFilterBar(),
        ),
      ),
      body: asyncItems.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load Shelf: $e'),
          ),
        ),
        data: (allItems) {
          if (allItems.isEmpty) return const _ShelfEmptyState();
          if (filtered.isEmpty) {
            return _FilteredEmptyState(
              hasFilter: !filter.isEmpty || hasQuery,
              onClear: () {
                ref.read(shelfFilterProvider.notifier).reset();
                _closeSearch();
              },
            );
          }
          // Reorder is only available on the full unfiltered list —
          // dragging a tile within a filtered subset would mean the
          // visible positions don't map cleanly onto the underlying
          // persisted order (index drift). Clearing filters re-enables
          // reorder. The filter bar makes that one-tap.
          final reorderEnabled = filter.isEmpty && !hasQuery;
          const gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            // Slightly taller (was 0.78) so 2 lines of description
            // and the tag chip row don't squeeze the thumbnail.
            childAspectRatio: 0.70,
          );
          const padding = EdgeInsets.fromLTRB(8, 4, 8, 16);

          if (!reorderEnabled) {
            return GridView.builder(
              padding: padding,
              gridDelegate: gridDelegate,
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final item = filtered[index];
                return ShelfTile(
                  key: ValueKey(item.id),
                  item: item,
                  onTap: () => context.push('/shelf/${item.id}'),
                );
              },
            );
          }

          return ReorderableGridView.builder(
            padding: padding,
            gridDelegate: gridDelegate,
            itemCount: filtered.length,
            onDragStart: (_) {
              HapticFeedback.mediumImpact();
              ref.read(shelfDraggingProvider.notifier).setDragging(true);
            },
            onReorder: (oldIndex, newIndex) =>
                _handleReorder(filtered, oldIndex, newIndex),
            // Adds a subtle scale + shadow to the dragged tile so the
            // user can see which item they're carrying.
            dragWidgetBuilderV2: DragWidgetBuilderV2(
              builder: (index, child, screenshot) {
                return Transform.scale(
                  scale: 1.05,
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: child,
                  ),
                );
              },
            ),
            itemBuilder: (context, index) {
              final item = filtered[index];
              return ShelfTile(
                key: ValueKey(item.id),
                item: item,
                onTap: () => context.push('/shelf/${item.id}'),
              );
            },
          );
        },
      ),
    );
  }

  /// Persists a reorder. `onReorder` always fires on drop (not during
  /// the drag), so this is the single place where we flip the
  /// dragging flag back to `false` and commit the new sequence.
  void _handleReorder(List<ShelfItem> filtered, int oldIndex, int newIndex) {
    final ids = filtered.map((i) => i.id).toList();
    if (oldIndex < 0 ||
        oldIndex >= ids.length ||
        newIndex < 0 ||
        newIndex >= ids.length) {
      ref.read(shelfDraggingProvider.notifier).setDragging(false);
      return;
    }
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);

    // Persist asynchronously, but flip the dragging flag synchronously
    // so the sortedShelfItemsProvider is unfrozen on the next frame
    // (with the new order already on disk by then in normal cases).
    unawaited(ShelfStorageService.instance.setOrder(ids));
    ref.read(shelfDraggingProvider.notifier).setDragging(false);
  }
}

class _ShelfEmptyState extends StatelessWidget {
  const _ShelfEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.inbox,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No items yet',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Share content from any app to "Shelf" to capture it here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilteredEmptyState extends StatelessWidget {
  final bool hasFilter;
  final VoidCallback onClear;
  const _FilteredEmptyState({required this.hasFilter, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.searchX,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No matches',
              style: theme.textTheme.titleMedium,
            ),
            if (hasFilter) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onClear,
                child: const Text('Clear filters'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
