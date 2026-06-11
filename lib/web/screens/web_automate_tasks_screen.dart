import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/automate_task.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/services/automate_task_service.dart';
import 'package:fula_files/web/services/web_automate_csv_store.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

/// Mirror of lib/features/automate/screens/automate_tasks_browser_screen.dart
/// for the web shell: one Automate task per "automate-tasks-*" tag. The
/// tag syncs through the cloud tag manifest (so task names made in the
/// app show here and vice versa); the task config + recipients CSV are
/// per-browser, same as they're per-device in the app.
class WebAutomateTasksScreen extends StatefulWidget {
  const WebAutomateTasksScreen({super.key});

  @override
  State<WebAutomateTasksScreen> createState() =>
      _WebAutomateTasksScreenState();
}

class _WebAutomateTasksScreenState extends State<WebAutomateTasksScreen> {
  List<FileTag> _tags = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await WebTagService.instance.load(force: force);
      _tags = WebTagService.instance.tags
          .where((t) => t.name.startsWith('automate-tasks-'))
          .toList();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Automate'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(force: true),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load tasks.\n$_error'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _tags.isEmpty
                  ? _buildEmptyState(context)
                  : _buildList(context),
      floatingActionButton: FloatingActionButton(
        onPressed: _createTask,
        tooltip: 'New Automate task',
        child: const Icon(LucideIcons.plus),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
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
              onPressed: _createTask,
              icon: const Icon(LucideIcons.plus),
              label: const Text('New Automate task'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 80),
          itemCount: _tags.length,
          itemBuilder: (context, index) {
            final tag = _tags[index];
            return _AutomateTaskListTile(
              tag: tag,
              onTap: () => context.go('/automate-tasks/${tag.id}'),
              onDelete: () => _deleteTask(tag),
            );
          },
        ),
      ),
    );
  }

  Future<void> _createTask() async {
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
    try {
      final tag = await WebTagService.instance.createTag(
        name: 'automate-tasks-${name.trim()}',
        colorValue: TagColors.getRandomColor(),
      );
      await AutomateTaskService.instance.getOrCreate(
        tagId: tag.id,
        tagName: tag.name,
      );
      if (mounted) context.go('/automate-tasks/${tag.id}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create task: $e')),
        );
      }
    }
  }

  Future<void> _deleteTask(FileTag tag) async {
    final displayName = tag.name.replaceFirst('automate-tasks-', '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Automate task'),
        content: Text(
          'Delete "$displayName"? The recipients list stored in this '
          'browser, the message template and the send plan are removed.',
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
    if (confirmed != true) return;
    try {
      await AutomateTaskService.instance.deleteTasksForTag(tag.id);
      await WebAutomateCsvStore.instance.removeAll(tag.id);
      await WebTagService.instance.deleteTag(tag.id);
      await _load(force: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "$displayName"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }
}

/// Stateful so the subtitle re-renders when the underlying task's rows
/// change (user marks rows sent in the run screen, then comes back).
/// Same statusStream subscription as the native tile.
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
  State<_AutomateTaskListTile> createState() =>
      _AutomateTaskListTileState();
}

class _AutomateTaskListTileState extends State<_AutomateTaskListTile> {
  AutomateTask? _task;
  bool _hasCsv = false;
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
    WebAutomateCsvStore.instance.readCsv(widget.tag.id).then((csv) {
      if (mounted) setState(() => _hasCsv = csv != null);
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
    final subtitle = _subtitleFor(_task);

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

  /// Send-plan progress when one exists (same shape as the app tile);
  /// otherwise whether a recipients CSV is stored in this browser.
  String _subtitleFor(AutomateTask? task) {
    if (task == null || task.rows.isEmpty) {
      return _hasCsv ? 'Recipients attached' : 'No recipients yet';
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
