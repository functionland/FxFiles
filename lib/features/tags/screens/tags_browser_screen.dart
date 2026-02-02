import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/tags/widgets/create_tag_dialog.dart';
import 'package:fula_files/features/tags/widgets/edit_tag_dialog.dart';

/// Screen for browsing all tags
class TagsBrowserScreen extends ConsumerWidget {
  const TagsBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagState = ref.watch(tagProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tags'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.plus),
            tooltip: 'Create tag',
            onPressed: () => _createTag(context),
          ),
        ],
      ),
      body: _buildBody(context, ref, tagState),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createTag(context),
        child: const Icon(LucideIcons.plus),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, TagState tagState) {
    if (tagState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (tagState.error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.alertCircle, size: 48, color: Colors.red[300]),
            const SizedBox(height: 16),
            Text('Error: ${tagState.error}'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => ref.read(tagProvider.notifier).refresh(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (tagState.tags.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.tags, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No tags yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Create tags to organize your files',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[500],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _createTag(context),
              icon: const Icon(LucideIcons.plus),
              label: const Text('Create Tag'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(tagProvider.notifier).refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: tagState.tags.length,
        itemBuilder: (context, index) {
          final tag = tagState.tags[index];
          return _TagListTile(
            tag: tag,
            onTap: () => context.push('/tags/${tag.id}', extra: tag),
            onEdit: () => _editTag(context, tag),
            onDelete: () => _deleteTag(context, ref, tag),
          );
        },
      ),
    );
  }

  Future<void> _createTag(BuildContext context) async {
    await showCreateTagDialog(context);
  }

  Future<void> _editTag(BuildContext context, FileTag tag) async {
    await showEditTagDialog(context, tag: tag);
  }

  Future<void> _deleteTag(BuildContext context, WidgetRef ref, FileTag tag) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Tag'),
        content: Text(
          'Are you sure you want to delete "${tag.name}"? '
          'This will remove the tag from all ${tag.fileCount} file(s).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(tagProvider.notifier).deleteTag(tag.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted tag "${tag.name}"')),
        );
      }
    }
  }
}

class _TagListTile extends StatelessWidget {
  final FileTag tag;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TagListTile({
    required this.tag,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(tag.colorValue);

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
      title: Text(tag.name),
      subtitle: Text(
        '${tag.fileCount} file${tag.fileCount == 1 ? '' : 's'}',
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'edit':
              onEdit();
              break;
            case 'delete':
              onDelete();
              break;
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'edit',
            child: Row(
              children: [
                Icon(LucideIcons.edit, size: 18),
                SizedBox(width: 8),
                Text('Edit'),
              ],
            ),
          ),
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
