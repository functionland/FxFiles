import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/widgets/web_create_share_dialog.dart';
import 'package:fula_files/web/widgets/web_tag_dialogs.dart';

/// Mirror of lib/features/tags/screens/tags_browser_screen.dart:
/// search bar, color rows with file counts, create-tag FAB/dialog, and
/// the per-tag Share / Edit / Delete menu (share opens the tag-mode
/// share sheet, same as the app).
class WebTagsScreen extends StatefulWidget {
  const WebTagsScreen({super.key});

  @override
  State<WebTagsScreen> createState() => _WebTagsScreenState();
}

class _WebTagsScreenState extends State<WebTagsScreen> {
  bool _loading = true;
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // SWR: the initial open serves the cached tag manifest instantly
  // (mutations write through the cache, so it's never behind our own
  // edits); the Refresh button keeps the awaited live read.
  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await WebTagService.instance.load(force: force);
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

  Future<void> _createTag() async {
    final created = await showWebCreateTagDialog(context: context);
    if (created != null && mounted) setState(() {});
  }

  Future<void> _editTag(FileTag tag) async {
    final changed = await showWebEditTagDialog(context: context, tag: tag);
    if (changed && mounted) setState(() {});
  }

  Future<void> _deleteTag(FileTag tag) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Tag'),
        content: Text(
            'Delete "${tag.name}"? Files keep their other tags; this only '
            'removes the tag and its associations.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await WebTagService.instance.deleteTag(tag.id);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _shareTag(FileTag tag) async {
    final result = await showWebCreateTagShareDialog(
      context: context,
      tagId: tag.id,
      tagName: tag.name,
    );
    if (result != null && mounted) {
      await showWebShareCreatedDialog(context: context, result: result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allTags = WebTagService.instance.tags;
    final tags = allTags
        .where((t) =>
            _query.isEmpty ||
            t.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Tags'),
        actions: [
          IconButton(
            tooltip: 'Create tag',
            icon: const Icon(LucideIcons.plus),
            onPressed: _createTag,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(force: true),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createTag,
        child: const Icon(LucideIcons.plus),
      ),
      body: _error != null
          ? Center(child: Text('Could not load tags.\n$_error'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon:
                              const Icon(LucideIcons.search, size: 20),
                          hintText: 'Search tags...',
                          filled: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: allTags.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(LucideIcons.tag, size: 64),
                                  const SizedBox(height: 12),
                                  Text('No tags yet',
                                      style: theme.textTheme.titleMedium),
                                  const SizedBox(height: 6),
                                  Text(
                                      'Create tags to organize your files',
                                      style: theme.textTheme.bodySmall),
                                  const SizedBox(height: 16),
                                  FilledButton(
                                    onPressed: _createTag,
                                    child: const Text('Create Tag'),
                                  ),
                                ],
                              ),
                            )
                          : tags.isEmpty
                              ? Center(
                                  child:
                                      Text('No tags matching "$_query"'))
                              : ListView.builder(
                                  itemCount: tags.length,
                                  itemBuilder: (ctx, i) =>
                                      _tagTile(ctx, tags[i]),
                                ),
                    ),
                  ],
                ),
    );
  }

  Widget _tagTile(BuildContext context, FileTag tag) {
    final color = Color(tag.colorValue);
    final n = tag.fileCount;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
      title: Text(tag.name),
      subtitle: Text(
        '$n file${n == 1 ? '' : 's'}',
        style: TextStyle(
            fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'share') _shareTag(tag);
          if (v == 'edit') _editTag(tag);
          if (v == 'delete') _deleteTag(tag);
        },
        itemBuilder: (ctx) => const [
          PopupMenuItem(
            value: 'share',
            child: ListTile(
              leading: Icon(LucideIcons.share2, size: 18),
              title: Text('Share'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'edit',
            child: ListTile(
              leading: Icon(LucideIcons.edit, size: 18),
              title: Text('Edit'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading:
                  Icon(LucideIcons.trash2, size: 18, color: AppColors.error),
              title:
                  Text('Delete', style: TextStyle(color: AppColors.error)),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        ],
      ),
      onTap: () => context.go('/tags/${tag.id}'),
    );
  }
}

/// Mirror of lib/features/tags/screens/tagged_files_screen.dart: color
/// dot + tag name app bar with a Share action, file rows with relative
/// "Tagged …" times and a remove (X) affordance.
class WebTaggedFilesScreen extends StatefulWidget {
  final String tagId;
  const WebTaggedFilesScreen({super.key, required this.tagId});

  @override
  State<WebTaggedFilesScreen> createState() => _WebTaggedFilesScreenState();
}

class _WebTaggedFilesScreenState extends State<WebTaggedFilesScreen> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await WebTagService.instance.load();
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

  String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return 'Tagged ${d.inMinutes}m ago';
    if (d.inHours < 24) return 'Tagged ${d.inHours}h ago';
    if (d.inDays < 30) return 'Tagged ${d.inDays}d ago';
    return 'Tagged ${t.day.toString().padLeft(2, '0')}/'
        '${t.month.toString().padLeft(2, '0')}/${t.year}';
  }

  Future<void> _shareTag(FileTag tag) async {
    final result = await showWebCreateTagShareDialog(
      context: context,
      tagId: tag.id,
      tagName: tag.name,
    );
    if (result != null && mounted) {
      await showWebShareCreatedDialog(context: context, result: result);
    }
  }

  Future<void> _removeTag(TaggedFile f) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Tag'),
        content: Text('Remove tag from "${f.fileName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await WebTagService.instance.removeTaggedFile(f.id);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Remove failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tag = WebTagService.instance.tagById(widget.tagId);
    final files = WebTagService.instance.filesWithTag(widget.tagId);
    final color = tag != null ? Color(tag.colorValue) : null;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/tags'),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: 12,
                height: 12,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
            ],
            Text(tag?.name ?? 'Tag'),
          ],
        ),
        actions: [
          if (tag != null)
            IconButton(
              tooltip: 'Share tag',
              icon: const Icon(LucideIcons.share2),
              onPressed: () => _shareTag(tag),
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load tag.\n$_error'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : files.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.find_in_page_outlined, size: 64),
                          const SizedBox(height: 12),
                          Text('No files with this tag',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: 6),
                          Text(
                            'Files tagged with "${tag?.name ?? ''}" will '
                            'appear here',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: files.length,
                      itemBuilder: (ctx, i) {
                        final f = files[i];
                        final cloud =
                            f.remoteKey != null && f.remoteKey!.isNotEmpty;
                        return ListTile(
                          leading: Icon(cloud
                              ? Icons.cloud_done_outlined
                              : Icons.smartphone),
                          title: Text(f.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${_relative(f.taggedAt)}'
                            '${cloud ? '' : '  ·  on a device'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove tag',
                            icon: const Icon(LucideIcons.x, size: 18),
                            onPressed: () => _removeTag(f),
                          ),
                          onTap: () =>
                              ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(cloud
                                  ? 'Find "${f.fileName}" in its category to open it.'
                                  : 'This file lives on a device — open it in the app.'),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
