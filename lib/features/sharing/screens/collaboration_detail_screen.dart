import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/features/sharing/providers/collaboration_provider.dart';
import 'package:fula_files/features/sharing/utils/collab_folder_tree.dart';

class CollaborationDetailScreen extends ConsumerStatefulWidget {
  final String groupId;

  const CollaborationDetailScreen({super.key, required this.groupId});

  @override
  ConsumerState<CollaborationDetailScreen> createState() =>
      _CollaborationDetailScreenState();
}

class _CollaborationDetailScreenState
    extends ConsumerState<CollaborationDetailScreen> {
  bool _isRefreshing = false;
  String? _downloadingFileId;
  String _currentPath = '';
  final bool _isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    // Refresh on open to get latest files
    Future.microtask(() => _refreshGroup());
  }

  Future<void> _refreshGroup() async {
    setState(() => _isRefreshing = true);
    await ref.read(collaborationProvider.notifier).refreshGroup(widget.groupId);
    if (mounted) setState(() => _isRefreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(collaborationProvider);
    final notifier = ref.read(collaborationProvider.notifier);
    final group = notifier.getGroup(widget.groupId);
    final isOwner = notifier.isOwner(widget.groupId);

    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Collaboration')),
        body: const Center(child: Text('Group not found')),
      );
    }

    return PopScope(
      canPop: _currentPath.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _currentPath.isNotEmpty) {
          setState(() {
            final lastSlash = _currentPath.lastIndexOf('/');
            _currentPath = lastSlash >= 0 ? _currentPath.substring(0, lastSlash) : '';
          });
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(_currentPath.isEmpty ? group.name : _currentPath.split('/').last),
        actions: [
          if (isOwner)
            IconButton(
              icon: const Icon(LucideIcons.share2),
              tooltip: 'Copy Link',
              onPressed: () => _copyLink(notifier),
            ),
          IconButton(
            icon: _isRefreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw),
            tooltip: 'Refresh',
            onPressed: _isRefreshing ? null : _refreshGroup,
          ),
          PopupMenuButton<String>(
            onSelected: (value) => _handleMenuAction(value, notifier),
            itemBuilder: (context) {
              final allGroups = ref.read(collaborationProvider).allGroups;
              CollabGroupEntry? entry;
              for (final e in allGroups) {
                if (e.id == widget.groupId) { entry = e; break; }
              }
              final hasFolder = entry?.localFolderPath != null;
              final isSyncing = entry?.syncEnabled ?? false;

              return [
                if (_isDesktop) ...[
                  PopupMenuItem(
                    value: 'assign_folder',
                    child: Row(
                      children: [
                        Icon(hasFolder ? LucideIcons.folderOpen : LucideIcons.folderPlus, size: 18),
                        const SizedBox(width: 8),
                        Text(hasFolder ? 'Change Local Folder' : 'Assign Local Folder'),
                      ],
                    ),
                  ),
                  if (hasFolder)
                    PopupMenuItem(
                      value: 'unlink_folder',
                      child: Row(
                        children: [
                          Icon(LucideIcons.folderOutput, size: 18, color: Colors.orange),
                          const SizedBox(width: 8),
                          const Text('Unlink Folder', style: TextStyle(color: Colors.orange)),
                        ],
                      ),
                    ),
                  if (isSyncing)
                    const PopupMenuItem(
                      value: 'sync_now',
                      child: Row(
                        children: [
                          Icon(LucideIcons.refreshCw, size: 18),
                          SizedBox(width: 8),
                          Text('Sync Now'),
                        ],
                      ),
                    ),
                  const PopupMenuDivider(),
                ],
                if (isOwner)
                  const PopupMenuItem(
                    value: 'revoke',
                    child: Row(
                      children: [
                        Icon(LucideIcons.ban, size: 18, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Revoke Group'),
                      ],
                    ),
                  ),
              ];
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshGroup,
        child: _buildFileList(context, group, isOwner),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addFile(context),
        icon: const Icon(LucideIcons.filePlus),
        label: const Text('Add File'),
      ),
    ),
    );
  }

  Widget _buildFileList(
    BuildContext context,
    CollaborationGroup group,
    bool isOwner,
  ) {
    final theme = Theme.of(context);
    final items = collabItemsAtPath(group, _currentPath);
    final totalFiles = group.files.where((f) => f.contentType != 'application/x-directory').length;

    final headerWidgets = <Widget>[];

    // Sync status bar (desktop only)
    if (_isDesktop) {
      final allGroupsForSync = ref.watch(collaborationProvider).allGroups;
      CollabGroupEntry? entry;
      for (final e in allGroupsForSync) {
        if (e.id == widget.groupId) { entry = e; break; }
      }
      if (entry?.localFolderPath != null) {
        headerWidgets.add(
          Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.withValues(alpha: 0.15)),
            ),
            child: Row(
              children: [
                Icon(
                  entry!.syncEnabled ? LucideIcons.folderSync : LucideIcons.folderOpen,
                  size: 16,
                  color: Colors.blue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.localFolderPath!,
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (entry.syncEnabled)
                  const Text(
                    'Syncing',
                    style: TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.w500),
                  ),
              ],
            ),
          ),
        );
      }
    }

    // Breadcrumb
    if (_currentPath.isNotEmpty) {
      final segments = _currentPath.split('/');
      headerWidgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _currentPath = ''),
                child: Text('Root', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13)),
              ),
              ...List.generate(segments.length, (i) {
                final path = segments.sublist(0, i + 1).join('/');
                final isLast = i == segments.length - 1;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(' / ', style: TextStyle(color: theme.colorScheme.outline, fontSize: 13)),
                    GestureDetector(
                      onTap: isLast ? null : () => setState(() => _currentPath = path),
                      child: Text(
                        segments[i],
                        style: TextStyle(
                          color: isLast ? theme.colorScheme.onSurface : theme.colorScheme.primary,
                          fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      );
    }

    // Header row
    headerWidgets.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Icon(LucideIcons.files, size: 18, color: theme.colorScheme.outline),
            const SizedBox(width: 8),
            Text(
              '$totalFiles file${totalFiles == 1 ? '' : 's'}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const Spacer(),
            if (group.isRevoked)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Revoked',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    final totalItems = headerWidgets.length + items.folders.length + items.files.length;

    if (items.folders.isEmpty && items.files.isEmpty) {
      return ListView(
        children: [
          ...headerWidgets,
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.4,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _currentPath.isEmpty ? LucideIcons.fileQuestion : LucideIcons.folderOpen,
                    size: 64,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _currentPath.isEmpty ? 'No files yet' : 'This folder is empty',
                    style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 80),
      itemCount: totalItems,
      itemBuilder: (context, index) {
        // Header widgets
        if (index < headerWidgets.length) {
          return headerWidgets[index];
        }

        final itemIndex = index - headerWidgets.length;

        // Folder items
        if (itemIndex < items.folders.length) {
          final folderName = items.folders[itemIndex];
          final folderPath = _currentPath.isEmpty ? folderName : '$_currentPath/$folderName';
          final fileCount = collabCountFolderFiles(group, folderPath);
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
            color: theme.brightness == Brightness.dark
                ? Colors.amber.withValues(alpha: 0.1)
                : Colors.amber.shade50,
            child: ListTile(
              onTap: () => setState(() => _currentPath = folderPath),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(LucideIcons.folderOpen, color: Colors.amber, size: 20),
              ),
              title: Text(
                folderName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: Text(
                '$fileCount file${fileCount == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall,
              ),
              trailing: Icon(LucideIcons.chevronRight, size: 18, color: theme.colorScheme.outline),
            ),
          );
        }

        // File items
        final fileIndex = itemIndex - items.folders.length;
        final file = items.files[fileIndex];
        final isOwnerFile = file.addedByPublicKey == group.ownerPublicKey;
        final isDownloading = _downloadingFileId == file.id;

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          child: ListTile(
            onTap: isDownloading ? null : () => _downloadFile(file),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _getFileColor(file.contentType).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _getFileIcon(file.contentType),
                color: _getFileColor(file.contentType),
                size: 20,
              ),
            ),
            title: Text(
              file.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Row(
              children: [
                Text(
                  _formatFileSize(file.fileSize),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: isOwnerFile
                        ? Colors.blue.withValues(alpha: 0.1)
                        : Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isOwnerFile ? 'Owner' : 'Collaborator',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: isOwnerFile ? Colors.blue : Colors.green,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatDate(file.addedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                isDownloading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        LucideIcons.download,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                if (isOwner)
                  IconButton(
                    tooltip: 'Remove from group',
                    icon: Icon(LucideIcons.x,
                        size: 18, color: theme.colorScheme.outline),
                    onPressed:
                        isDownloading ? null : () => _removeFile(file),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Remove a file from the group WITHOUT deleting the underlying cloud object
  /// (`deleteFromStorage: false`) — the file stays in its category and any
  /// other shares; only its membership in this collaboration is revoked.
  Future<void> _removeFile(CollaborationFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove file?'),
        content: Text(
          '"${file.fileName}" will be removed from this group. '
          'The original file stays in your cloud storage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await ref
        .read(collaborationProvider.notifier)
        .removeFile(widget.groupId, file.id, deleteFromStorage: false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'File removed' : 'Remove failed')),
      );
    }
  }

  Future<void> _downloadFile(CollaborationFile file) async {
    if (_downloadingFileId != null) return;

    final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}/${file.fileName}';
    final localFile = File(savePath);

    // Open cached file if it already exists
    if (await localFile.exists() && await localFile.length() > 0) {
      await OpenFilex.open(savePath);
      return;
    }

    setState(() => _downloadingFileId = file.id);

    try {
      final notifier = ref.read(collaborationProvider.notifier);
      final data = await notifier.downloadFile(widget.groupId, file);
      if (data == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Download failed')),
          );
        }
        return;
      }

      await localFile.writeAsBytes(data);
      await OpenFilex.open(savePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloadingFileId = null);
    }
  }

  void _copyLink(CollaborationNotifier notifier) {
    final link = notifier.generateLink(widget.groupId);
    if (link != null) {
      Clipboard.setData(ClipboardData(text: link));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied to clipboard')),
      );
    }
  }

  void _handleMenuAction(String action, CollaborationNotifier notifier) async {
    if (action == 'revoke') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Revoke Group?'),
          content: const Text(
            'This will prevent collaborators from accessing this group. '
            'This action cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Revoke'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await notifier.revokeGroup(widget.groupId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Group revoked')),
          );
        }
      }
    } else if (action == 'assign_folder') {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select folder for collaboration sync',
      );
      if (result != null) {
        await notifier.assignFolder(widget.groupId, result);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Syncing to: $result')),
          );
        }
      }
    } else if (action == 'unlink_folder') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Unlink Folder?'),
          content: const Text(
            'This will stop syncing files to the local folder. '
            'Downloaded files will remain on disk.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Unlink'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await notifier.unassignFolder(widget.groupId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Folder unlinked')),
          );
        }
      }
    } else if (action == 'sync_now') {
      await notifier.syncNow(widget.groupId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync triggered')),
        );
      }
    }
  }

  void _addFile(BuildContext context) {
    // TODO: Open cloud file browser in selection mode
    // For now, show a placeholder dialog
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Navigate to your cloud files and share them to this group'),
      ),
    );
  }

  IconData _getFileIcon(String? contentType) {
    if (contentType == null) return LucideIcons.file;
    if (contentType.startsWith('image/')) return LucideIcons.image;
    if (contentType.startsWith('video/')) return LucideIcons.video;
    if (contentType.startsWith('audio/')) return LucideIcons.music;
    if (contentType.contains('pdf')) return LucideIcons.fileText;
    if (contentType.contains('zip') || contentType.contains('archive')) {
      return LucideIcons.fileArchive;
    }
    if (contentType.startsWith('text/')) return LucideIcons.fileText;
    return LucideIcons.file;
  }

  Color _getFileColor(String? contentType) {
    if (contentType == null) return Colors.grey;
    if (contentType.startsWith('image/')) return Colors.blue;
    if (contentType.startsWith('video/')) return Colors.purple;
    if (contentType.startsWith('audio/')) return Colors.orange;
    if (contentType.contains('pdf')) return Colors.red;
    if (contentType.startsWith('text/')) return Colors.teal;
    return Colors.grey;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDate(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.month}/${date.day}/${date.year}';
  }
}
