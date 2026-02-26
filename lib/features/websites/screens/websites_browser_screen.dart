import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/websites/providers/website_provider.dart';

/// Screen listing all website projects (tags with "websites-" prefix)
class WebsitesBrowserScreen extends ConsumerWidget {
  const WebsitesBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final websiteTags = ref.watch(websiteTagsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Websites'),
      ),
      body: websiteTags.isEmpty
          ? _buildEmptyState(context, ref)
          : _buildList(context, ref, websiteTags),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createWebsite(context, ref),
        child: const Icon(LucideIcons.plus),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.globe, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No websites yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create your first website',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _createWebsite(context, ref),
            icon: const Icon(LucideIcons.plus),
            label: const Text('Create Website'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, List<FileTag> tags) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: tags.length,
      itemBuilder: (context, index) {
        final tag = tags[index];
        return _WebsiteListTile(
          tag: tag,
          onTap: () => context.push('/websites/${tag.id}', extra: tag),
          onDelete: () => _deleteWebsite(context, ref, tag),
        );
      },
    );
  }

  Future<void> _createWebsite(BuildContext context, WidgetRef ref) async {
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Website'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Website name',
            hintText: 'My Portfolio',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (value) => Navigator.of(ctx).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == null || result.trim().isEmpty) return;

    final tag = await ref.read(websiteProvider.notifier).createWebsite(result.trim());
    if (tag != null && context.mounted) {
      context.push('/websites/${tag.id}', extra: tag);
    }
  }

  Future<void> _deleteWebsite(
      BuildContext context, WidgetRef ref, FileTag tag) async {
    final displayName = tag.name.replaceFirst('websites-', '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Website'),
        content: Text(
          'Are you sure you want to delete "$displayName"? '
          'This will remove the website and all generation history.',
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
      await ref.read(websiteProvider.notifier).deleteWebsite(tag.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "$displayName"')),
        );
      }
    }
  }
}

class _WebsiteListTile extends StatelessWidget {
  final FileTag tag;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _WebsiteListTile({
    required this.tag,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(tag.colorValue);
    final displayName = tag.name.replaceFirst('websites-', '');

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Icon(LucideIcons.globe, size: 20),
        ),
      ),
      title: Text(displayName),
      subtitle: Text(
        '${tag.fileCount} file${tag.fileCount == 1 ? '' : 's'}',
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'delete') onDelete();
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
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
