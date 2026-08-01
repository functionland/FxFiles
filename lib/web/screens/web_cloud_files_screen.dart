import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/share_token.dart' as share_model;
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_public_service.dart';
import 'package:fula_files/web/services/web_audio_controller.dart';
import 'package:fula_files/web/services/web_device_class.dart';
import 'package:fula_files/web/services/web_file_view_mode.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/services/web_streaming_file.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_text_viewer_logic.dart';
import 'package:fula_files/web/services/web_thumbnail_service.dart';
import 'package:fula_files/web/services/web_upload_manager.dart';
import 'package:fula_files/web/services/web_view_mode_store.dart';
import 'package:fula_files/web/utils/cloud_folder_tree.dart';
import 'package:fula_files/web/widgets/media_preview_dialog.dart';
import 'package:fula_files/web/widgets/web_audio_player.dart';
import 'package:fula_files/web/widgets/web_file_grid_tile.dart';
import 'package:fula_files/web/widgets/web_create_share_dialog.dart';
import 'package:fula_files/web/widgets/web_tag_dialogs.dart';
import 'package:fula_files/web/widgets/web_text_viewer.dart';
import 'package:fula_files/web/widgets/web_thumb.dart';

/// Result of [_WebCloudFilesScreenState._copyDelete]'s download → upload →
/// delete round-trip (no server-side copy exists for the encrypted forest).
enum _CopyDeleteResult { ok, copyFailed, deleteFailed }

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
  // objectKey → tags for the current bucket (category-tabs / native parity:
  // file rows show compact tag chips). Refreshed after each listing + edit;
  // cleared on bucket switch so a stale chip can't flash on the next bucket.
  Map<String, List<FileTag>> _fileTags = const {};

  bool _loading = true;
  String? _error;

  StreamSubscription<String>? _uploadSub;

  /// list / 2-col grid / 3-col grid (native parity). One choice for the
  /// whole cloud browser (native uses a single `viewMode_cloud` key too
  /// — folders and files share the layout), read synchronously so the
  /// first frame paints in the remembered mode.
  WebFileViewMode _viewMode = WebFileViewMode.list;
  static const String _viewModeKey = 'cloud';

  @override
  void initState() {
    super.initState();
    _viewMode = WebViewModeStore.instance.read(_viewModeKey);
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
        // Hide the sidecar thumbnail buckets (e.g. images-v8-thumbs).
        _buckets = [for (final b in r.buckets) if (!isThumbsBucket(b)) b]
          ..sort();
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
      final objs = await WebForegroundActivity.instance.run(
          () => FulaApiService.instance.listObjects(bucket));
      if (!mounted) return;
      setState(() {
        _objects = objs;
        _loading = false;
      });
      _refreshTags(bucket, objs); // best-effort chip data; never blocks listing
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      // A brand-new / empty bucket has no forest yet — that's the empty
      // state, not an error.
      if (msg.contains('NoSuchBucket') || msg.contains('bucket not found')) {
        setState(() {
          _objects = const [];
          _fileTags = const {};
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

  /// Best-effort tag-chip data for the current bucket — never blocks or fails
  /// the listing (mirror of WebBucketScreen._refreshTags). One pass over the
  /// whole flat bucket covers every folder; rows look up `_fileTags[o.key]`.
  Future<void> _refreshTags(String bucket, List<FulaObject> objects) async {
    try {
      await WebTagService.instance.load();
      final tags = WebTagService.instance.tagsForObjects(bucket, objects);
      if (mounted) setState(() => _fileTags = tags);
    } catch (e) {
      debugPrint('WebCloudFilesScreen: tag load skipped: $e');
    }
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _openBucket(String bucket) {
    setState(() {
      _bucket = bucket;
      _prefix = '';
      _objects = const [];
      _fileTags = const {};
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
      _fileTags = const {};
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
    final bucket = o.sourceBucket ?? _bucket!;
    if (o.isVideo) {
      await _previewVideo(bucket, o);
    } else if (o.isAudio) {
      await _openAudioPlayer(bucket, o);
    } else if (isTextViewableName(o.key)) {
      if (o.size > kMaxInlineTextBytes) {
        await _download(o);
      } else {
        await _previewText(bucket, o);
      }
    } else if (o.isImage) {
      await _previewImage(o);
    } else {
      await _download(o); // documents/PDF/other → download (same as category tabs)
    }
  }

  /// MIME for the media viewers: the stored content-type, else a guess by ext.
  String _mime(FulaObject o) {
    final ct = o.metadata?['contentType'];
    if (ct != null && ct.isNotEmpty && ct != 'application/octet-stream') {
      return ct;
    }
    final i = o.key.lastIndexOf('.');
    switch (i < 0 ? '' : o.key.substring(i + 1).toLowerCase()) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'flac':
        return 'audio/flac';
      case 'aac':
        return 'audio/aac';
      default:
        return 'application/octet-stream';
    }
  }

  /// Video via the shared MediaPreviewDialog (blob-URL HTML5 player).
  Future<void> _previewVideo(String bucket, FulaObject o) async {
    _snack('Loading "${o.name}"…');
    try {
      final bytes = await WebForegroundActivity.instance
          .run(() => FulaApiService.instance.downloadObject(bucket, o.key));
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => MediaPreviewDialog(
          title: o.name,
          bytes: bytes,
          mimeType: _mime(o),
          isVideo: true,
        ),
      );
    } catch (e) {
      _snack('Playback failed: ${_clean(e)}');
    }
  }

  WebAudioTrack _audioTrack(String bucket, FulaObject o) => WebAudioTrack(
        name: o.name,
        mime: _mime(o),
        cloudKey: o.key,
        download: () => FulaApiService.instance.downloadObject(bucket, o.key),
      );

  /// Audio via the shared full-screen queue player — queue = the current
  /// folder's audio files, starting at the tapped one.
  Future<void> _openAudioPlayer(String bucket, FulaObject tapped) async {
    final audio = _view().files.where((o) => o.isAudio).toList();
    var start = audio.indexWhere((o) => o.key == tapped.key);
    if (start < 0) {
      audio.insert(0, tapped);
      start = 0;
    }
    final c = WebAudioController.instance;
    c.playQueue(
      [for (final o in audio) _audioTrack(o.sourceBucket ?? bucket, o)],
      start,
    );
    c.setExpanded(true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (ctx) => const Dialog.fullscreen(child: WebAudioPlayer()),
    );
  }

  /// Text/code via the shared full-screen WebTextViewer (download if too big).
  Future<void> _previewText(String bucket, FulaObject o) async {
    _snack('Loading "${o.name}"…');
    try {
      final bytes = await WebForegroundActivity.instance
          .run(() => FulaApiService.instance.downloadObject(bucket, o.key));
      if (!mounted) return;
      if (bytes.length > kMaxInlineTextBytes) {
        saveBytesAsDownload(o.name, bytes);
        return;
      }
      await showDialog<void>(
        context: context,
        useSafeArea: false,
        builder: (ctx) => Dialog.fullscreen(
          child: WebTextViewer(
            fileName: o.name,
            bytes: bytes,
            onDownload: () => saveBytesAsDownload(o.name, bytes),
          ),
        ),
      );
    } catch (e) {
      _snack('Preview failed: ${_clean(e)}');
    }
  }

  Future<void> _previewImage(FulaObject o) async {
    final bucket = o.sourceBucket ?? _bucket!;
    final future = FulaApiService.instance.downloadObject(bucket, o.key);
    // The full bytes download anyway — backfill a thumbnail (gated to the
    // user's own writable bucket) so the grid shows it next time.
    unawaited(future
        .then((bytes) => WebThumbnailService.instance
            .backfillFromBytes(bucket, o.key, o.name, bytes))
        .catchError((_) {}));
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
          child: FutureBuilder<Uint8List>(
            future: future,
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

  /// Add/edit tags for [o] — reuses the category screen's tag selector +
  /// WebTagService (tags round-trip across platforms).
  Future<void> _editTags(FulaObject o) async {
    final bucket = o.sourceBucket ?? _bucket!;
    try {
      await WebTagService.instance.load();
    } catch (e) {
      _snack('Could not load tags: ${_clean(e)}');
      return;
    }
    if (!mounted) return;
    final initial =
        (WebTagService.instance.tagsForObjects(bucket, [o])[o.key] ??
                const <FileTag>[])
            .map((t) => t.id)
            .toSet();
    await showWebTagSelectorDialog(
      context: context,
      remoteKey: '$bucket/${o.key}',
      fileName: o.name,
      initialTagIds: initial,
    );
    // Reflect any tag change as updated chips (the dialog already synced the
    // in-memory manifest, so this needs no force-reload).
    if (mounted) _refreshTags(bucket, _objects);
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
      unawaited(WebThumbnailService.instance.deleteCloudThumb(bucket, o.key));
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
        unawaited(WebThumbnailService.instance.deleteCloudThumb(bucket, o.key));
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

  // ── Share / rename / move ──────────────────────────────────────────────────

  /// Largest file we rename/move on web. The encrypted forest has no
  /// server-side copy, so rename/move = download + re-upload + delete; the whole
  /// file is held in memory, which would OOM a low-RAM tab on big files.
  static const int _kMaxCopyBytes = 50 * 1024 * 1024;

  bool _guardCopySize(FulaObject o, String verb) {
    if (o.size > _kMaxCopyBytes) {
      _snack('Files over 50 MB can\'t be $verb on the web yet '
          '(it would exceed browser memory).');
      return false;
    }
    return true;
  }

  String? _ct(FulaObject o) {
    final ct = o.metadata?['contentType'];
    return (ct != null && ct.isNotEmpty && ct != 'application/octet-stream')
        ? ct
        : null;
  }

  Future<void> _shareFile(FulaObject o) async {
    final bucket = o.sourceBucket ?? _bucket!;
    final storageKey = o.storageKey ?? o.key;
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
      fileName: o.name,
      contentType: _ct(o),
      snapshotBinding: binding,
    );
    if (result != null && mounted) {
      await showWebShareCreatedDialog(context: context, result: result);
    }
  }

  Future<void> _sharePublicly(FulaObject o) async {
    if (!await _confirm(
        'Share publicly?',
        'This uploads "${o.name}" (${o.sizeFormatted}) to IPFS WITHOUT '
            'encryption. Anyone with the link can access it.',
        confirmLabel: 'Share publicly')) {
      return;
    }
    if (!_guardCopySize(o, 'shared publicly')) return;
    final bucket = o.sourceBucket ?? _bucket!;
    _snack('Uploading "${o.name}" to IPFS…');
    try {
      final bytes = await WebForegroundActivity.instance
          .run(() => FulaApiService.instance.downloadObject(bucket, o.key));
      final result = await IpfsPublicService.instance.pinBytes(bytes, o.name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      await _showPublicLink(result.gatewayUrl, o.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      _snack('Public share failed: ${_clean(e)}');
    }
  }

  Future<void> _showPublicLink(String url, String fileName) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Public link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fileName,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SelectableText(url, style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (ctx.mounted) Navigator.pop(ctx);
              _snack('Link copied');
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy link'),
          ),
        ],
      ),
    );
  }

  Future<void> _renameFile(FulaObject o) async {
    if (_isReadOnly || !_guardCopySize(o, 'renamed')) return;
    final newName = await _promptName(
      title: 'Rename file',
      hint: o.name,
      helper: 'Stays in the same folder.',
      initial: o.name,
      validator: (v) => _validateFileName(v, exclude: o.name),
    );
    if (newName == null || newName == o.name) return;
    final bucket = o.sourceBucket ?? _bucket!;
    await _copyDelete(bucket, o, bucket, cloudChildKey(_prefix, newName), 'Renamed');
  }

  Future<void> _moveFile(FulaObject o) async {
    if (_isReadOnly || !_guardCopySize(o, 'moved')) return;
    final dest = await _pickMoveDestination(o);
    if (dest == null) return;
    final srcBucket = o.sourceBucket ?? _bucket!;
    final destKey = cloudChildKey(dest.prefix, o.name);
    if (dest.bucket == srcBucket &&
        normalizeCloudKey(destKey) == normalizeCloudKey(o.key)) {
      _snack('Already there');
      return;
    }
    await _copyDelete(srcBucket, o, dest.bucket, destKey, 'Moved');
  }

  /// Shared download → upload-to-dest → delete-source for rename + move. No
  /// server-side copy exists for the encrypted forest, so this round-trips the
  /// bytes (size-guarded by [_guardCopySize]).
  Future<void> _copyDelete(String srcBucket, FulaObject o, String destBucket,
      String destKey, String okWord) async {
    _snack('Working…');
    // No server-side copy for the encrypted forest: download from the source
    // bucket, re-upload to the destination, then delete the source.
    final result = await WebForegroundActivity.instance.run<_CopyDeleteResult>(
      () async {
        try {
          final bytes =
              await FulaApiService.instance.downloadObject(srcBucket, o.key);
          await FulaApiService.instance
              .uploadObject(destBucket, destKey, bytes, contentType: _ct(o));
        } catch (_) {
          return _CopyDeleteResult.copyFailed;
        }
        try {
          await FulaApiService.instance.deleteObject(srcBucket, o.key);
        } catch (_) {
          return _CopyDeleteResult.deleteFailed;
        }
        return _CopyDeleteResult.ok;
      },
    );
    if (!mounted) return;
    switch (result) {
      case _CopyDeleteResult.copyFailed:
        _snack('$okWord failed.');
        return;
      case _CopyDeleteResult.deleteFailed:
        // The copy landed but the original couldn't be removed; refresh so the
        // new copy shows (the stale original still exists too).
        _snack('Copied, but couldn\'t remove the original.');
        await _loadObjects(silent: true);
        return;
      case _CopyDeleteResult.ok:
        break;
    }
    setState(() =>
        _objects = [for (final x in _objects) if (x.key != o.key) x]);
    _snack(okWord);
    unawaited(WebThumbnailService.instance
        .moveCloudThumb(srcBucket, o.key, destBucket, destKey));
    await _loadObjects(silent: true);
  }

  Future<({String bucket, String prefix})?> _pickMoveDestination(
      FulaObject o) async {
    final writable = [
      for (final b in _buckets)
        if (!BucketVersionResolver.isForbiddenWriteTarget(b)) b
    ];
    if (writable.isEmpty) {
      _snack('No writable buckets to move into.');
      return null;
    }
    final srcBucket = o.sourceBucket ?? _bucket;
    var selBucket = (_bucket != null && writable.contains(_bucket!))
        ? _bucket!
        : writable.first;
    final folderCtrl = TextEditingController(text: _prefix);
    final result = await showDialog<({String bucket, String prefix})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final crossBucket = selBucket != srcBucket;
          return AlertDialog(
            title: Text('Move "${o.name}"'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Destination bucket',
                      style: Theme.of(ctx).textTheme.labelMedium),
                ),
                DropdownButton<String>(
                  value: selBucket,
                  isExpanded: true,
                  items: [
                    for (final b in writable)
                      DropdownMenuItem(value: b, child: Text(b))
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => selBucket = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: folderCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Folder',
                    hintText: 'e.g. photos/2024 — blank for root',
                  ),
                ),
                if (crossBucket) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 16, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Moving to a different bucket.',
                          style: Theme.of(ctx).textTheme.bodySmall),
                    ),
                  ]),
                ],
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, (
                  bucket: selBucket,
                  prefix: normalizeCloudPrefix(folderCtrl.text),
                )),
                child: const Text('Move'),
              ),
            ],
          );
        },
      ),
    );
    folderCtrl.dispose();
    return result;
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

  Future<bool> _confirm(String title, String body,
      {String confirmLabel = 'Delete'}) async {
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
              child: Text(confirmLabel)),
        ],
      ),
    );
    return ok == true;
  }

  String? _validateFolderName(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'Enter a name.';
    if (s.contains('/')) return 'No "/" in a folder name.';
    if (s == kFolderMarkerName) return 'Reserved name.';
    return null;
  }

  String? _validateFileName(String v, {String? exclude}) {
    final s = v.trim();
    if (s.isEmpty) return 'Enter a name.';
    if (s.contains('/')) return 'No "/" in a file name.';
    if (s == kFolderMarkerName) return 'Reserved name.';
    final siblings = _view().files.map((f) => f.name).toSet();
    if (s != exclude && siblings.contains(s)) {
      return 'A file with this name already exists here.';
    }
    return null;
  }

  Future<String?> _promptName({
    required String title,
    required String hint,
    required String helper,
    required String? Function(String) validator,
    String? initial,
  }) async {
    final controller = TextEditingController(text: initial ?? '');
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

  /// One cycling button (native parity): list → 2-col → 3-col → list.
  void _cycleViewMode() {
    final next = nextWebFileViewMode(_viewMode);
    setState(() => _viewMode = next);
    WebViewModeStore.instance.write(_viewModeKey, next);
  }

  static IconData _viewModeIcon(WebFileViewMode m) {
    switch (m) {
      case WebFileViewMode.list:
        return Icons.view_list;
      case WebFileViewMode.grid2:
        return Icons.grid_view;
      case WebFileViewMode.grid3:
        return Icons.grid_on;
    }
  }

  /// Names what the button switches TO (see WebBucketScreen).
  static String _viewModeTooltip(WebFileViewMode m) {
    switch (nextWebFileViewMode(m)) {
      case WebFileViewMode.list:
        return 'Switch to list view';
      case WebFileViewMode.grid2:
        return 'Switch to grid (2 columns)';
      case WebFileViewMode.grid3:
        return 'Switch to grid (3 columns)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: _bucket == null ? 'Back' : 'Up',
          onPressed: () {
            if (_bucket == null) {
              // _go used context.go (stack replaced), so there's usually
              // nothing to pop — fall back to home.
              context.canPop() ? context.pop() : context.go('/');
            } else {
              _up();
            }
          },
        ),
        title: const Text('Cloud Files'),
        actions: [
          // Only inside a bucket — the bucket LIST stays a list (there
          // is nothing to thumbnail, and native has no grid there).
          if (_bucket != null)
            IconButton(
              tooltip: _viewModeTooltip(_viewMode),
              icon: Icon(_viewModeIcon(_viewMode)),
              onPressed: _cycleViewMode,
            ),
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
    // Only pre-created buckets — no bucket creation from the web UI.
    if (_bucket == null) return null;
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

  // Memoized folder view: deriveCloudFolderView re-scans the whole flat list,
  // so cache it and recompute only when the object-list identity or the prefix
  // changes — not on every build or every rename-dialog keystroke.
  ({List<String> folders, List<FulaObject> files})? _viewCache;
  int? _viewObjectsId;
  String? _viewPrefix;

  ({List<String> folders, List<FulaObject> files}) _view() {
    final id = identityHashCode(_objects);
    if (_viewCache != null && _viewObjectsId == id && _viewPrefix == _prefix) {
      return _viewCache!;
    }
    final v = deriveCloudFolderView(_objects, _prefix);
    _viewCache = v;
    _viewObjectsId = id;
    _viewPrefix = _prefix;
    return v;
  }

  Widget _folderView() {
    final view = _view();
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
      child: _viewMode == WebFileViewMode.list
          ? _buildFileList(view)
          : _buildFileGrid(view),
    );
  }

  /// Folder actions — null in read-only buckets (native shows a plain
  /// chevron there).
  Widget? _folderMenu(String name, {bool dense = false}) {
    if (_isReadOnly) return null;
    return PopupMenuButton<String>(
      tooltip: 'More',
      // dense = a grid cell corner: shrink the BUTTON (iconSize/padding).
      // Not `constraints` — that sizes the popup menu, not the button.
      iconSize: dense ? 18 : 24,
      padding: dense ? EdgeInsets.zero : const EdgeInsets.all(8),
      onSelected: (v) {
        if (v == 'delete') _deleteFolder(name);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  Widget _fileMenu(FulaObject o, {bool dense = false}) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      // dense = a grid cell corner: shrink the BUTTON (iconSize/padding).
      // Not `constraints` — that sizes the popup menu, not the button.
      iconSize: dense ? 18 : 24,
      padding: dense ? EdgeInsets.zero : const EdgeInsets.all(8),
      onSelected: (v) {
        switch (v) {
          case 'open':
            _open(o);
          case 'download':
            _download(o);
          case 'tags':
            _editTags(o);
          case 'share':
            _shareFile(o);
          case 'sharePublic':
            _sharePublicly(o);
          case 'rename':
            _renameFile(o);
          case 'move':
            _moveFile(o);
          case 'delete':
            _deleteFile(o);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'open', child: Text('Open')),
        const PopupMenuItem(value: 'download', child: Text('Download')),
        const PopupMenuItem(value: 'tags', child: Text('Tags')),
        const PopupMenuItem(
            value: 'share', child: Text('Share (private link)')),
        const PopupMenuItem(
            value: 'sharePublic', child: Text('Share publicly')),
        if (!_isReadOnly)
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
        if (!_isReadOnly)
          const PopupMenuItem(value: 'move', child: Text('Move')),
        if (!_isReadOnly)
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  Widget _buildFileList(({List<String> folders, List<FulaObject> files}) view) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: view.folders.length + view.files.length,
      itemBuilder: (_, i) {
        if (i < view.folders.length) {
          final name = view.folders[i];
          return ListTile(
            leading: const Icon(LucideIcons.folder, color: Color(0xFF8AB4F8)),
            title: Text(name),
            onTap: () => _enterFolder(name),
            trailing:
                _folderMenu(name) ?? const Icon(Icons.chevron_right),
          );
        }
        final o = view.files[i - view.folders.length];
        final tags = _fileTags[o.key] ?? const <FileTag>[];
        return ListTile(
          leading: o.isImage
              ? WebThumb(
                  bucket: o.sourceBucket ?? _bucket!,
                  objectKey: o.key,
                  fallback: Icon(_iconFor(o)),
                )
              : Icon(_iconFor(o)),
          title: Text(o.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(o.sizeFormatted),
              if (tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _TagChipRow(tags: tags),
                ),
            ],
          ),
          onTap: () => _open(o),
          trailing: _fileMenu(o),
        );
      },
    );
  }

  /// Grid view. Folders keep leading the files (same flat index space as
  /// the list) and render as icon tiles. See WebBucketScreen._buildGrid
  /// for why cacheExtent is modest and keep-alives are off — a grid puts
  /// 4-9x more thumbnail-capable tiles on screen than the list.
  Widget _buildFileGrid(({List<String> folders, List<FulaObject> files}) view) {
    final dense = _viewMode == WebFileViewMode.grid3;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final columns = webGridColumnsFor(_viewMode, constraints.maxWidth);
        return GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
          cacheExtent: webGridCacheExtent(lowEnd: WebDeviceClass.lowEnd),
          addAutomaticKeepAlives: false,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: webGridAspectRatioFor(_viewMode),
          ),
          itemCount: view.folders.length + view.files.length,
          itemBuilder: (ctx, i) {
            if (i < view.folders.length) {
              final name = view.folders[i];
              return WebFileGridTile(
                thumbnail: const Icon(LucideIcons.folder,
                    size: 40, color: Color(0xFF8AB4F8)),
                name: name,
                menu: _folderMenu(name, dense: true),
                onTap: () => _enterFolder(name),
                dense: dense,
              );
            }
            final o = view.files[i - view.folders.length];
            final tags = _fileTags[o.key] ?? const <FileTag>[];
            return WebFileGridTile(
              thumbnail: o.isImage
                  ? WebThumb(
                      bucket: o.sourceBucket ?? _bucket!,
                      objectKey: o.key,
                      fallback: _gridIcon(o),
                      fill: true,
                    )
                  : _gridIcon(o),
              name: o.name,
              subtitle: o.sizeFormatted,
              tags: tags.isEmpty ? null : _TagChipRow(tags: tags),
              menu: _fileMenu(o, dense: true),
              onTap: () => _open(o),
              dense: dense,
            );
          },
        );
      },
    );
  }

  Widget _gridIcon(FulaObject o) => Icon(
        _iconFor(o),
        size: 36,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );

  IconData _iconFor(FulaObject o) {
    if (o.isImage) return LucideIcons.image;
    if (o.isVideo) return LucideIcons.video;
    if (o.isAudio) return LucideIcons.music;
    if (o.isDocument) return LucideIcons.fileText;
    return LucideIcons.file;
  }
}

/// Compact tag chips under a file row — duplicated from WebBucketScreen's
/// _TagChipRow (itself a mirror of the native TagChipRow(compact: true) in
/// lib/features/tags/widgets/tag_chip.dart): up to two solid mini-chips plus a
/// "+N" overflow marker. Kept identical by eye; extract a shared widget if a
/// third consumer appears (rule-of-three).
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '+$rest',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
      ],
    );
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
