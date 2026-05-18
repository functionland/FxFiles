import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/automate_task.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/services/automate_task_service.dart';
import 'package:fula_files/features/automate/providers/automate_task_provider.dart';

/// Lists all Automate tasks — one per "automate-tasks-*" tag.
class AutomateTasksBrowserScreen extends ConsumerWidget {
  const AutomateTasksBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(automateTagsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Automate'),
      ),
      body: tags.isEmpty
          ? _buildEmptyState(context, ref)
          : _buildList(context, ref, tags),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createTask(context, ref),
        tooltip: 'New Automate task',
        child: const Icon(LucideIcons.plus),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.zap, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No Automate tasks yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Attach a CSV of contacts, build a message template with '
              'placeholders like {Name} or {Phone}, then send each row '
              'via WhatsApp / Telegram / SMS / Email.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _createTask(context, ref),
              icon: const Icon(LucideIcons.plus),
              label: const Text('New Automate task'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, List<FileTag> tags) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: tags.length,
      itemBuilder: (context, index) {
        final tag = tags[index];
        return _AutomateTaskListTile(
          tag: tag,
          onTap: () =>
              context.push('/automate-tasks/${tag.id}', extra: tag),
          onDelete: () => _deleteTask(context, ref, tag),
        );
      },
    );
  }

  Future<void> _createTask(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Automate task'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Task name',
            hintText: 'Customer outreach',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final tag = await ref
        .read(automateTaskProvider.notifier)
        .createTask(name.trim());
    if (tag != null && context.mounted) {
      context.push('/automate-tasks/${tag.id}', extra: tag);
    }
  }

  Future<void> _deleteTask(
      BuildContext context, WidgetRef ref, FileTag tag) async {
    final displayName = tag.name.replaceFirst('automate-tasks-', '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Automate task'),
        content: Text(
          'Delete "$displayName"? Attached files are untagged but stay '
          'on disk. The message template + send plan are removed.',
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
      await ref.read(automateTaskProvider.notifier).deleteTask(tag.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "$displayName"')),
        );
      }
    }
  }
}

/// Stateful so we can re-render the subtitle when the underlying
/// AutomateTask's rows change (e.g. user marks rows sent in the run
/// screen, then returns to the browser). Subscribes to
/// `AutomateTaskService.statusStream` for live updates.
class _AutomateTaskListTile extends StatefulWidget {
  final FileTag tag;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _AutomateTaskListTile({
    required this.tag,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_AutomateTaskListTile> createState() => _AutomateTaskListTileState();
}

class _AutomateTaskListTileState extends State<_AutomateTaskListTile> {
  AutomateTask? _task;
  StreamSubscription<AutomateTask>? _sub;

  @override
  void initState() {
    super.initState();
    _task = AutomateTaskService.instance.findByTagId(widget.tag.id);
    _sub = AutomateTaskService.instance.statusStream.listen((t) {
      if (t.tagId == widget.tag.id && mounted) {
        setState(() => _task = t);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(widget.tag.colorValue);
    final displayName =
        widget.tag.name.replaceFirst('automate-tasks-', '');
    final subtitle = _subtitleFor(widget.tag, _task);

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(child: Icon(LucideIcons.zap, size: 20)),
      ),
      title: Text(displayName),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'delete') widget.onDelete();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
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
      onTap: widget.onTap,
    );
  }

  /// Build the subtitle line. When the task has a send plan (rows is
  /// non-empty) we summarise progress — `12 sent · 5 pending of 50`.
  /// Otherwise fall back to the original file-count subtitle.
  String _subtitleFor(FileTag tag, AutomateTask? task) {
    if (task == null || task.rows.isEmpty) {
      return '${tag.fileCount} file${tag.fileCount == 1 ? '' : 's'}';
    }
    final total = task.rows.length;
    final sent =
        task.rows.where((r) => r.status == SendStatus.sent).length;
    final opened =
        task.rows.where((r) => r.status == SendStatus.opened).length;
    final pending =
        task.rows.where((r) => r.status == SendStatus.pending).length;
    final failed =
        task.rows.where((r) => r.status == SendStatus.failed).length;
    final parts = <String>[];
    if (sent > 0) parts.add('$sent sent');
    if (opened > 0) parts.add('$opened opened');
    if (pending > 0) parts.add('$pending pending');
    if (failed > 0) parts.add('$failed failed');
    return '${parts.join(' · ')} of $total';
  }
}
