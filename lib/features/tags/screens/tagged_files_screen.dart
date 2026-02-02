import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';

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
      ),
      body: taggedFilesAsync.when(
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
                onTap: () => _openFile(context, taggedFile),
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
    );
  }

  void _openFile(BuildContext context, TaggedFile taggedFile) {
    final path = taggedFile.localPath;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File location not available')),
      );
      return;
    }

    // Check if file exists
    final file = File(path);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File not found')),
      );
      return;
    }

    // Determine file type and open appropriate viewer
    final ext = path.toLowerCase().split('.').last;

    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'].contains(ext)) {
      context.push('/viewer/image', extra: path);
    } else if (['mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'].contains(ext)) {
      context.push('/viewer/video', extra: path);
    } else if (['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'].contains(ext)) {
      context.push('/viewer/audio', extra: path);
    } else if (['txt', 'md', 'json', 'xml', 'yaml', 'yml', 'log'].contains(ext)) {
      context.push('/viewer/text', extra: path);
    } else {
      // Navigate to browser with file's parent directory
      final parentDir = file.parent.path;
      context.push('/browser', extra: {'path': parentDir});
    }
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
      leading: _buildThumbnail(),
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

  Widget _buildThumbnail() {
    final path = taggedFile.localPath;
    if (path == null) {
      return _buildPlaceholderThumbnail();
    }

    final file = File(path);
    if (!file.existsSync()) {
      return _buildPlaceholderThumbnail();
    }

    try {
      final stat = file.statSync();
      final localFile = LocalFile.fromFileSystemEntity(file, stat);
      return FileThumbnail(file: localFile, size: 48);
    } catch (e) {
      return _buildPlaceholderThumbnail();
    }
  }

  Widget _buildPlaceholderThumbnail() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(LucideIcons.file, color: Colors.grey),
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
