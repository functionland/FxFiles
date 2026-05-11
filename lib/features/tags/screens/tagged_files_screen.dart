import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/media_service.dart';
import 'package:fula_files/features/sharing/widgets/create_share_dialog.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';
import 'package:open_filex/open_filex.dart';

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

  Future<void> _openFile(BuildContext context, TaggedFile taggedFile) async {
    final path = taggedFile.localPath;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File location not available')),
      );
      return;
    }

    // Resolve actual file path — on iOS, virtual paths (e.g. "PhotoKit/...")
    // must be resolved via the asset ID to get a real filesystem path.
    String filePath = path;
    final isVirtualPath = Platform.isIOS && !path.startsWith('/');
    if (isVirtualPath) {
      // Resolve iosAssetId: use stored value, fall back to recent files / sync states
      final iosAssetId = taggedFile.iosAssetId
          ?? _lookupIosAssetId(path);
      if (iosAssetId != null) {
        final actualFile = await MediaService.instance.getOriginalFile(iosAssetId);
        if (actualFile != null) {
          filePath = actualFile.path;
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('File no longer available in Photos library')),
            );
          }
          return;
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot locate file — try re-tagging it')),
          );
        }
        return;
      }
    } else {
      // Check if file exists on filesystem
      if (!File(filePath).existsSync()) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File not found')),
          );
        }
        return;
      }
    }

    if (!context.mounted) return;

    // Determine file type and open appropriate viewer using LocalFile
    // for consistent extension handling across the app.
    final localFile = LocalFile(
      path: filePath,
      name: filePath.split(Platform.pathSeparator).last,
      size: 0,
      modifiedAt: DateTime.now(),
      isDirectory: false,
    );

    if (localFile.isImage) {
      context.push('/viewer/image', extra: filePath);
    } else if (localFile.isVideo) {
      context.push('/viewer/video', extra: filePath);
    } else if (localFile.isAudio) {
      context.push('/viewer/audio', extra: filePath);
    } else if (localFile.isTextViewable) {
      context.push('/viewer/text', extra: filePath);
    } else {
      // No built-in viewer — open with native app selector
      final result = await OpenFilex.open(filePath);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file: ${result.message}')),
        );
      }
    }
  }

  /// Look up iosAssetId for an iOS virtual path from recent files or sync states.
  static String? _lookupIosAssetId(String virtualPath) {
    // Try recent files
    final recentFiles = LocalStorageService.instance.getRecentFiles(limit: 1000);
    for (final rf in recentFiles) {
      if (rf.path == virtualPath && rf.iosAssetId != null) {
        return rf.iosAssetId;
      }
    }
    // Try sync state
    return LocalStorageService.instance
        .getSyncStateByDisplayPath(virtualPath)?.iosAssetId;
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

    // On iOS, virtual paths (e.g. "PhotoKit/...") don't exist on the filesystem.
    // Use iosAssetId to display the thumbnail via PhotoKit.
    if (Platform.isIOS && !path.startsWith('/')) {
      final iosAssetId = taggedFile.iosAssetId
          ?? TaggedFilesScreen._lookupIosAssetId(path);
      if (iosAssetId != null) {
        final localFile = LocalFile(
          path: path,
          name: taggedFile.fileName,
          size: 0,
          modifiedAt: taggedFile.taggedAt,
          isDirectory: false,
          iosAssetId: iosAssetId,
        );
        return FileThumbnail(file: localFile, size: 48);
      }
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
