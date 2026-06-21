import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/services/web_streaming_file.dart';
import 'package:fula_files/web/services/web_upload_manager.dart';
import 'package:fula_files/web/utils/cloud_folder_tree.dart';

/// Raw cloud file manager ("Cloud Files"). Browses the user's buckets and the
/// virtual folder tree inside each one — the same encrypted data the category
/// tabs show, but organized by bucket/folder instead of by Images/Videos/etc.
///
/// Buckets are shown RAW (every bucket the gateway returns). `listObjects`
/// returns the whole bucket flat (isDirectory always false), so the folder
/// structure is derived client-side via [deriveCloudFolderView]. Folders are
/// virtual key-prefixes; an empty one is materialized by a hidden keep-marker
/// (see [FulaApiService.createFolder] / [stripFolderMarkers]).
class WebCloudFilesScreen extends StatefulWidget {
  const WebCloudFilesScreen({super.key});

  @override
  State<WebCloudFilesScreen> createState() => _WebCloudFilesScreenState();
}

class _WebCloudFilesScreenState extends State<WebCloudFilesScreen> {
  // Navigation: bucket == null → bucket list; else → folder view at _prefix
  // (normalized: '' for the bucket root, or 'a/b/' with a trailing slash).
  String? _bucket;
  String _prefix = '';

  List<String> _buckets = const [];
  bool _bucketsStale = false;
  // The WHOLE current bucket, flat (raw — includes keep-markers, which the
  // tree derivation hides from the file view).
  List<FulaObject> _objects = const [];

  bool _loading = true;
  String? _error;

  StreamSubscription<String>? _uploadSub;

  @override
  void initState() {
    super.initState();
    // Reload the open bucket when its uploads finish.
    _uploadSub = WebUploadManager.instance.onBucketCompleted.listen((bucket) {
      if (mounted && bucket == _bucket) _loadObjects(silent: true);
    });
    _loadBuckets();
  }

  @override
  void dispose() {
    _uploadSub?.cancel();
    super.dispose();
  }

  bool get _isReadOnly =>
      _bucket != null && BucketVersionResolver.isForbiddenWriteTarget(_bucket!);

  // ── Loading ──────────────────────────────────────────────────────────────

  Future<void> _loadBuckets() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await FulaApiService.instance.listBucketsCached();
      if (!mounted) return;
      setState(() {
        _buckets = [...r.buckets]..sort();
        _bucketsStale = r.stale;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadObjects({bool silent = false}) async {
    final bucket = _bucket;
    if (bucket == null) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final objs = await WebForegroundActivity.instance
          .run(() => FulaApiService.instance.listObjects(bucket));
      if (!mounted) return;
      setState(() {
        _objects = objs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      // A brand-new / empty bucket has no forest yet — that's the empty
      // state, not an error.
      if (msg.contains('NoSuchBucket') || msg.contains('bucket not found')) {
        setState(() {
          _objects = const [];
          _loading = false;
        });
      } else {
        setState(() {
          _error = msg;
          _loading = false;
        });
      }
    }
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _openBucket(String bucket) {
    setState(() {
      _bucket = bucket;
      _prefix = '';
      _objects = const [];
    });
    _loadObjects();
  }

  void _enterFolder(String name) {
    setState(() => _prefix = '$_prefix$name/');
  }

  void _toBuckets() {
    setState(() {
      _bucket = null;
      _prefix = '';
      _objects = const [];
    });
    _loadBuckets();
  }

  void _toCrumb(int folderDepth) {
    // folderDepth 0 → bucket root; n → first n folder segments.
    final parts = _prefix.split('/').where((p) => p.isNotEmpty).toList();
    final kept = parts.take(folderDepth).toList();
    setState(() => _prefix = kept.isEmpty ? '' : '${kept.join('/')}/');
  }

  void _up() {
    if (_prefix.isEmpty) {
      _toBuckets();
    } else {
      final parts = _prefix.split('/').where((p) => p.isNotEmpty).toList()
        ..removeLast();
      setState(() => _prefix = parts.isEmpty ? '' : '${parts.join('/')}/');
    }
  }

  // ── Create / upload ─────────────────────────────────────────────────────────

  Future<void> _newBucket() async {
    final name = await _promptName(
      title: 'New bucket',
      hint: 'my-bucket',
      helper: '3–63 chars: lowercase letters, digits, "-" or "."; '
          'must not start with "-" or ".".',
      validator: _validateBucketName,
    );
    if (name == null) return;
    try {
      await FulaApiService.instance.createBucket(name);
      _snack('Bucket "$name" created');
      _openBucket(name);
    } catch (e) {
      _snack('Could not create bucket: ${_clean(e)}');
    }
  }

  Future<void> _newFolder() async {
    final name = await _promptName(
      title: 'New folder',
      hint: 'folder name',
      helper: 'Created inside the current folder.',
      validator: _validateFolderName,
    );
    if (name == null) return;
    final bucket = _bucket!;
    try {
      await FulaApiService.instance.createFolder(bucket, '$_prefix$name');
      _snack('Folder "$name" created');
      await _loadObjects();
    } catch (e) {
      _snack('Could not create folder: ${_clean(e)}');
    }
  }

  Future<void> _uploadHere() async {
    final bucket = _bucket;
    if (bucket == null) return;
    // pickFilesForUpload runs input.click() synchronously to preserve the
    // user gesture (iOS Safari), then resolves with the picked files.
    final picked = await pickFilesForUpload();
    if (picked.isEmpty || !mounted) return;
    WebUploadManager.instance.enqueue(
      base: bucket,
      bucket: bucket,
      files: picked,
      keyPrefix: _prefix,
    );
    _snack(picked.length == 1
        ? 'Uploading "${picked.first.name}"…'
        : 'Uploading ${picked.length} files…');
  }

  // ── File interactions ───────────────────────────────────────────────────────

  Future<void> _open(FulaObject o) async {
    if (o.isImage) {
      await _previewImage(o);
    } else {
      await _download(o);
    }
  }

  Future<void> _previewImage(FulaObject o) async {
    final bucket = o.sourceBucket ?? _bucket!;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
          child: FutureBuilder<Uint8List>(
            future: FulaApiService.instance.downloadObject(bucket, o.key),
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 240,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError || snap.data == null) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not open: ${_clean(snap.error)}'),
                );
              }
              return InteractiveViewer(
                child: Image.memory(snap.data!, fit: BoxFit.contain),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _download(FulaObject o) async {
    _snack('Downloading "${o.name}"…');
    try {
      final bucket = o.sourceBucket ?? _bucket!;
      final bytes = await WebForegroundActivity.instance
          .run(() => FulaApiService.instance.downloadObject(bucket, o.key));
      saveBytesAsDownload(
        o.name,
        bytes,
        mimeType: (o.metadata?['contentType']?.isNotEmpty ?? false)
            ? o.metadata!['contentType']!
            : 'application/octet-stream',
      );
    } catch (e) {
      _snack('Download failed: ${_clean(e)}');
    }
  }

  Future<void> _deleteFile(FulaObject o) async {
    if (!await _confirm('Delete file?',
        '"${o.name}" will be removed from this bucket. This cannot be undone '
            'from the web app.')) {
      return;
    }
    final bucket = o.sourceBucket ?? _bucket!;
    try {
      await WebForegroundActivity.instance
          .run(() => FulaApiService.instance.deleteObject(bucket, o.key));
      if (!mounted) return;
      setState(() =>
          _objects = [for (final x in _objects) if (x.key != o.key) x]);
      _snack('Deleted');
    } catch (e) {
      _snack('Delete failed: ${_clean(e)}');
    }
  }

  Future<void> _deleteFolder(String name) async {
    final folderPrefix = '$_prefix$name/';
    final inFolder = [
      for (final o in _objects)
        if (normalizeCloudKey(o.key).startsWith(folderPrefix)) o
    ];
    final fileCount = inFolder.where((o) => !isFolderMarker(o)).length;
    if (!await _confirm(
        'Delete folder?',
        'Delete "$name" and everything inside it'
            '${fileCount > 0 ? ' ($fileCount file${fileCount == 1 ? '' : 's'})' : ''}? '
            'This cannot be undone from the web app.')) {
      return;
    }
    final bucket = _bucket!;
    try {
      for (final o in inFolder) {
        await WebForegroundActivity.instance
            .run(() => FulaApiService.instance.deleteObject(bucket, o.key));
      }
      if (!mounted) return;
      final deleted = inFolder.map((o) => o.key).toSet();
      setState(() =>
          _objects = [for (final x in _objects) if (!deleted.contains(x.key)) x]);
      _snack('Folder deleted');
    } catch (e) {
      _snack('Delete failed: ${_clean(e)}');
      await _loadObjects(silent: true);
    }
  }

  // ── Small helpers ────────────────────────────────────────────────────────

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  String _clean(Object? e) =>
      '$e'.replaceFirst('FulaApiException: ', '').replaceFirst('Exception: ', '');

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    return ok == true;
  }

  String? _validateBucketName(String v) {
    final s = v.trim();
    if (s.length < 3 || s.length > 63) return 'Use 3–63 characters.';
    if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(s)) {
      return 'Only lowercase letters, digits, "-" and ".".';
    }
    if (s.startsWith('-') || s.startsWith('.')) return 'Cannot start with "-" or ".".';
    if (_buckets.contains(s)) return 'A bucket with this name already exists.';
    return null;
  }

  String? _validateFolderName(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'Enter a name.';
    if (s.contains('/')) return 'No "/" in a folder name.';
    if (s == kFolderMarkerName) return 'Reserved name.';
    return null;
  }

  Future<String?> _promptName({
    required String title,
    required String hint,
    required String helper,
    required String? Function(String) validator,
  }) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: hint, helperText: helper,
                helperMaxLines: 3),
            validator: (v) => validator(v ?? ''),
            onFieldSubmitted: (_) {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: _bucket == null ? 'Back' : 'Up',
          onPressed: () {
            if (_bucket == null) {
              Navigator.of(context).maybePop();
            } else {
              _up();
            }
          },
        ),
        title: const Text('Cloud Files'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.refreshCw),
            tooltip: 'Refresh',
            onPressed: _bucket == null ? _loadBuckets : () => _loadObjects(),
          ),
        ],
      ),
      floatingActionButton: _buildFab(),
      body: Column(
        children: [
          _breadcrumb(),
          if (_bucketsStale && _bucket == null)
            const _Banner(
                text:
                    'Showing a saved bucket list — the cloud was unreachable.'),
          if (_isReadOnly)
            const _Banner(
                text:
                    'This is a legacy bucket — read-only on the web app.'),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget? _buildFab() {
    if (_bucket == null) {
      return FloatingActionButton.extended(
        onPressed: _newBucket,
        icon: const Icon(LucideIcons.folderPlus),
        label: const Text('New bucket'),
      );
    }
    if (_isReadOnly) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton.small(
          heroTag: 'cf-newfolder',
          onPressed: _newFolder,
          tooltip: 'New folder',
          child: const Icon(LucideIcons.folderPlus),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.extended(
          heroTag: 'cf-upload',
          onPressed: _uploadHere,
          icon: const Icon(LucideIcons.upload),
          label: const Text('Upload'),
        ),
      ],
    );
  }

  Widget _breadcrumb() {
    final crumbs = <Widget>[];
    void add(String label, VoidCallback? onTap, {bool last = false}) {
      crumbs.add(InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Text(label,
              style: TextStyle(
                  fontWeight: last ? FontWeight.w600 : FontWeight.w400,
                  color: last
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.primary)),
        ),
      ));
    }

    final folderParts = _prefix.split('/').where((p) => p.isNotEmpty).toList();
    add('Buckets', _bucket == null ? null : _toBuckets,
        last: _bucket == null);
    if (_bucket != null) {
      crumbs.add(const Icon(Icons.chevron_right, size: 16));
      add(_bucket!, folderParts.isEmpty ? null : () => _toCrumb(0),
          last: folderParts.isEmpty);
      for (var i = 0; i < folderParts.length; i++) {
        final isLast = i == folderParts.length - 1;
        crumbs.add(const Icon(Icons.chevron_right, size: 16));
        add(folderParts[i], isLast ? null : () => _toCrumb(i + 1), last: isLast);
      }
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.5))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: crumbs),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _Centered(
        icon: LucideIcons.cloudOff,
        title: 'Could not load',
        subtitle: _clean(_error),
        action: FilledButton(
          onPressed: _bucket == null ? _loadBuckets : () => _loadObjects(),
          child: const Text('Retry'),
        ),
      );
    }
    if (_bucket == null) return _bucketList();
    return _folderView();
  }

  Widget _bucketList() {
    if (_buckets.isEmpty) {
      return const _Centered(
        icon: LucideIcons.database,
        title: 'No buckets yet',
        subtitle: 'Tap “New bucket” to create your first one.',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadBuckets,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _buckets.length,
        itemBuilder: (_, i) {
          final b = _buckets[i];
          return ListTile(
            leading: const Icon(LucideIcons.database),
            title: Text(b),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openBucket(b),
          );
        },
      ),
    );
  }

  Widget _folderView() {
    final view = deriveCloudFolderView(_objects, _prefix);
    final empty = view.folders.isEmpty && view.files.isEmpty;
    if (empty) {
      return RefreshIndicator(
        onRefresh: _loadObjects,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 160),
            _Centered(
              icon: LucideIcons.folderOpen,
              title: 'Empty',
              subtitle: 'Upload a file or create a folder.',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadObjects,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: view.folders.length + view.files.length,
        itemBuilder: (_, i) {
          if (i < view.folders.length) {
            final name = view.folders[i];
            return ListTile(
              leading: const Icon(LucideIcons.folder, color: Color(0xFF8AB4F8)),
              title: Text(name),
              onTap: () => _enterFolder(name),
              trailing: _isReadOnly
                  ? const Icon(Icons.chevron_right)
                  : PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'delete') _deleteFolder(name);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
            );
          }
          final o = view.files[i - view.folders.length];
          return ListTile(
            leading: Icon(_iconFor(o)),
            title: Text(o.name),
            subtitle: Text(o.sizeFormatted),
            onTap: () => _open(o),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'open':
                    _open(o);
                  case 'download':
                    _download(o);
                  case 'delete':
                    _deleteFile(o);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'open', child: Text('Open')),
                const PopupMenuItem(value: 'download', child: Text('Download')),
                if (!_isReadOnly)
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          );
        },
      ),
    );
  }

  IconData _iconFor(FulaObject o) {
    if (o.isImage) return LucideIcons.image;
    if (o.isVideo) return LucideIcons.video;
    if (o.isAudio) return LucideIcons.music;
    if (o.isDocument) return LucideIcons.fileText;
    return LucideIcons.file;
  }
}

class _Banner extends StatelessWidget {
  final String text;
  const _Banner({required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSecondaryContainer)),
    );
  }
}

class _Centered extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;
  const _Centered({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
