import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/ask_ai_context.dart';
import 'package:fula_files/features/sharing/widgets/create_share_dialog.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/tags/widgets/tag_ask_ai_sheet.dart';
import 'package:fula_files/shared/utils/tagged_file_utils.dart';
import 'package:fula_files/shared/widgets/tagged_file_thumbnail.dart';

/// Screen for viewing all files with a specific tag
class TaggedFilesScreen extends ConsumerWidget {
  final String tagId;
  final FileTag? tag;

  const TaggedFilesScreen({
    super.key,
    required this.tagId,
    this.tag,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taggedFilesAsync = ref.watch(taggedFilesProvider(tagId));
    final tagState = ref.watch(tagProvider);

    // Get the tag either from the passed parameter or from state
    final currentTag = tag ?? tagState.tags.where((t) => t.id == tagId).firstOrNull;
    final tagColor = currentTag != null ? Color(currentTag.colorValue) : Colors.purple;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: tagColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(currentTag?.name ?? 'Tagged Files'),
          ],
        ),
        actions: [
          if (currentTag != null)
            IconButton(
              icon: const Icon(LucideIcons.share2),
              tooltip: 'Share this tag',
              onPressed: () => _shareTag(context, currentTag),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: taggedFilesAsync.when(
              data: (taggedFiles) {
                if (taggedFiles.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(LucideIcons.fileX, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          'No files with this tag',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Files tagged with "${currentTag?.name ?? 'this tag'}" will appear here',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey[500],
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: taggedFiles.length,
                  itemBuilder: (context, index) {
                    final taggedFile = taggedFiles[index];
                    return _TaggedFileTile(
                      taggedFile: taggedFile,
                      onTap: () => openTaggedFile(context, taggedFile),
                      onRemoveTag: () => _removeTag(context, ref, taggedFile),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(LucideIcons.alertCircle, size: 48, color: Colors.red[300]),
                    const SizedBox(height: 16),
                    Text('Error: $error'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: currentTag != null
          ? taggedFilesAsync.maybeWhen(
              data: (taggedFiles) {
                if (taggedFiles.isEmpty) return null;
                return FloatingActionButton(
                  onPressed: () {
                    TagAskAiSheet.show(context, currentTag, taggedFiles);
                  },
                  backgroundColor: Colors.purple,
                  child: const Icon(LucideIcons.bot, color: Colors.white),
                );
              },
              orElse: () => null,
            )
          : null,
    );
  }

  Future<void> _removeTag(BuildContext context, WidgetRef ref, TaggedFile taggedFile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Tag'),
        content: Text('Remove tag from "${taggedFile.fileName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.untagFile(
        tagId: tagId,
        localPath: taggedFile.localPath,
        remoteKey: taggedFile.remoteKey,
        iosAssetId: taggedFile.iosAssetId,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed tag from "${taggedFile.fileName}"')),
        );
      }
    }
  }

  Future<void> _shareTag(BuildContext context, FileTag tag) async {
    final result = await showCreateTagShareDialog(
      context: context,
      tagId: tag.id,
      tagName: tag.name,
    );
    if (!context.mounted || result == null) return;
    await showShareCreatedDialog(context: context, result: result);
  }
}

class _TaggedFileTile extends StatelessWidget {
  final TaggedFile taggedFile;
  final VoidCallback onTap;
  final VoidCallback onRemoveTag;

  const _TaggedFileTile({
    required this.taggedFile,
    required this.onTap,
    required this.onRemoveTag,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: TaggedFileThumbnail(taggedFile: taggedFile),
      title: Text(
        taggedFile.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _formatDate(taggedFile.taggedAt),
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
      ),
      trailing: IconButton(
        icon: const Icon(LucideIcons.x, size: 18),
        tooltip: 'Remove tag',
        onPressed: onRemoveTag,
      ),
      onTap: onTap,
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        return 'Tagged ${diff.inMinutes}m ago';
      }
      return 'Tagged ${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return 'Tagged ${diff.inDays}d ago';
    } else {
      return 'Tagged ${date.day}/${date.month}/${date.year}';
    }
  }
}
