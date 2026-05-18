import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/automate_task.dart';
import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/services/automate_task_service.dart';
import 'package:fula_files/core/utils/target_uri_builder.dart';

/// Per-row send screen. Walks the user through the SendPlanRow list:
/// tap "Open" → app launches the target app pre-filled → tap Send
/// inside that app → return → tap "Mark sent" (or "Skip").
///
/// **Why a ConsumerStatefulWidget and not a plain ConsumerWidget +
/// StreamProvider:** The natural Riverpod pattern would be to watch
/// `automateTaskForTagProvider(tagId)` and rebuild on each emission.
/// But our `save()` mutates the `AutomateTask` in place — the stream
/// emits the SAME object reference each time. Riverpod's AsyncValue
/// uses `==` to detect "did the value change?" — and for the same
/// reference it returns true, so the rebuild is silently deduped.
/// Result: tap "Mark sent" → save runs → status mutates → stream
/// emits → Riverpod sees no change → UI stays on the old status.
///
/// We sidestep that by managing the task as local state and calling
/// `setState({})` explicitly after every mutation. We still subscribe
/// to `AutomateTaskService.statusStream` so changes made elsewhere
/// (e.g. someone re-running the task from a different screen) propagate.
class AutomateTaskRunScreen extends ConsumerStatefulWidget {
  final String tagId;
  const AutomateTaskRunScreen({super.key, required this.tagId});

  @override
  ConsumerState<AutomateTaskRunScreen> createState() =>
      _AutomateTaskRunScreenState();
}

class _AutomateTaskRunScreenState
    extends ConsumerState<AutomateTaskRunScreen> {
  AutomateTask? _task;
  StreamSubscription<AutomateTask>? _sub;

  @override
  void initState() {
    super.initState();
    _task = AutomateTaskService.instance.findByTagId(widget.tagId);
    _sub = AutomateTaskService.instance.statusStream.listen((t) {
      if (t.tagId == widget.tagId && mounted) {
        // Same reference or different — doesn't matter; setState always
        // rebuilds. Captures external mutations too (e.g. another
        // screen marking the task done).
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
    final task = _task;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send plan'),
        actions: [
          IconButton(
            tooltip: 'Mark all opened as sent',
            icon: const Icon(LucideIcons.checkCheck),
            onPressed: task == null ? null : () => _markAllOpenedAsSent(task),
          ),
        ],
      ),
      body: _buildBody(task),
    );
  }

  Widget _buildBody(AutomateTask? task) {
    if (task == null) {
      return const Center(child: Text('Task not found'));
    }
    if (task.rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No send plan yet. Go back and tap "Run task" to generate one.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      children: [
        _Summary(task: task),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: task.rows.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, indent: 64),
            itemBuilder: (_, i) {
              final row = task.rows[i];
              return _RowTile(
                row: row,
                target: task.targetApp,
                onOpen: () => _openRow(task, i),
                onMarkSent: () => _setStatus(task, i, SendStatus.sent),
                onSkip: () => _setStatus(task, i, SendStatus.skipped),
                onEdit: () => _editMessage(task, i),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openRow(AutomateTask task, int index) async {
    final row = task.rows[index];
    final result = TargetUriBuilder.build(
      target: task.targetApp,
      recipient: row.recipient,
      message: row.message,
      subject: task.subjectTemplate, // honored only by email target
    );
    if (result.uri == null) {
      row.status = SendStatus.failed;
      row.failureReason = result.failureReason ?? 'Could not build URI';
      await AutomateTaskService.instance.save(task);
      if (mounted) {
        setState(() {}); // belt-and-braces — stream listener will also fire
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(row.failureReason ?? 'Send URI invalid')),
        );
      }
      return;
    }
    bool launched;
    try {
      launched = await launchUrl(result.uri!,
          mode: LaunchMode.externalApplication);
    } catch (e) {
      launched = false;
    }
    if (!launched) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the target app for this row.'),
          ),
        );
      }
      return;
    }
    row.status = SendStatus.opened;
    row.openedAt = DateTime.now();
    await AutomateTaskService.instance.save(task);
    if (mounted) setState(() {});
  }

  Future<void> _setStatus(
      AutomateTask task, int index, SendStatus status) async {
    task.rows[index].status = status;
    await AutomateTaskService.instance.save(task);
    if (mounted) setState(() {});
  }

  Future<void> _markAllOpenedAsSent(AutomateTask task) async {
    var changed = 0;
    for (final r in task.rows) {
      if (r.status == SendStatus.opened) {
        r.status = SendStatus.sent;
        changed++;
      }
    }
    if (changed > 0) {
      await AutomateTaskService.instance.save(task);
      if (mounted) setState(() {});
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Marked $changed row(s) as sent')),
      );
    }
  }

  Future<void> _editMessage(AutomateTask task, int index) async {
    final ctrl = TextEditingController(text: task.rows[index].message);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          minLines: 3,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated == null) return;
    task.rows[index].message = updated;
    await AutomateTaskService.instance.save(task);
    if (mounted) setState(() {});
  }
}

class _Summary extends StatelessWidget {
  final AutomateTask task;
  const _Summary({required this.task});

  @override
  Widget build(BuildContext context) {
    final counts = <SendStatus, int>{};
    for (final r in task.rows) {
      counts[r.status] = (counts[r.status] ?? 0) + 1;
    }
    Widget chip(SendStatus s, String label, Color color) {
      final c = counts[s] ?? 0;
      if (c == 0) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$label: $c',
            style: TextStyle(color: color, fontSize: 12)),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Icon(LucideIcons.users, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 6),
          Text(
            '${task.rows.length} recipient${task.rows.length == 1 ? '' : 's'} '
            'via ${TargetUriBuilder.label(task.targetApp)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  chip(SendStatus.pending, 'pending', Colors.blue),
                  chip(SendStatus.opened, 'opened', Colors.orange),
                  chip(SendStatus.sent, 'sent', Colors.green),
                  chip(SendStatus.skipped, 'skipped', Colors.grey),
                  chip(SendStatus.failed, 'failed', Colors.red),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RowTile extends StatelessWidget {
  final SendPlanRow row;
  final TargetApp target;
  final VoidCallback onOpen;
  final VoidCallback onMarkSent;
  final VoidCallback onSkip;
  final VoidCallback onEdit;

  const _RowTile({
    required this.row,
    required this.target,
    required this.onOpen,
    required this.onMarkSent,
    required this.onSkip,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFailed = row.status == SendStatus.failed;
    final isDone =
        row.status == SendStatus.sent || row.status == SendStatus.skipped;
    final isOpened = row.status == SendStatus.opened;

    return InkWell(
      onTap: isDone || isFailed ? null : onOpen,
      onLongPress: () => _showMenu(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusDot(status: row.status),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.displayName == null || row.displayName!.isEmpty
                        ? row.recipient
                        : '${row.displayName}  ·  ${row.recipient}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    row.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isFailed && row.failureReason != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        row.failureReason!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            _ActionButton(
              isOpened: isOpened,
              isDone: isDone,
              isFailed: isFailed,
              onOpen: onOpen,
              onMarkSent: onMarkSent,
            ),
            IconButton(
              icon: const Icon(LucideIcons.moreVertical, size: 18),
              tooltip: 'More',
              onPressed: () => _showMenu(context),
            ),
          ],
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(LucideIcons.send),
              title: const Text('Mark sent'),
              onTap: () {
                Navigator.pop(ctx);
                onMarkSent();
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.x),
              title: const Text('Skip'),
              onTap: () {
                Navigator.pop(ctx);
                onSkip();
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: const Text('Edit message'),
              onTap: () {
                Navigator.pop(ctx);
                onEdit();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final SendStatus status;
  const _StatusDot({required this.status});
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      SendStatus.pending => Colors.blue,
      SendStatus.opened => Colors.orange,
      SendStatus.sent => Colors.green,
      SendStatus.skipped => Colors.grey,
      SendStatus.failed => Colors.red,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final bool isOpened;
  final bool isDone;
  final bool isFailed;
  final VoidCallback onOpen;
  final VoidCallback onMarkSent;
  const _ActionButton({
    required this.isOpened,
    required this.isDone,
    required this.isFailed,
    required this.onOpen,
    required this.onMarkSent,
  });

  @override
  Widget build(BuildContext context) {
    if (isDone) return const SizedBox(width: 64);
    if (isFailed) return const SizedBox(width: 64);
    if (isOpened) {
      return TextButton(
        onPressed: onMarkSent,
        child: const Text('Mark sent'),
      );
    }
    return TextButton.icon(
      onPressed: onOpen,
      icon: const Icon(LucideIcons.send, size: 14),
      label: const Text('Open'),
    );
  }
}
