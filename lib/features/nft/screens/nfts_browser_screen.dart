import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shimmer/shimmer.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/nft/providers/nft_provider.dart';
import 'package:fula_files/features/nft/widgets/receive_nft_dialog.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Screen listing all NFT collections (tags with "nft-" prefix)
class NftsBrowserScreen extends ConsumerWidget {
  const NftsBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagState = ref.watch(tagProvider);
    final nftTags = ref.watch(nftTagsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('NFTs'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.qrCode),
            tooltip: 'Receive NFT',
            onPressed: () => showReceiveNftDialog(context),
          ),
        ],
      ),
      body: tagState.isLoading
          ? _buildShimmerList(context)
          : nftTags.isEmpty
              ? _buildEmptyState(context, ref)
              : _buildList(context, ref, nftTags),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createCollection(context, ref),
        child: const Icon(LucideIcons.plus),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.gem, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No NFT collections yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create your first NFT collection',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _createCollection(context, ref),
            icon: const Icon(LucideIcons.plus),
            label: const Text('Create Collection'),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmerList(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: 3,
        itemBuilder: (context, index) {
          return ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            title: Container(
              height: 14,
              width: 120,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            subtitle: Container(
              height: 10,
              width: 80,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, List<FileTag> tags) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: tags.length,
      itemBuilder: (context, index) {
        final tag = tags[index];
        return _NftCollectionTile(
          tag: tag,
          onTap: () => context.push('/nfts/${tag.id}', extra: tag),
          onDelete: () => _deleteCollection(context, ref, tag),
        );
      },
    );
  }

  Future<void> _createCollection(BuildContext context, WidgetRef ref) async {
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New NFT Collection'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Collection name',
            hintText: 'My NFTs',
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

    final tag = await ref.read(nftProvider.notifier).createCollection(result.trim());
    if (tag != null && context.mounted) {
      context.push('/nfts/${tag.id}', extra: tag);
    }
  }

  Future<void> _deleteCollection(
      BuildContext context, WidgetRef ref, FileTag tag) async {
    final displayName = tag.name.replaceFirst('nft-', '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Collection'),
        content: Text(
          'Are you sure you want to delete "$displayName"? '
          'This will remove the collection and all local NFT records.',
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
      await ref.read(nftProvider.notifier).deleteCollection(tag.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "$displayName"')),
        );
      }
    }
  }
}

class _NftCollectionTile extends StatelessWidget {
  final FileTag tag;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _NftCollectionTile({
    required this.tag,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(tag.colorValue);
    final displayName = tag.name.replaceFirst('nft-', '');

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Icon(LucideIcons.gem, size: 20),
        ),
      ),
      title: Text(displayName),
      subtitle: Text(
        '${tag.fileCount} asset${tag.fileCount == 1 ? '' : 's'}',
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
