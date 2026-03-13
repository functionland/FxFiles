import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/app_models.dart';
import 'package:fula_files/core/services/app_store_service.dart';
import 'package:fula_files/core/services/whatsapp_backup_service.dart';
import 'package:fula_files/features/apps/providers/app_provider.dart';
import 'package:fula_files/features/apps/widgets/password_setup_dialog.dart';
import 'package:fula_files/shared/utils/adaptive_ui.dart';

String _formatTimeAgo(DateTime dateTime) {
  final diff = DateTime.now().difference(dateTime);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
}

class WhatsAppBackupScreen extends ConsumerStatefulWidget {
  final String appId;
  const WhatsAppBackupScreen({super.key, required this.appId});

  @override
  ConsumerState<WhatsAppBackupScreen> createState() => _WhatsAppBackupScreenState();
}

class _WhatsAppBackupScreenState extends ConsumerState<WhatsAppBackupScreen> {
  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appProvider);
    final history = ref.watch(backupHistoryProvider(widget.appId));
    final activated = AppStoreService.instance.getActivatedApp(widget.appId);
    final appDef = AppStoreService.getAppDefinition(widget.appId);
    final stats = WhatsAppBackupService.instance.getStats(widget.appId);

    return Scaffold(
      appBar: AppBar(
        title: Text(appDef?.name ?? 'Backup'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Status card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.hardDrive, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('Backup Status', style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _StatRow(
                    label: 'Last backup',
                    value: stats.lastBackup != null
                        ? _formatTimeAgo(stats.lastBackup!)
                        : 'Never',
                  ),
                  _StatRow(
                    label: 'Total files backed up',
                    value: '${stats.totalFiles}',
                  ),
                  _StatRow(
                    label: 'Total size',
                    value: _formatSize(stats.totalBytes),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Back Up Now button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: appState.isBusy ? null : () => _startBackup(context, ref),
              icon: appState.isBackingUp
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(LucideIcons.upload),
              label: Text(appState.isBackingUp ? 'Backing up...' : 'Back Up Now'),
            ),
          ),

          // Progress indicator when backing up
          if (appState.isBackingUp && appState.progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: appState.progress!.fraction),
            if (appState.statusMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                appState.statusMessage!,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => ref.read(appProvider.notifier).cancelBackup(),
                child: const Text('Cancel'),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Password section
          Card(
            child: ListTile(
              leading: Icon(
                activated?.hasPassword == true ? LucideIcons.lock : LucideIcons.unlock,
                color: activated?.hasPassword == true ? Colors.green : Colors.grey,
              ),
              title: Text(activated?.hasPassword == true ? 'Password protected' : 'No password set'),
              subtitle: Text(activated?.hasPassword == true
                  ? 'Your backups are encrypted with a password'
                  : 'Add a password for extra security'),
              trailing: TextButton(
                onPressed: () => _showPasswordDialog(context, ref),
                child: Text(activated?.hasPassword == true ? 'Change' : 'Set'),
              ),
            ),
          ),

          // iOS folder section
          if (Platform.isIOS && activated != null) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(LucideIcons.folder),
                title: const Text('Backup Folder'),
                subtitle: Text(activated.iosFolderPath ?? 'Not selected'),
                trailing: TextButton(
                  onPressed: () => _changeIosFolder(ref),
                  child: const Text('Change'),
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Backup history
          if (history.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Backup History', style: Theme.of(context).textTheme.titleMedium),
            ),
            ...history.map((record) => _BackupHistoryTile(
              record: record,
              appId: widget.appId,
              onRestore: () => _showRestoreOptions(context, ref, record),
              onDelete: () => _confirmDelete(context, ref, record),
            )),
          ],

          // Delete All Backups — danger zone
          if (history.isNotEmpty || stats.totalFiles > 0) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            Text('Danger Zone', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.red)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: appState.isBusy ? null : () => _confirmDeleteAll(context, ref),
                icon: const Icon(LucideIcons.trash2, color: Colors.red),
                label: const Text('Delete All Backups'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Permanently removes all backed-up files from the cloud and resets all backup data.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _startBackup(BuildContext context, WidgetRef ref) async {
    final activated = AppStoreService.instance.getActivatedApp(widget.appId);

    // If password is set but we don't have the key cached in this session,
    // prompt once. After that, the session key is reused automatically.
    if (activated?.hasPassword == true &&
        !AppStoreService.instance.hasSessionKey(widget.appId)) {
      final password = await _promptPassword(context, 'Enter backup password');
      if (password == null) return;
      final valid = await AppStoreService.instance.verifyAppPassword(widget.appId, password);
      if (!valid) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Incorrect password')),
          );
        }
        return;
      }
      // verifyAppPassword caches the derived key in _sessionKeys
    }

    Directory? overrideDir;
    if (Platform.isIOS && activated?.iosFolderPath != null) {
      overrideDir = Directory(activated!.iosFolderPath!);
    }

    ref.read(appProvider.notifier).startBackup(
      widget.appId,
      overrideDir: overrideDir,
    );
  }

  void _showPasswordDialog(BuildContext context, WidgetRef ref) {
    showAdaptiveSheet(
      context: context,
      builder: (ctx) => PasswordSetupDialog(
        appId: widget.appId,
        onSaved: (password) {
          ref.read(appProvider.notifier).setPassword(widget.appId, password);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Future<void> _changeIosFolder(WidgetRef ref) async {
    final dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select WhatsApp export folder',
    );
    if (dirPath != null) {
      await AppStoreService.instance.updateIosFolderPath(widget.appId, dirPath);
      setState(() {});
    }
  }

  void _showRestoreOptions(BuildContext context, WidgetRef ref, BackupRecord record) {
    showAdaptiveSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Restore Options', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(LucideIcons.downloadCloud),
              title: const Text('Restore All Data'),
              subtitle: const Text('Download everything from this backup'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/apps/${widget.appId}/restore');
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(LucideIcons.filter),
              title: const Text('Restore by Category'),
              subtitle: const Text('Choose which types of data to restore'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/apps/${widget.appId}/restore', extra: {
                  'showCategoryPicker': true,
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
    final activated = AppStoreService.instance.getActivatedApp(widget.appId);

    // Step 1: Password verification (required if password is set)
    if (activated?.hasPassword == true) {
      final password = await _promptPassword(context, 'Enter password to confirm');
      if (password == null) return;
      final valid = await AppStoreService.instance.verifyAppPassword(widget.appId, password);
      if (!valid) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Incorrect password')),
          );
        }
        return;
      }
    }

    // Step 2: Final confirmation dialog
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete All Backups?'),
        content: const Text(
          'This will permanently delete ALL backed-up files from the cloud, '
          'remove all backup history, and reset the file index. '
          'Your original WhatsApp files on this device will NOT be affected.\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    ref.read(appProvider.notifier).deleteAllBackups(widget.appId);
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, BackupRecord record) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Backup?'),
        content: const Text(
          'This will permanently delete this backup and its files from the cloud. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(appProvider.notifier).deleteBackup(widget.appId, record.id);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptPassword(BuildContext context, String title) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
          Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _BackupHistoryTile extends StatelessWidget {
  final BackupRecord record;
  final String appId;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  const _BackupHistoryTile({
    required this.record,
    required this.appId,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (record.status) {
      BackupStatus.completed => Colors.green,
      BackupStatus.error => Colors.red,
      BackupStatus.cancelled => Colors.orange,
      _ => Colors.blue,
    };

    return Card(
      child: ListTile(
        leading: Icon(
          record.status == BackupStatus.completed
              ? LucideIcons.checkCircle
              : record.status == BackupStatus.error
                  ? LucideIcons.alertCircle
                  : LucideIcons.clock,
          color: statusColor,
        ),
        title: Text(
          _formatTimeAgo(record.startedAt),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        subtitle: Text(
          '${record.newFileCount} new files, ${_formatSize(record.totalSizeBytes)}',
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'restore') onRestore();
            if (value == 'delete') onDelete();
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'restore', child: Text('Restore')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
