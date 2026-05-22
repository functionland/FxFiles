import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/sync_task.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/sync_service.dart' hide SyncTask;

class SyncQueueScreen extends StatefulWidget {
  const SyncQueueScreen({super.key});

  @override
  State<SyncQueueScreen> createState() => _SyncQueueScreenState();
}

class _SyncQueueScreenState extends State<SyncQueueScreen> {
  Timer? _refreshTimer;
  List<SyncTask> _tasks = [];

  @override
  void initState() {
    super.initState();
    _loadTasks();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _loadTasks();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _loadTasks() {
    final pending = LocalStorageService.instance.getPendingSyncTasks();
    final failed = LocalStorageService.instance.getFailedSyncTasks();

    // Sort: inProgress first, then pending, then failed
    final sorted = <SyncTask>[
      ...pending.where((t) => t.status == SyncTaskStatus.inProgress),
      ...pending.where((t) => t.status == SyncTaskStatus.pending),
      ...failed,
    ];

    setState(() => _tasks = sorted);
  }

  @override
  Widget build(BuildContext context) {
    final hasFailed = _tasks.any((t) => t.isFailed);
    final hasActive = _tasks.any((t) => t.isPending || t.isInProgress);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Queue'),
        actions: [
          if (hasFailed)
            IconButton(
              icon: const Icon(LucideIcons.refreshCw),
              tooltip: 'Retry all failed',
              onPressed: _retryAllFailed,
            ),
          if (hasActive)
            IconButton(
              icon: const Icon(LucideIcons.xCircle),
              tooltip: 'Cancel all uploads',
              onPressed: _confirmCancelAll,
            ),
        ],
      ),
      body: _tasks.isEmpty ? _buildEmptyState() : _buildTaskList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.checkCircle, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No pending uploads',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'All files are synced',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList() {
    final inProgressCount = _tasks.where((t) => t.isInProgress).length;
    final pendingCount = _tasks.where((t) => t.isPending).length;
    final failedCount = _tasks.where((t) => t.isFailed).length;

    return Column(
      children: [
        // Summary bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          child: Row(
            children: [
              if (inProgressCount > 0) ...[
                _buildCountChip('Uploading', inProgressCount, Colors.blue),
                const SizedBox(width: 8),
              ],
              if (pendingCount > 0) ...[
                _buildCountChip('Pending', pendingCount, Colors.orange),
                const SizedBox(width: 8),
              ],
              if (failedCount > 0)
                _buildCountChip('Failed', failedCount, Colors.red),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: _tasks.length,
            itemBuilder: (context, index) => _buildTaskTile(_tasks[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildCountChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$count $label',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildTaskTile(SyncTask task) {
    final fileName = task.localPath.split(RegExp(r'[/\\]')).last;
    final statusColor = _statusColor(task.status);
    final statusIcon = _statusIcon(task.status);

    // Check for active upload progress
    final activeProgress = SyncService.instance.activeSync[task.localPath];
    final hasProgress = activeProgress != null && activeProgress.totalBytes > 0;
    final progressPercent = hasProgress
        ? (activeProgress.bytesTransferred / activeProgress.totalBytes * 100).round()
        : 0;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: statusColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: task.isInProgress && hasProgress
            ? Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      value: progressPercent / 100,
                      strokeWidth: 2.5,
                      color: statusColor,
                    ),
                  ),
                  Text(
                    '$progressPercent',
                    style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: statusColor),
                  ),
                ],
              )
            : Icon(statusIcon, color: statusColor, size: 20),
      ),
      title: Text(
        fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${task.remoteBucket}/${task.remoteKey}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
          if (task.isFailed && task.errorMessage != null)
            Text(
              task.errorMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.red),
            ),
          if (task.retryCount > 0)
            Text(
              'Retried ${task.retryCount} time${task.retryCount == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
        ],
      ),
      trailing: task.isFailed
          ? IconButton(
              icon: const Icon(LucideIcons.refreshCw, size: 18),
              tooltip: 'Retry',
              onPressed: () => _retryTask(task),
            )
          : (task.isPending || task.isInProgress)
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (task.isPending)
                      IconButton(
                        icon: const Icon(LucideIcons.arrowUpToLine, size: 18),
                        tooltip: 'Upload next',
                        onPressed: () => _moveToFront(task),
                      ),
                    IconButton(
                      icon: const Icon(LucideIcons.x, size: 18),
                      tooltip: task.isInProgress
                          // The in-flight upload can't be aborted today
                          // (the encrypted SDK has no cancel hook on the
                          // Flutter side — see Phase B3). Surface that
                          // honestly: queued retries are stopped, but
                          // bytes already in flight will finish in
                          // background and just be discarded.
                          ? 'Cancel queued retries (in-flight bytes will finish quietly)'
                          : 'Remove from queue',
                      onPressed: () => _cancelTask(task),
                    ),
                  ],
                )
              : null,
    );
  }

  Color _statusColor(SyncTaskStatus status) {
    switch (status) {
      case SyncTaskStatus.inProgress:
        return Colors.blue;
      case SyncTaskStatus.pending:
        return Colors.orange;
      case SyncTaskStatus.failed:
        return Colors.red;
      case SyncTaskStatus.completed:
        return Colors.green;
    }
  }

  IconData _statusIcon(SyncTaskStatus status) {
    switch (status) {
      case SyncTaskStatus.inProgress:
        return LucideIcons.upload;
      case SyncTaskStatus.pending:
        return LucideIcons.clock;
      case SyncTaskStatus.failed:
        return LucideIcons.alertCircle;
      case SyncTaskStatus.completed:
        return LucideIcons.checkCircle;
    }
  }

  void _moveToFront(SyncTask task) {
    final moved = SyncService.instance.prioritizeUpload(task.localPath);
    if (moved && mounted) {
      _loadTasks();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Moved to front of queue')),
      );
    }
  }

  Future<void> _retryTask(SyncTask task) async {
    await SyncService.instance.queueUpload(
      localPath: task.localPath,
      remoteBucket: task.remoteBucket,
      remoteKey: task.remoteKey,
      encrypt: task.encrypt,
    );
    await LocalStorageService.instance.removeSyncTask(task.id);
    _loadTasks();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Re-queued for upload')),
      );
    }
  }

  Future<void> _cancelTask(SyncTask task) async {
    await SyncService.instance.cancelTask(task.localPath);
    _loadTasks();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(task.isInProgress
              // Be honest about today's behavior: queued retries stop, but
              // the current SDK call has no cancel hook so any bytes
              // already in flight finish in the background and get
              // dropped (no synced state, no error). Phase B3 will deliver
              // true mid-chunk abort.
              ? 'Cancelled — in-flight upload will finish in background and be discarded'
              : 'Removed from queue'),
        ),
      );
    }
  }

  Future<void> _confirmCancelAll() async {
    final active = _tasks.where((t) => t.isPending || t.isInProgress).length;
    if (active == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel all uploads?'),
        content: Text(
          'This will cancel $active queued or in-progress upload${active == 1 ? '' : 's'}. '
          'Files already uploaded stay in the cloud; you can re-queue cancelled files later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep uploading'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await SyncService.instance.cancelAllUploads();
    _loadTasks();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cancelled $active upload${active == 1 ? '' : 's'}')),
      );
    }
  }

  Future<void> _retryAllFailed() async {
    final failed = _tasks.where((t) => t.isFailed).toList();
    for (final task in failed) {
      await SyncService.instance.queueUpload(
        localPath: task.localPath,
        remoteBucket: task.remoteBucket,
        remoteKey: task.remoteKey,
        encrypt: task.encrypt,
      );
      await LocalStorageService.instance.removeSyncTask(task.id);
    }
    _loadTasks();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Re-queued ${failed.length} failed uploads')),
      );
    }
  }
}
