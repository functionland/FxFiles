import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/web/services/web_features.dart';

/// Mirror of lib/features/tags/screens/tags_browser_screen.dart
/// (view-only): search bar, color-dot rows with file counts, native
/// empty-state copy. Tag creation/editing stays native.
class WebTagsScreen extends StatefulWidget {
  const WebTagsScreen({super.key});

  @override
  State<WebTagsScreen> createState() => _WebTagsScreenState();
}

class _WebTagsScreenState extends State<WebTagsScreen> {
  List<FileTag>? _tags;
  List<TaggedFile> _files = const [];
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _tags = null;
      _error = null;
    });
    try {
      final r = await WebFeatures.loadTags();
      setState(() {
        _tags = r.tags;
        _files = r.files;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  int _countFor(FileTag tag) =>
      _files.where((f) => f.tagId == tag.id).length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = (_tags ?? const <FileTag>[])
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
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load tags.\n$_error'))
          : _tags == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 20),
                          hintText: 'Search tags...',
                          filled: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _tags!.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.sell_outlined, size: 64),
                                  const SizedBox(height: 12),
                                  Text('No tags yet',
                                      style: theme.textTheme.titleMedium),
                                  const SizedBox(height: 6),
                                  Text(
                                      'Create tags to organize your files '
                                      'in the FxFiles app',
                                      style: theme.textTheme.bodySmall),
                                ],
                              ),
                            )
                          : tags.isEmpty
                              ? Center(
                                  child: Text('No tags matching "$_query"'))
                              : ListView.builder(
                                  itemCount: tags.length,
                                  itemBuilder: (ctx, i) {
                                    final tag = tags[i];
                                    final color = Color(tag.colorValue);
                                    final n = _countFor(tag);
                                    return ListTile(
                                      leading: Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: color.withValues(
                                              alpha: 0.15),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Center(
                                          child: Container(
                                            width: 16,
                                            height: 16,
                                            decoration: BoxDecoration(
                                              color: color,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        ),
                                      ),
                                      title: Text(tag.name),
                                      subtitle: Text(
                                        '$n file${n == 1 ? '' : 's'}',
                                        style:
                                            const TextStyle(fontSize: 12),
                                      ),
                                      onTap: () =>
                                          context.go('/tags/${tag.id}'),
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
    );
  }
}

/// Mirror of lib/features/tags/screens/tagged_files_screen.dart
/// (view-only): color dot + tag name app bar, file rows with relative
/// "Tagged …" times. Web note: tagged-file CONTENT opening is limited
/// to items with a cloud copy; device-local tags show as info rows.
class WebTaggedFilesScreen extends StatefulWidget {
  final String tagId;
  const WebTaggedFilesScreen({super.key, required this.tagId});

  @override
  State<WebTaggedFilesScreen> createState() => _WebTaggedFilesScreenState();
}

class _WebTaggedFilesScreenState extends State<WebTaggedFilesScreen> {
  FileTag? _tag;
  List<TaggedFile> _files = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await WebFeatures.loadTags();
      setState(() {
        _tag = r.tags.where((t) => t.id == widget.tagId).firstOrNull;
        _files = r.files.where((f) => f.tagId == widget.tagId).toList()
          ..sort((a, b) => b.taggedAt.compareTo(a.taggedAt));
      });
    } catch (e) {
      setState(() => _error = '$e');
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _tag != null ? Color(_tag!.colorValue) : null;
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
            Text(_tag?.name ?? 'Tag'),
          ],
        ),
      ),
      body: _error != null
          ? Center(child: Text('Could not load tag.\n$_error'))
          : _files.isEmpty
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
                        'Files tagged with "${_tag?.name ?? ''}" will '
                        'appear here',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _files.length,
                  itemBuilder: (ctx, i) {
                    final f = _files[i];
                    final cloud =
                        f.remoteKey != null && f.remoteKey!.isNotEmpty;
                    return ListTile(
                      leading: Icon(cloud
                          ? Icons.cloud_done_outlined
                          : Icons.smartphone),
                      title: Text(f.fileName,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${_relative(f.taggedAt)}'
                        '${cloud ? '' : '  ·  on a device'}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () => ScaffoldMessenger.of(ctx).showSnackBar(
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
