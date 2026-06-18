import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/web/services/web_upload_manager.dart';

/// Web Sync Queue — lists the upload queue (the app-level [WebUploadManager])
/// and lets the user cancel an upload or prioritize a queued one, mirroring the
/// mobile sync-queue screen. Uploads run one-by-one; cancel aborts the
/// in-flight one (0.6.14) or drops a queued one, and "Upload next" moves a
/// queued file to the front.
class WebSyncQueueScreen extends StatelessWidget {
  const WebSyncQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mgr = WebUploadManager.instance;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
        title: const Text('Sync Queue'),
        actions: [
          AnimatedBuilder(
            animation: mgr,
            builder: (context, _) {
              final hasFinished = mgr.jobs.any((j) => !j.isActive);
              return TextButton(
                onPressed: hasFinished ? mgr.clearFinished : null,
                child: const Text('Clear finished'),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: AnimatedBuilder(
            animation: mgr,
            builder: (context, _) {
              final jobs = mgr.jobs;
              if (jobs.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No uploads in the queue.'),
                  ),
                );
              }
              return ListView.separated(
                itemCount: jobs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) =>
                    _JobTile(job: jobs[i], mgr: mgr),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  final WebUploadJob job;
  final WebUploadManager mgr;
  const _JobTile({required this.job, required this.mgr});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget leading;
    final String statusText;
    switch (job.status) {
      case WebUploadStatus.uploading:
        final p = job.progress;
        leading = SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5, value: p),
        );
        statusText =
            p != null ? 'Uploading ${(p * 100).round()}%' : 'Uploading…';
        break;
      case WebUploadStatus.queued:
        leading = const Icon(Icons.schedule);
        statusText = 'Queued';
        break;
      case WebUploadStatus.done:
        leading = Icon(Icons.check_circle, color: Colors.green.shade600);
        statusText = 'Uploaded';
        break;
      case WebUploadStatus.failed:
        leading = Icon(Icons.error_outline, color: theme.colorScheme.error);
        statusText = job.error ?? 'Failed';
        break;
      case WebUploadStatus.skipped:
        leading = Icon(Icons.block, color: theme.colorScheme.error);
        statusText = job.error ?? 'Skipped';
        break;
      case WebUploadStatus.cancelled:
        leading = const Icon(Icons.cancel_outlined);
        statusText = 'Cancelled';
        break;
    }
    return ListTile(
      leading: leading,
      title: Text(job.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$statusText · ${_fmtSize(job.size)}',
          maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: _actions(),
    );
  }

  Widget? _actions() {
    final actions = <Widget>[];
    if (job.status == WebUploadStatus.queued) {
      actions.add(IconButton(
        tooltip: 'Upload next',
        icon: const Icon(Icons.vertical_align_top),
        onPressed: () => mgr.moveJobToFront(job.id),
      ));
    }
    if (job.isActive) {
      actions.add(IconButton(
        tooltip: 'Cancel',
        icon: const Icon(Icons.close),
        onPressed: () => mgr.cancelJob(job.id),
      ));
    }
    if (actions.isEmpty) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: actions);
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
