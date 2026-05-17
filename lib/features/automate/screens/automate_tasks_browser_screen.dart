import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/automate/providers/automate_task_provider.dart';

/// Lists all Automate tasks — one per "automate-tasks-*" tag.
class AutomateTasksBrowserScreen extends ConsumerWidget {
  const AutomateTasksBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(automateTagsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Automate'),
      ),
      body: tags.isEmpty
          ? _buildEmptyState(context, ref)
          : _buildList(context, ref, tags),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createTask(context, ref),
        tooltip: 'New Automate task',
        child: const Icon(LucideIcons.plus),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.zap, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No Automate tasks yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Attach a CSV of contacts, build a message template with '
              'placeholders like {Name} or {Phone}, then send each row '
              'via WhatsApp / Telegram / SMS / Email.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _createTask(context, ref),
              icon: const Icon(LucideIcons.plus),
              label: const Text('New Automate task'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, List<FileTag> tags) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: tags.length,
      itemBuilder: (context, index) {
        final tag = tags[index];
        return _AutomateTaskListTile(
          tag: tag,
          onTap: () =>
              context.push('/automate-tasks/${tag.id}', extra: tag),
          onDelete: () => _deleteTask(context, ref, tag),
        );
      },
    );
  }

  Future<void> _createTask(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Automate task'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Task name',
            hintText: 'Customer outreach',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final tag = await ref
        .read(automateTaskProvider.notifier)
        .createTask(name.trim());
    if (tag != null && context.mounted) {
      context.push('/automate-tasks/${tag.id}', extra: tag);
    }
  }

  Future<void> _deleteTask(
      BuildContext context, WidgetRef ref, FileTag tag) async {
    final displayName = tag.name.replaceFirst('automate-tasks-', '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Automate task'),
        content: Text(
          'Delete "$displayName"? Attached files are untagged but stay '
          'on disk. The message template + send plan are removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(automateTaskProvider.notifier).deleteTask(tag.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "$displayName"')),
        );
      }
    }
  }
}

class _AutomateTaskListTile extends StatelessWidget {
  final FileTag tag;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _AutomateTaskListTile({
    required this.tag,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(tag.colorValue);
    final displayName = tag.name.replaceFirst('automate-tasks-', '');

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(child: Icon(LucideIcons.zap, size: 20)),
      ),
      title: Text(displayName),
      subtitle: Text(
        '${tag.fileCount} file${tag.fileCount == 1 ? '' : 's'}',
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(LucideIcons.trash2, size: 18, color: Colors.red),
                SizedBox(width: 8),
                Text('Delete', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
