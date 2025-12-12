import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/services/file_service.dart';

final trashContentsProvider = FutureProvider<List<LocalFile>>((ref) async {
  return FileService.instance.getTrashContents();
});

class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trashAsync = ref.watch(trashContentsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.trash2),
            tooltip: 'Empty trash',
            onPressed: () => _showEmptyTrashDialog(context, ref),
          ),
        ],
      ),
      body: trashAsync.when(
        data: (files) {
          if (files.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.trash2, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('Trash is empty'),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(trashContentsProvider),
            child: ListView.builder(
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                return _TrashFileItem(
                  file: file,
                  onRestore: () => _restoreFile(context, ref, file),
                  onDelete: () => _deleteFile(context, ref, file),
                );
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  void _showEmptyTrashDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Empty Trash'),
        content: const Text('Are you sure you want to permanently delete all items in trash? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await FileService.instance.emptyTrash();
              ref.invalidate(trashContentsProvider);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Trash emptied')),
                );
              }
            },
            child: const Text('Empty', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreFile(BuildContext context, WidgetRef ref, LocalFile file) async {
    final originalPath = file.path.replaceFirst('.trash/', '');
    try {
      await FileService.instance.restoreFromTrash(file.path, originalPath);
      ref.invalidate(trashContentsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restored: ${file.name}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to restore: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteFile(BuildContext context, WidgetRef ref, LocalFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Permanently'),
        content: Text('Are you sure you want to permanently delete "${file.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await FileService.instance.deleteFile(file.path);
        ref.invalidate(trashContentsProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted: ${file.name}')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }
}

class _TrashFileItem extends StatelessWidget {
  final LocalFile file;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  const _TrashFileItem({
    required this.file,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        file.isDirectory ? LucideIcons.folder : _getFileIcon(),
        color: file.isDirectory ? Colors.amber : Colors.grey,
      ),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        file.isDirectory ? 'Folder' : _formatSize(file.size),
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(LucideIcons.rotateCcw),
            tooltip: 'Restore',
            onPressed: onRestore,
          ),
          IconButton(
            icon: const Icon(LucideIcons.trash2, color: Colors.red),
            tooltip: 'Delete permanently',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon() {
    final ext = file.extension.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) return LucideIcons.image;
    if (['mp4', 'mov', 'avi', 'mkv'].contains(ext)) return LucideIcons.video;
    if (['mp3', 'wav', 'aac', 'flac'].contains(ext)) return LucideIcons.music;
    if (['pdf', 'doc', 'docx', 'txt'].contains(ext)) return LucideIcons.fileText;
    if (['zip', 'rar', '7z', 'tar'].contains(ext)) return LucideIcons.archive;
    return LucideIcons.file;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
