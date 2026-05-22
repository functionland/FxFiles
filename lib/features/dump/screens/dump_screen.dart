import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/features/dump/providers/dump_providers.dart';
import 'package:fula_files/features/dump/widgets/dump_add_sheet.dart';
import 'package:fula_files/features/dump/widgets/dump_filter_bar.dart';
import 'package:fula_files/features/dump/widgets/dump_tile.dart';

/// Grid view over the user's dumps. Renders an empty-state when the
/// Hive box is empty, the populated grid otherwise. Tap a tile →
/// `/dump/:id`.
///
/// Filter chips + Date chip live in [DumpFilterBar] and read/write
/// `dumpFilterProvider`. The expandable search TextField writes to
/// `dumpSearchProvider` after a 250 ms debounce. The composed view
/// (filter + search applied) is rendered via `filteredDumpItemsProvider`
/// — a synchronous `Provider<List<DumpItem>>` (no double-wrapped
/// AsyncValue per R17).
class DumpScreen extends ConsumerStatefulWidget {
  const DumpScreen({super.key});

  @override
  ConsumerState<DumpScreen> createState() => _DumpScreenState();
}

class _DumpScreenState extends ConsumerState<DumpScreen> {
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
          await DumpLostDataHandler.instance.retrievePendingPhoto();
      if (lostPath == null || !mounted) return;
      context.push('/dump/doodle', extra: lostPath);
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
      ref.read(dumpSearchProvider.notifier).set(value);
    });
  }

  void _closeSearch() {
    setState(() => _isSearchOpen = false);
    _searchController.clear();
    ref.read(dumpSearchProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final asyncItems = ref.watch(dumpItemsProvider);
    final filtered = ref.watch(filteredDumpItemsProvider);
    final filter = ref.watch(dumpFilterProvider);
    final hasQuery = ref.watch(dumpSearchProvider).isNotEmpty;

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => DumpAddSheet.show(context),
        tooltip: 'Add to Dump',
        child: const Icon(LucideIcons.plus),
      ),
      appBar: AppBar(
        title: _isSearchOpen
            ? TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  hintText: 'Search dumps',
                  border: InputBorder.none,
                ),
              )
            : const Text('Dump'),
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
          child: const DumpFilterBar(),
        ),
      ),
      body: asyncItems.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load Dump: $e'),
          ),
        ),
        data: (allItems) {
          if (allItems.isEmpty) return const _DumpEmptyState();
          if (filtered.isEmpty) {
            return _FilteredEmptyState(
              hasFilter: !filter.isEmpty || hasQuery,
              onClear: () {
                ref.read(dumpFilterProvider.notifier).reset();
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
              childAspectRatio: 0.78,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final item = filtered[index];
              return DumpTile(
                item: item,
                onTap: () => context.push('/dump/${item.id}'),
              );
            },
          );
        },
      ),
    );
  }
}

class _DumpEmptyState extends StatelessWidget {
  const _DumpEmptyState();

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
              'No dumps yet',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Share content from any app to "FxFiles Dump" to capture it here.',
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
