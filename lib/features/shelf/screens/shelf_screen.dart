import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

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
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              // Slightly taller (was 0.78) so 2 lines of description
              // and the tag chip row don't squeeze the thumbnail.
              childAspectRatio: 0.70,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final item = filtered[index];
              return ShelfTile(
                item: item,
                onTap: () => context.push('/shelf/${item.id}'),
              );
            },
          );
        },
      ),
    );
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
