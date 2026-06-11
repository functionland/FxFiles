import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/category_listing.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_save.dart';

/// Hard per-file upload cap for web v1: picked files are held fully in
/// browser memory before the encrypted upload, so bound the worst case.
const int kWebUploadCapBytes = 200 * 1024 * 1024;

/// Merged (legacy + v8) listing of one content category, with upload /
/// download / delete / preview.
class WebBucketScreen extends StatefulWidget {
  final String base; // 'images' | 'videos' | 'documents' | 'audio'
  const WebBucketScreen({super.key, required this.base});

  @override
  State<WebBucketScreen> createState() => _WebBucketScreenState();
}

class _WebBucketScreenState extends State<WebBucketScreen> {
  List<FulaObject>? _objects;
  bool _stale = false;
  String? _error;
  bool _loading = true;

  // Upload state (single in-flight batch).
  bool _uploading = false;
  String _uploadLabel = '';
  double? _uploadPct;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await listCategoryMergedCached(
        FulaApiService.instance,
        widget.base,
      );
      r.objects.sort((a, b) {
        final at = a.lastModified?.millisecondsSinceEpoch ?? 0;
        final bt = b.lastModified?.millisecondsSinceEpoch ?? 0;
        return bt.compareTo(at);
      });
      setState(() {
        _objects = r.objects;
        _stale = r.stale;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _displayName(FulaObject o) {
    final k = o.key.startsWith('/') ? o.key.substring(1) : o.key;
    return k;
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Future<void> _pickAndUpload() async {
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      allowMultiple: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    final target = BucketVersionResolver.writeBucket(widget.base);
    setState(() => _uploading = true);
    try {
      // First upload into a fresh vault/category: the bucket may not
      // exist yet. Same ensure-pattern as the native cloud services
      // (create, tolerate already-exists).
      try {
        await FulaApiService.instance.createBucket(target);
      } catch (_) {}
      for (final f in picked.files) {
        final data = f.bytes;
        if (data == null) continue;
        if (data.length > kWebUploadCapBytes) {
          _snack('"${f.name}" is larger than the 200 MB web upload limit '
              '- use the desktop or mobile app for very large files.');
          continue;
        }
        setState(() {
          _uploadLabel = f.name;
          _uploadPct = null;
        });
        final key = '/${f.name}';
        if (data.length <= 768 * 1024) {
          await FulaApiService.instance.uploadObject(target, key, data);
        } else {
          await FulaApiService.instance.uploadLargeFile(
            target,
            key,
            data,
            onProgress: (p) {
              if (mounted) setState(() => _uploadPct = p.percentage / 100);
            },
          );
        }
      }
      _snack('Upload complete');
    } catch (e) {
      _snack('Upload failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadPct = null;
          _uploadLabel = '';
        });
        await _load();
      }
    }
  }

  Future<void> _download(FulaObject o) async {
    _snack('Downloading "${_displayName(o)}"…');
    try {
      final bucket = o.sourceBucket ?? widget.base;
      final bytes = await FulaApiService.instance.downloadObject(
        bucket,
        o.key,
      );
      saveBytesAsDownload(
        _displayName(o).split('/').last,
        bytes,
        mimeType: o.metadata?['contentType']?.isNotEmpty == true
            ? o.metadata!['contentType']!
            : 'application/octet-stream',
      );
    } catch (e) {
      _snack('Download failed: $e');
    }
  }

  Future<void> _delete(FulaObject o) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('"${_displayName(o)}" will be removed from your '
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
      final bucket = o.sourceBucket ?? widget.base;
      await FulaApiService.instance.deleteObject(bucket, o.key);
      _snack('Deleted');
      await _load();
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  bool _isImage(FulaObject o) {
    final ct = o.metadata?['contentType'] ?? '';
    if (ct.startsWith('image/')) return true;
    final n = o.key.toLowerCase();
    return n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp');
  }

  bool _isText(FulaObject o) {
    final ct = o.metadata?['contentType'] ?? '';
    if (ct.startsWith('text/') || ct == 'application/json') return true;
    final n = o.key.toLowerCase();
    return n.endsWith('.txt') ||
        n.endsWith('.md') ||
        n.endsWith('.json') ||
        n.endsWith('.csv') ||
        n.endsWith('.log');
  }

  Future<void> _preview(FulaObject o) async {
    if (!_isImage(o) && !_isText(o)) {
      await _download(o);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
          child: FutureBuilder<Uint8List>(
            future: FulaApiService.instance.downloadObject(
              o.sourceBucket ?? widget.base,
              o.key,
            ),
            builder: (ctx, snap) {
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Preview failed: ${snap.error}'),
                );
              }
              if (!snap.hasData) {
                return const SizedBox(
                  width: 320,
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final bytes = snap.data!;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(
                      _displayName(o),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Download',
                          icon: const Icon(Icons.download),
                          onPressed: () => saveBytesAsDownload(
                              _displayName(o).split('/').last, bytes),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: _isImage(o)
                        ? InteractiveViewer(
                            maxScale: 8,
                            child: Image.memory(bytes, fit: BoxFit.contain),
                          )
                        : SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              utf8.decode(bytes, allowMalformed: true),
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 13),
                            ),
                          ),
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final labels = {
      'images': 'Photos',
      'videos': 'Videos',
      'documents': 'Documents',
      'audio': 'Audio',
    };
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: Text(labels[widget.base] ?? widget.base),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _pickAndUpload,
        icon: _uploading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: _uploadPct,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              )
            : const Icon(Icons.upload_file),
        label: Text(_uploading
            ? (_uploadPct != null
                ? '${(_uploadPct! * 100).toStringAsFixed(0)}%  $_uploadLabel'
                : 'Uploading $_uploadLabel')
            : 'Upload'),
      ),
      body: Column(
        children: [
          if (_stale)
            MaterialBanner(
              content: const Text(
                  'Showing cached listing — the cloud gateway could not be '
                  'reached just now.'),
              leading: const Icon(Icons.cloud_off),
              actions: [
                TextButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          if (_error != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 44),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text('Could not load this category.\n$_error',
                          textAlign: TextAlign.center),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                        onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            )
          else if (_loading)
            const Expanded(
                child: Center(child: CircularProgressIndicator()))
          else if (_objects == null || _objects!.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_open, size: 44),
                    const SizedBox(height: 8),
                    const Text('Nothing here yet'),
                    const SizedBox(height: 4),
                    Text(
                      'Use Upload to add files from this device.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: _objects!.length,
                itemBuilder: (ctx, i) {
                  final o = _objects![i];
                  return ListTile(
                    leading: Icon(_isImage(o)
                        ? Icons.image_outlined
                        : _isText(o)
                            ? Icons.article_outlined
                            : Icons.insert_drive_file_outlined),
                    title: Text(_displayName(o),
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      _fmtSize(o.size),
                      if (o.lastModified != null)
                        '${o.lastModified!.toLocal()}'.split('.').first,
                    ].join('  ·  ')),
                    onTap: () => _preview(o),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'download') _download(o);
                        if (v == 'delete') _delete(o);
                      },
                      itemBuilder: (ctx) => const [
                        PopupMenuItem(
                          value: 'download',
                          child: Text('Download'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
