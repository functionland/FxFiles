import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/share_token.dart' as share_model;
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_device_class.dart';
import 'package:fula_files/web/services/web_file_view_mode.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_tagged_file_resolver.dart';
import 'package:fula_files/web/services/web_view_mode_store.dart';
import 'package:fula_files/features/tags/widgets/tag_ask_ai_sheet.dart';
import 'package:fula_files/web/widgets/web_create_share_dialog.dart';
import 'package:fula_files/web/widgets/web_file_grid_tile.dart';
import 'package:fula_files/web/widgets/web_file_preview.dart';
import 'package:fula_files/web/widgets/web_tag_dialogs.dart';
import 'package:fula_files/web/widgets/web_thumb.dart';

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
  // edits); the Refresh button does an awaited live read INCLUDING a
  // server forest re-fetch (cross-device intent).
  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await WebTagService.instance
          .load(force: force, refetchForest: force);
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

  /// Tagged files joined to the cloud objects they point at, so this
  /// screen can render thumbnails and open the same internal viewers the
  /// category screens use. Files that resolve to nothing are KEPT (with
  /// an "on a device" affordance) rather than dropped.
  List<ResolvedTaggedFile> _resolved = const [];

  late WebFileViewMode _viewMode;
  String get _viewModeKey => 'tag_${widget.tagId}';

  @override
  void initState() {
    super.initState();
    _viewMode = WebViewModeStore.instance.read(_viewModeKey);
    _load();
  }

  Future<void> _load({bool force = false}) async {
    if (force && mounted) setState(() => _loading = true);
    try {
      await WebTagService.instance.load();
      if (force) WebTaggedFileResolver.instance.reset();
      final files = WebTagService.instance.filesWithTag(widget.tagId);
      final resolved = await WebTaggedFileResolver.instance.resolveAll(files);
      if (mounted) {
        setState(() {
          _resolved = resolved;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _cycleViewMode() {
    final next = nextWebFileViewMode(_viewMode);
    setState(() => _viewMode = next);
    WebViewModeStore.instance.write(_viewModeKey, next);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Every resolved audio file in this tag, so tapping one plays the
  /// tag as a queue exactly like a category screen does.
  List<FulaObject> get _audioQueue => [
        for (final r in _resolved)
          if (r.inCloud && webIsAudio(r.object!)) r.object!,
      ];

  Future<void> _open(ResolvedTaggedFile r) async {
    if (!r.inCloud) {
      _snack(r.taggedFile.remoteKey == null
          ? 'This file lives on a device — open it in the app.'
          : 'This file is no longer in your cloud vault.');
      return;
    }
    await openWebFilePreview(
      context: context,
      object: r.object!,
      // Each tagged file carries its OWN bucket: one tag legitimately
      // spans several, so a screen-wide fallback would misroute half.
      bucketOf: (o) => _bucketOf(o) ?? r.bucket!,
      base: r.bucket!,
      nameOf: (o) => _nameOf(o),
      audioQueue: _audioQueue,
    );
  }

  String? _bucketOf(FulaObject o) {
    for (final r in _resolved) {
      if (r.inCloud && identical(r.object, o)) return r.bucket;
    }
    return o.sourceBucket;
  }

  String _nameOf(FulaObject o) {
    for (final r in _resolved) {
      if (r.inCloud && identical(r.object, o)) return r.displayName;
    }
    return o.name;
  }

  Future<void> _download(ResolvedTaggedFile r) async {
    if (!r.inCloud) return;
    await downloadWebFile(
      context: context,
      object: r.object!,
      bucket: r.bucket!,
      base: r.bucket!,
      nameOf: (_) => r.displayName,
    );
  }

  /// Share sheet parity with the category screens (see
  /// WebBucketScreen._shareFile).
  Future<void> _shareFile(ResolvedTaggedFile r) async {
    if (!r.inCloud) return;
    final o = r.object!;
    final bucket = r.bucket!;
    final storageKey = o.storageKey ?? o.key;
    final ct = o.metadata?['contentType'] ?? '';
    final binding = share_model.SnapshotBinding(
      contentHash: o.etag ?? storageKey,
      size: o.size,
      modifiedAt: (o.lastModified ?? DateTime.now()).millisecondsSinceEpoch,
      storageKey: storageKey,
    );
    final result = await showWebCreateShareDialog(
      context: context,
      bucket: bucket,
      pathScope: o.key,
      storageKey: storageKey,
      fileName: r.displayName.split('/').last,
      contentType:
          ct.isNotEmpty && ct != 'application/octet-stream' ? ct : null,
      snapshotBinding: binding,
    );
    if (result != null && mounted) {
      await showWebShareCreatedDialog(context: context, result: result);
    }
  }

  Future<void> _editTags(ResolvedTaggedFile r) async {
    if (!r.inCloud) return;
    final bucket = r.bucket!;
    // Reuse the listing-oriented lookup with a single-object list rather
    // than reaching into the service's private association rows.
    final initial = (WebTagService.instance
                .tagsForObjects(bucket, [r.object!])[r.object!.key] ??
            const <FileTag>[])
        .map((t) => t.id)
        .toSet();
    final changed = await showWebTagSelectorDialog(
      context: context,
      remoteKey: '$bucket/${r.object!.key}',
      fileName: r.displayName.split('/').last,
      initialTagIds: initial,
    );
    if (changed == true) await _load(force: true);
  }

  Future<void> _deleteFile(ResolvedTaggedFile r) async {
    if (!r.inCloud) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('"${r.displayName}" will be removed from your '
            'cloud vault. This cannot be undone from the web app.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final bucket = r.bucket!;
      final key = r.object!.key;
      await WebForegroundActivity.instance
          .run(() => FulaApiService.instance.deleteObject(bucket, key));
      await WebListingCache.instance.patchListingRemove(bucket, key);
      WebCacheSync.instance.sendInvalidateListing(bucket);
      _snack('Deleted');
      await _load(force: true);
    } catch (e) {
      _snack('Delete failed: $e');
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
      // Re-resolve so the row disappears and the audio queue/indices stay
      // in step with the tag's contents.
      if (mounted) await _load();
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
          IconButton(
            tooltip: switch (_viewMode) {
              WebFileViewMode.list => 'Grid view',
              WebFileViewMode.grid2 => 'Small grid',
              WebFileViewMode.grid3 => 'List view',
            },
            icon: Icon(switch (_viewMode) {
              WebFileViewMode.list => Icons.grid_view,
              WebFileViewMode.grid2 => Icons.apps,
              WebFileViewMode.grid3 => Icons.view_list,
            }),
            onPressed: _cycleViewMode,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(force: true),
          ),
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
                  : _viewMode == WebFileViewMode.list
                      ? _buildList()
                      : _buildGrid(),
      floatingActionButton: (tag != null && files.isNotEmpty)
          ? FloatingActionButton(
              onPressed: () {
                TagAskAiSheet.show(context, tag, files);
              },
              backgroundColor: Colors.purple,
              child: const Icon(LucideIcons.bot, color: Colors.white),
            )
          : null,
    );
  }

  // ------------------------------------------------------------ rows

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _resolved.length,
      itemBuilder: (ctx, i) {
        final r = _resolved[i];
        return ListTile(
          leading: _thumbFor(r, size: 40),
          title: Text(r.displayName,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_metaLine(r), style: const TextStyle(fontSize: 12)),
          trailing: _menuFor(r),
          onTap: () => _open(r),
        );
      },
    );
  }

  Widget _buildGrid() {
    final width = MediaQuery.of(context).size.width;
    final columns = webGridColumnsFor(_viewMode, width);
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      cacheExtent: webGridCacheExtent(lowEnd: WebDeviceClass.lowEnd),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: webGridAspectRatioFor(_viewMode),
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _resolved.length,
      itemBuilder: (ctx, i) {
        final r = _resolved[i];
        return WebFileGridTile(
          thumbnail: _thumbFor(r, fill: true),
          name: r.displayName.split('/').last,
          subtitle: _metaLine(r),
          menu: _menuFor(r, dense: true),
          dense: _viewMode == WebFileViewMode.grid3,
          onTap: () => _open(r),
        );
      },
    );
  }

  /// Same lazy sidecar thumbnail the category screens use — resolving the
  /// bucket is the ONLY thing tags were ever missing.
  Widget _thumbFor(ResolvedTaggedFile r, {double size = 40, bool fill = false}) {
    final o = r.object;
    if (o == null) {
      // Unresolved: still listed, but honestly marked.
      return Icon(
        r.taggedFile.remoteKey == null
            ? Icons.smartphone
            : Icons.cloud_off_outlined,
        size: fill ? 36 : null,
      );
    }
    final icon = Icon(webIconFor(o), size: fill ? 36 : null);
    if (!webIsImage(o)) return icon;
    return WebThumb(
      bucket: r.bucket!,
      objectKey: o.key,
      size: size,
      fill: fill,
      fallback: icon,
    );
  }

  Widget _menuFor(ResolvedTaggedFile r, {bool dense = false}) {
    final cloud = r.inCloud;
    return PopupMenuButton<String>(
      tooltip: 'More',
      iconSize: dense ? 18 : 24,
      padding: dense ? EdgeInsets.zero : const EdgeInsets.all(8),
      onSelected: (v) {
        switch (v) {
          case 'open':
            _open(r);
          case 'download':
            _download(r);
          case 'tags':
            _editTags(r);
          case 'share':
            _shareFile(r);
          case 'untag':
            _removeTag(r.taggedFile);
          case 'delete':
            _deleteFile(r);
        }
      },
      itemBuilder: (ctx) => [
        if (cloud) const PopupMenuItem(value: 'open', child: Text('Open')),
        if (cloud)
          const PopupMenuItem(value: 'download', child: Text('Download')),
        if (cloud) const PopupMenuItem(value: 'tags', child: Text('Tags')),
        if (cloud)
          const PopupMenuItem(
              value: 'share', child: Text('Share Private…')),
        const PopupMenuItem(value: 'untag', child: Text('Remove tag')),
        if (cloud)
          const PopupMenuItem(value: 'delete', child: Text('Delete file')),
      ],
    );
  }

  String _metaLine(ResolvedTaggedFile r) {
    final parts = <String>[];
    final o = r.object;
    if (o != null && o.size > 0) parts.add(_fmtSize(o.size));
    parts.add(_relative(r.taggedFile.taggedAt));
    if (!r.inCloud) {
      parts.add(r.taggedFile.remoteKey == null ? 'on a device' : 'not in cloud');
    }
    return parts.join('  ·  ');
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
