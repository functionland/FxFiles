import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/features/dump/providers/dump_providers.dart';

/// Session 1 placeholder. Renders an empty-state hint when the
/// `dump_items` box is empty, or a debug-only count of items
/// otherwise. The grid view + filter bar + search + FAB land in
/// Session 3 / Session 3b.
class DumpScreen extends ConsumerWidget {
  const DumpScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(dumpItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dump'),
      ),
      body: asyncItems.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load Dump: $e'),
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const _DumpEmptyState();
          }
          // Session 1 stub: list items by originalName. Session 3 replaces
          // this with the full grid + thumbnails.
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              return ListTile(
                leading: const Icon(LucideIcons.inbox),
                title: Text(item.autoTitle ?? item.originalName),
                subtitle: Text(item.category.name),
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
