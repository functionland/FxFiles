import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/share_token.dart' as share_model;
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_public_service.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/services/web_share_service.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/widgets/media_preview_dialog.dart';
import 'package:fula_files/web/widgets/web_create_share_dialog.dart';
import 'package:fula_files/web/widgets/web_tag_dialogs.dart';

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

  /// When the rendered listing came from the SWR cache: its fetch time
  /// (drives the "Synced X min ago" line past 15 minutes).
  DateTime? _fetchedAt;

  /// objectKey → tags, refreshed after each listing (native parity:
  /// file rows show compact tag chips).
  Map<String, List<FileTag>> _fileTags = const {};

  // Upload state (single in-flight batch).
  bool _uploading = false;
  String _uploadLabel = '';
  double? _uploadPct;

  @override
  void initState() {
    super.initState();
    // Connection-regain → silent forced revalidate (plan §5.3).
    WebListingSwr.instance.ensureOnlineHook();
    WebListingSwr.instance.addListener(_onOnline);
    _load();
  }

  @override
  void dispose() {
    WebListingSwr.instance.removeListener(_onOnline);
    super.dispose();
  }

  void _onOnline() {
    if (mounted && !_loading) _load(force: true, silent: true);
  }

  /// Manual Refresh = the user asking for OTHER devices' writes. The
  /// wasm client pins each forest for its lifetime, so a plain re-list
  /// would re-serve this session's stale forest; rebuild the client
  /// first (interim until fula_client 0.6.8 exposes per-bucket forest
  /// invalidation), then force-list.
  Future<void> _refreshHard() async {
    await WebListingSwr.instance.hardRefreshSession();
    if (mounted) await _load(force: true);
  }

  /// Web lists ONLY the category's -v8 bucket (owner decision,
  /// 2026-06-11): the legacy buckets carry the gc-damaged forest whose
  /// repair paths (404 forest-walk, forest backups) are native-only —
  /// touching them from wasm produces 404 floods, 410 write-guard hits
  /// and corrupt legacy reads. The fresh v8 sibling is the write target
  /// for every platform and is fully healthy. Pre-migration files stay
  /// reachable from the mobile/desktop apps.
  /// SWR load (plan §5.2): cached render lands immediately when the
  /// cache has this bucket; the live fetch then patches the view in
  /// place. force = mutation/Refresh semantics — awaited live listing,
  /// exactly the pre-SWR behavior (plus the cache update). silent =
  /// no spinner (connection-regain revalidate).
  Future<void> _load({bool force = false, bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final bucket = BucketVersionResolver.writeBucket(widget.base);
    try {
      // Foreground-wrapped: the prefetcher must yield while a screen
      // the user is looking at loads or patches in.
      final r = await WebForegroundActivity.instance
          .run(() => WebListingSwr.instance.getListing(bucket, force: force));
      _applyListing(
        bucket,
        r.objects,
        stale: r.offlineStale || r.staleTier,
        fetchedAt: r.fetchedAt,
      );
      final reval = r.revalidation;
      if (reval != null) {
        WebForegroundActivity.instance.run(() => reval).then((fresh) {
          if (fresh == null || !mounted) return;
          _applyListing(
            bucket,
            fresh.objects,
            stale: fresh.offlineStale,
            fetchedAt: DateTime.now(),
          );
        });
      }
    } catch (e) {
      // A category nobody has uploaded to yet has no -v8 bucket at all:
      // that's the empty state, not an error.
      final msg = '$e';
      if (msg.contains('NoSuchBucket') || msg.contains('bucket not found')) {
        setState(() {
          _objects = const [];
          _stale = false;
          _loading = false;
          _fetchedAt = null;
        });
        return;
      }
      setState(() {
        _error = msg;
        _loading = false;
      });
    }
  }

  void _applyListing(
    String bucket,
    List<FulaObject> raw, {
    required bool stale,
    DateTime? fetchedAt,
  }) {
    final objects = raw.map((o) => o.withSourceBucket(bucket)).toList()
      ..sort((a, b) {
        final at = a.lastModified?.millisecondsSinceEpoch ?? 0;
        final bt = b.lastModified?.millisecondsSinceEpoch ?? 0;
        return bt.compareTo(at);
      });
    if (!mounted) return;
    setState(() {
      _objects = objects;
      _stale = stale;
      _loading = false;
      _fetchedAt = fetchedAt;
    });
    _refreshTags(bucket, objects);
  }

  /// Best-effort tag chip data — never blocks or fails the listing.
  Future<void> _refreshTags(String bucket, List<FulaObject> objects) async {
    try {
      await WebTagService.instance.load();
      final tags = WebTagService.instance.tagsForObjects(bucket, objects);
      if (mounted) setState(() => _fileTags = tags);
    } catch (e) {
      debugPrint('WebBucketScreen: tag load skipped: $e');
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

  /// Category → picker filter, so the Audio category can't pick images
  /// etc. Documents/Downloads stay open (catch-all categories);
  /// Archives restricts to the native archive extension set.
  FileType get _pickerType => switch (widget.base) {
        'images' => FileType.image,
        'videos' => FileType.video,
        'audio' => FileType.audio,
        'archives' => FileType.custom,
        _ => FileType.any,
      };

  List<String>? get _pickerExtensions => widget.base == 'archives'
      ? const ['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso']
      : null;

  Future<void> _pickAndUpload() async {
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      allowMultiple: true,
      type: _pickerType,
      allowedExtensions: _pickerExtensions,
    );
    if (picked == null || picked.files.isEmpty) return;

    final target = BucketVersionResolver.writeBucket(widget.base);
    setState(() => _uploading = true);
    WebForegroundActivity.instance.begin();
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
      // Other tabs drop their cached copy of this bucket; our own
      // forced reload below refreshes this tab + the cache.
      WebCacheSync.instance.sendInvalidateListing(target);
    } catch (e) {
      _snack('Upload failed: $e');
    } finally {
      WebForegroundActivity.instance.end();
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadPct = null;
          _uploadLabel = '';
        });
        await _load(force: true);
      }
    }
  }

  Future<void> _download(FulaObject o) async {
    _snack('Downloading "${_displayName(o)}"…');
    try {
      final bucket = o.sourceBucket ?? widget.base;
      final bytes = await WebForegroundActivity.instance.run(
        () => FulaApiService.instance.downloadObject(bucket, o.key),
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
      await WebForegroundActivity.instance
          .run(() => FulaApiService.instance.deleteObject(bucket, o.key));
      // Write-through: the cached listing drops the row instantly
      // (preserving its stamp so the forced reload below still wins),
      // and other tabs revalidate on their next view.
      await WebListingCache.instance.patchListingRemove(bucket, o.key);
      WebCacheSync.instance.sendInvalidateListing(bucket);
      _snack('Deleted');
      await _load(force: true);
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  String? _contentTypeOf(FulaObject o) {
    final ct = o.metadata?['contentType'] ?? '';
    if (ct.isNotEmpty && ct != 'application/octet-stream') return ct;
    return null;
  }

  /// Share a single file via the app's share sheet (mirrored in
  /// web_create_share_dialog.dart): Specific Person / Protected link /
  /// Anyone with the link, latest-vs-snapshot mode and expiry. The
  /// created share is recorded in the cloud shares manifest, so it
  /// shows up in the native app's Sharing tab and can be revoked there.
  Future<void> _shareFile(FulaObject o, {WebShareChoice? lockedChoice}) async {
    final bucket =
        o.sourceBucket ?? BucketVersionResolver.writeBucket(widget.base);
    final storageKey = o.storageKey ?? o.key;
    final fileName = _displayName(o).split('/').last;

    // Web files are cloud objects, so the snapshot metadata comes from
    // the listing (native derives it from local sync state instead).
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
      fileName: fileName,
      contentType: _contentTypeOf(o),
      snapshotBinding: binding,
      lockedChoice: lockedChoice,
    );
    if (result != null && mounted) {
      await showWebShareCreatedDialog(context: context, result: result);
    }
  }

  /// Tag selector for one file (native tag_selector_dialog parity).
  /// remoteKey uses the same `bucket/objectKey` form the native cloud
  /// explorer looks up, so tags round-trip between platforms.
  Future<void> _editTags(FulaObject o) async {
    final bucket =
        o.sourceBucket ?? BucketVersionResolver.writeBucket(widget.base);
    try {
      await WebTagService.instance.load();
    } catch (e) {
      _snack('Could not load tags: $e');
      return;
    }
    if (!mounted) return;
    final initial =
        (_fileTags[o.key] ?? const <FileTag>[]).map((t) => t.id).toSet();
    final changed = await showWebTagSelectorDialog(
      context: context,
      remoteKey: '$bucket/${o.key}',
      fileName: _displayName(o).split('/').last,
      initialTagIds: initial,
    );
    if (changed && mounted && _objects != null) {
      await _refreshTags(bucket, _objects!);
    }
  }

  /// Mirror of the app's Share Publicly flow (_sharePubliclyViaIpfs):
  /// explicit consent dialog, then download+decrypt the object and pin
  /// the plaintext to IPFS, then the public gateway link dialog.
  Future<void> _sharePublicly(FulaObject o) async {
    final fileName = _displayName(o).split('/').last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Share Publicly?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This will upload the file to IPFS without any encryption. '
              'Anyone with the link will be able to access it.',
            ),
            const SizedBox(height: 16),
            Text('File: $fileName',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Size: ${_fmtSize(o.size)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Share Publicly'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _snack('Uploading $fileName to IPFS...');
    try {
      final bucket =
          o.sourceBucket ?? BucketVersionResolver.writeBucket(widget.base);
      final bytes =
          await FulaApiService.instance.downloadObject(bucket, o.key);
      final result = await IpfsPublicService.instance.pinBytes(
        bytes,
        fileName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      await _showPublicIpfsLinkDialog(result.gatewayUrl, fileName);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      final msg =
          e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';
      _snack(msg);
    }
  }

  /// Mirror of the app's Add to Collaboration flow: pick one of the
  /// user's owned groups, then add this cloud file to it.
  Future<void> _addToCollaboration(FulaObject o) async {
    final List<OutgoingCollaboration> ownedGroups;
    try {
      final all =
          await CollaborationService.instance.getOutgoingCollaborations();
      ownedGroups = all.where((g) => g.isValid).toList();
    } catch (e) {
      _snack('Could not load collaboration groups: $e');
      return;
    }
    if (!mounted) return;
    if (ownedGroups.isEmpty) {
      _snack('No active collaboration groups. Create one from the '
          'Shared tab first.');
      return;
    }

    final selected = await showDialog<OutgoingCollaboration>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add to Collaboration Group'),
        children: ownedGroups
            .map((g) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, g),
                  child: ListTile(
                    leading:
                        const Icon(Icons.group_outlined, color: Colors.purple),
                    title: Text(g.name),
                    subtitle: Text(
                        '${g.group.fileCount} file${g.group.fileCount == 1 ? '' : 's'}'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ))
            .toList(),
      ),
    );
    if (selected == null || !mounted) return;

    final bucket =
        o.sourceBucket ?? BucketVersionResolver.writeBucket(widget.base);
    try {
      await CollaborationService.instance.addFileToGroup(
        groupId: selected.id,
        pathScope: o.key,
        bucket: bucket,
        fileName: _displayName(o).split('/').last,
        fileSize: o.size,
        contentType: _contentTypeOf(o),
      );
      _snack('Added "${_displayName(o).split('/').last}" to "${selected.name}"');
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _showPublicIpfsLinkDialog(
      String gatewayUrl, String fileName) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 24),
            SizedBox(width: 8),
            Text('Shared Publicly'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$fileName is now publicly accessible via IPFS.'),
            const SizedBox(height: 8),
            const Text(
              'Anyone with this link can access the file:',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                gatewayUrl,
                style:
                    const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open'),
            onPressed: () => launchUrl(
              Uri.parse(gatewayUrl),
              webOnlyWindowName: '_blank',
            ),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy URL'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: gatewayUrl));
              Navigator.pop(ctx);
              _snack('IPFS URL copied to clipboard');
            },
          ),
        ],
      ),
    );
  }

  bool _isVideo(FulaObject o) {
    final ct = o.metadata?['contentType'] ?? '';
    if (ct.startsWith('video/')) return true;
    final n = o.key.toLowerCase();
    return n.endsWith('.mp4') ||
        n.endsWith('.webm') ||
        n.endsWith('.mov') ||
        n.endsWith('.m4v');
  }

  bool _isAudio(FulaObject o) {
    final ct = o.metadata?['contentType'] ?? '';
    if (ct.startsWith('audio/')) return true;
    final n = o.key.toLowerCase();
    return n.endsWith('.mp3') ||
        n.endsWith('.m4a') ||
        n.endsWith('.wav') ||
        n.endsWith('.ogg') ||
        n.endsWith('.flac');
  }

  String _mediaMime(FulaObject o) {
    final ct = o.metadata?['contentType'] ?? '';
    if (ct.isNotEmpty && ct != 'application/octet-stream') return ct;
    final n = o.key.toLowerCase();
    if (n.endsWith('.mp4') || n.endsWith('.m4v')) return 'video/mp4';
    if (n.endsWith('.webm')) return 'video/webm';
    if (n.endsWith('.mov')) return 'video/quicktime';
    if (n.endsWith('.mp3')) return 'audio/mpeg';
    if (n.endsWith('.m4a')) return 'audio/mp4';
    if (n.endsWith('.wav')) return 'audio/wav';
    if (n.endsWith('.ogg')) return 'audio/ogg';
    if (n.endsWith('.flac')) return 'audio/flac';
    return 'application/octet-stream';
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
    if (_isVideo(o) || _isAudio(o)) {
      await _previewMedia(o);
      return;
    }
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

  /// Download + decrypt, then play via a blob URL fed to the HTML5
  /// media element (video_player / just_audio on web). Best-effort:
  /// codec support depends on the browser; the dialog offers Download
  /// as the fallback.
  Future<void> _previewMedia(FulaObject o) async {
    _snack('Loading "${_displayName(o)}"…');
    try {
      final bytes = await FulaApiService.instance.downloadObject(
        o.sourceBucket ?? widget.base,
        o.key,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => MediaPreviewDialog(
          title: _displayName(o),
          bytes: bytes,
          mimeType: _mediaMime(o),
          isVideo: _isVideo(o),
        ),
      );
    } catch (e) {
      _snack('Playback failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  static const labels = {
    'images': 'Images',
    'videos': 'Videos',
    'audio': 'Audio',
    'documents': 'Documents',
    'downloads': 'Downloads',
    'archives': 'Archives',
  };

  @override
  Widget build(BuildContext context) {
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
            onPressed: _loading ? null : _refreshHard,
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
                TextButton(
                    onPressed: () => _load(force: true),
                    child: const Text('Retry')),
              ],
            ),
          if (!_stale &&
              !_loading &&
              _fetchedAt != null &&
              DateTime.now().difference(_fetchedAt!) > kSwrSyncedAgoWindow)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Text(
                'Synced ${DateTime.now().difference(_fetchedAt!).inMinutes} min ago',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
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
                        onPressed: () => _load(force: true),
                        child: const Text('Retry')),
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
                      'Use Upload to add files from this device.\n'
                      'Files uploaded before the June 2026 storage upgrade '
                      'are available in the mobile and desktop apps.',
                      textAlign: TextAlign.center,
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
                  final tags = _fileTags[o.key] ?? const <FileTag>[];
                  return ListTile(
                    leading: Icon(_isImage(o)
                        ? Icons.image_outlined
                        : _isVideo(o)
                            ? Icons.movie_outlined
                            : _isAudio(o)
                                ? Icons.audiotrack_outlined
                                : _isText(o)
                                    ? Icons.article_outlined
                                    : Icons.insert_drive_file_outlined),
                    title: Text(_displayName(o),
                        overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text([
                          _fmtSize(o.size),
                          if (o.lastModified != null)
                            '${o.lastModified!.toLocal()}'
                                .split('.')
                                .first,
                        ].join('  ·  ')),
                        if (tags.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _TagChipRow(tags: tags),
                          ),
                      ],
                    ),
                    onTap: () => _preview(o),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'download') _download(o);
                        if (v == 'tags') _editTags(o);
                        if (v == 'share') _shareFile(o);
                        if (v == 'public') _sharePublicly(o);
                        if (v == 'collab') _addToCollaboration(o);
                        if (v == 'delete') _delete(o);
                      },
                      // Same entry points as the app's file menu: the
                      // private share sheet (its three options cover
                      // public-gateway links too) and the unencrypted
                      // IPFS Share Publicly path.
                      itemBuilder: (ctx) => const [
                        PopupMenuItem(
                          value: 'download',
                          child: Text('Download'),
                        ),
                        PopupMenuItem(
                          value: 'tags',
                          child: Text('Tags'),
                        ),
                        PopupMenuItem(
                          value: 'share',
                          child: Text('Share Private…'),
                        ),
                        PopupMenuItem(
                          value: 'public',
                          child: Text('Share Publicly'),
                        ),
                        PopupMenuItem(
                          value: 'collab',
                          child: Text('Add to Collaborate'),
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

/// Compact tag chips under a file row — mirror of the native
/// TagChipRow(compact: true) in lib/features/tags/widgets/tag_chip.dart:
/// up to two solid mini-chips plus a "+N" overflow marker.
class _TagChipRow extends StatelessWidget {
  final List<FileTag> tags;
  static const int _maxVisible = 2;

  const _TagChipRow({required this.tags});

  @override
  Widget build(BuildContext context) {
    final visible = tags.take(_maxVisible).toList();
    final rest = tags.length - visible.length;
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: [
        for (final t in visible)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Color(t.colorValue).withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              t.name,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        if (rest > 0)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '+$rest',
              style: const TextStyle(
                  fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
      ],
    );
  }
}

