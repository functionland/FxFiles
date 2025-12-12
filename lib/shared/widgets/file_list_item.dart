import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';

class FileListItem extends StatelessWidget {
  final LocalFile file;
  final SyncState? syncState;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onMorePressed;
  final bool selected;

  const FileListItem({
    super.key,
    required this.file,
    this.syncState,
    this.onTap,
    this.onLongPress,
    this.onMorePressed,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
      leading: Stack(
        children: [
          FileThumbnail(file: file, size: 48),
          if (syncState != null) _buildSyncBadge(),
        ],
      ),
      title: Text(
        file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Text(
            file.isDirectory ? 'Folder' : _formatSize(file.size),
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          if (file.modifiedAt case final modified) ...[
            Text(' • ', style: TextStyle(color: Colors.grey[600])),
            Text(
              _formatDate(modified),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (syncState != null) _buildSyncStatusIcon(),
          if (onMorePressed != null)
            IconButton(
              icon: const Icon(LucideIcons.moreVertical),
              onPressed: onMorePressed,
            ),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  Widget _buildSyncBadge() {
    if (syncState == null) return const SizedBox.shrink();
    
    Color badgeColor;
    IconData badgeIcon;
    
    switch (syncState!.status) {
      case SyncStatus.synced:
        badgeColor = Colors.green;
        badgeIcon = LucideIcons.check;
        break;
      case SyncStatus.syncing:
        badgeColor = Colors.blue;
        badgeIcon = LucideIcons.refreshCw;
        break;
      case SyncStatus.notSynced:
        badgeColor = Colors.orange;
        badgeIcon = LucideIcons.clock;
        break;
      case SyncStatus.error:
        badgeColor = Colors.red;
        badgeIcon = LucideIcons.alertCircle;
        break;
    }
    
    return Positioned(
      right: 0,
      bottom: 0,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: badgeColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Icon(badgeIcon, size: 10, color: Colors.white),
      ),
    );
  }

  Widget _buildSyncStatusIcon() {
    if (syncState == null) return const SizedBox.shrink();
    
    switch (syncState!.status) {
      case SyncStatus.synced:
        return const Icon(LucideIcons.cloud, size: 16, color: Colors.green);
      case SyncStatus.syncing:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case SyncStatus.notSynced:
        return const Icon(LucideIcons.upload, size: 16, color: Colors.orange);
      case SyncStatus.error:
        return const Icon(LucideIcons.alertCircle, size: 16, color: Colors.red);
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    
    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
