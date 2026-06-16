import 'dart:async';

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
import 'package:fula_files/web/services/web_audio_controller.dart';
import 'package:fula_files/web/services/web_bucket_sort.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';
import 'package:fula_files/web/services/web_recent_files_service.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/services/web_share_service.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_text_viewer_logic.dart';
import 'package:fula_files/web/services/web_upload_manager.dart';
import 'package:fula_files/web/widgets/media_preview_dialog.dart';
import 'package:fula_files/web/widgets/web_audio_player.dart';
import 'package:fula_files/web/widgets/web_create_share_dialog.dart';
import 'package:fula_files/web/widgets/web_tag_dialogs.dart';
import 'package:fula_files/web/widgets/web_text_viewer.dart';

/// Merged (legacy + v8) listing of one content category, with upload /
/// download / delete / preview.
class WebBucketScreen extends StatefulWidget {
  final String base; // 'images' | 'videos' | 'documents' | 'audio'

  /// When set (via `/b/<base>?open=<key>`), the matching file opens
  /// automatically once the listing loads — used by the home Recent strip.
  final String? openKey;
  const WebBucketScreen({super.key, required this.base, this.openKey});

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

  /// Per-category sort (#7), mirroring mobile: default date-descending
  /// (newest first). In-memory per screen visit (mobile doesn't persist it).
  WebSortBy _sortBy = WebSortBy.date;
  bool _sortAscending = false;

  /// objectKey → tags, refreshed after each listing (native parity:
  /// file rows show compact tag chips).
  Map<String, List<FileTag>> _fileTags = const {};

  // Uploads now run in the app-level WebUploadManager (they survive
  // navigating away from this screen). We only listen for "a file for THIS
  // category finished" to refresh the listing from the now-fresh cache.
  StreamSubscription<String>? _uploadDoneSub;

  /// `?open=` deep-open guard so we auto-open the target file at most once.
  bool _autoOpened = false;

  @override
  void initState() {
    super.initState();
    // Connection-regain → silent forced revalidate (plan §5.3).
    WebListingSwr.instance.ensureOnlineHook();
    WebListingSwr.instance.addListener(_onOnline);
    _uploadDoneSub =
        WebUploadManager.instance.onBucketCompleted.listen((base) {
      // The manager already refreshed this tab's cache from the session
      // forest before emitting, so a plain (force:false) load serves the
      // fresh listing — including the new file — without another forest
      // read.
      if (base == widget.base && mounted) _load();
    });
    _load();
  }

  @override
  void dispose() {
    WebListingSwr.instance.removeListener(_onOnline);
    _uploadDoneSub?.cancel();
    super.dispose();
  }

  void _onOnline() {
    if (mounted && !_loading) _load(force: true, silent: true);
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
  /// place. force = awaited live listing. refetchForest (defaults to
  /// force) = ALSO pull the forest from the server — right for the
  /// Refresh button / reconnect (cross-device intent), wrong after our
  /// OWN upload/delete, whose freshest truth is the session forest.
  Future<void> _load(
      {bool force = false,
      bool silent = false,
      bool hardRebuild = false,
      bool? refetchForest}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final bucket = BucketVersionResolver.writeBucket(widget.base);
    try {
      // Hard refresh (explicit Refresh button): the SDK can strand a bucket's
      // forest DIRTY in the in-memory cache, where neither the 60s TTL nor
      // invalidateForestCache evicts it — so a plain force-refresh keeps
      // serving the stale index (only a fresh client / incognito reads the
      // server). Rebuilding the client drops every in-memory forest so the
      // listing below reloads from storage. Skip while an upload is in flight:
      // a rebuild swaps the client handle out from under the in-flight write.
      if (hardRebuild && !WebUploadManager.instance.isActive) {
        try {
          await FulaApiService.instance.rebuildEncryptedClient();
        } catch (e) {
          debugPrint('WebBucket: hard-rebuild failed (continuing): $e');
        }
      }
      // Foreground-wrapped: the prefetcher must yield while a screen
      // the user is looking at loads or patches in.
      final r = await WebForegroundActivity.instance.run(() =>
          WebListingSwr.instance.getListing(bucket,
              force: force, refetchForest: refetchForest));
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
    final objects = sortObjects(
      raw.map((o) => o.withSourceBucket(bucket)).toList(),
      _sortBy,
      _sortAscending,
    );
    if (!mounted) return;
    setState(() {
      _objects = objects;
      _stale = stale;
      _loading = false;
      _fetchedAt = fetchedAt;
    });
    _refreshTags(bucket, objects);
    _maybeAutoOpen(objects);
  }

  /// Re-sort the already-loaded objects (a sort change doesn't refetch).
  void _resort() {
    final objs = _objects;
    if (objs == null) return;
    setState(() => _objects = sortObjects(objs, _sortBy, _sortAscending));
  }

  /// Mobile-style sort sheet (#7): Date newest/oldest, Name A–Z/Z–A.
  void _showSortSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget tile(String label, WebSortBy by, bool asc) {
          final selected = _sortBy == by && _sortAscending == asc;
          return ListTile(
            title: Text(label),
            trailing: selected
                ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                : null,
            onTap: () {
              Navigator.pop(ctx);
              if (selected) return;
              _sortBy = by;
              _sortAscending = asc;
              _resort();
            },
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                  title: Text('Sort by',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              tile('Date modified (newest first)', WebSortBy.date, false),
              tile('Date modified (oldest first)', WebSortBy.date, true),
              tile('Name (A–Z)', WebSortBy.name, true),
              tile('Name (Z–A)', WebSortBy.name, false),
            ],
          ),
        );
      },
    );
  }

  /// `/b/<base>?open=<key>` deep-open (home Recent strip): open the
  /// matching file once it appears in the listing. Retries across the
  /// cache→revalidation renders (flag set only on a successful match); if
  /// the file is gone it simply never opens and the user sees the category.
  void _maybeAutoOpen(List<FulaObject> objects) {
    if (widget.openKey == null || _autoOpened) return;
    FulaObject? match;
    for (final o in objects) {
      if (o.key == widget.openKey) {
        match = o;
        break;
      }
    }
    if (match == null) return;
    _autoOpened = true;
    final obj = match;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _preview(obj);
    });
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

    // Hand the picked bytes to the app-level manager and return. The upload
    // now runs independently of this screen: progress shows in the global
    // tray, it survives navigating away, the bucket is created and per-file
    // size cap enforced there, and on completion the manager refreshes this
    // tab's cache and pings us via onBucketCompleted (own-write path).
    final files = <({String name, Uint8List bytes})>[];
    for (final f in picked.files) {
      final data = f.bytes;
      if (data == null) continue;
      files.add((name: f.name, bytes: data));
    }
    if (files.isEmpty) return;

    WebUploadManager.instance.enqueue(
      base: widget.base,
      bucket: BucketVersionResolver.writeBucket(widget.base),
      files: files,
    );
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
      _recordRecent(o, bucket);
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
      // Own write — session forest already lacks the file; a server
      // refetch during the propagation window would resurrect it.
      await _load(force: true, refetchForest: false);
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
    if (ct.startsWith('text/') ||
        ct == 'application/json' ||
        ct == 'application/xml') {
      return true;
    }
    // Native parity: the full LocalFile.isTextViewable extension set
    // (xml, ts, js, html, yaml, py, …), not just the old short list (#19).
    return isTextViewableName(o.key);
  }

  /// A stable kind for the recents store (forces image/video/audio
  /// classification so the strip renders the right card + thumbnail).
  String _recentMime(FulaObject o) {
    if (_isImage(o)) return 'image/*';
    if (_isVideo(o)) return 'video/*';
    if (_isAudio(o)) return 'audio/*';
    final ct = o.metadata?['contentType'] ?? '';
    return ct.isNotEmpty ? ct : 'application/octet-stream';
  }

  /// Record a successful open in the device-local Recent strip (#17).
  void _recordRecent(FulaObject o, String bucket, {Uint8List? imageBytes}) {
    WebRecentFilesService.instance.recordOpened(
      bucket: bucket,
      base: widget.base,
      key: o.key,
      name: _displayName(o).split('/').last,
      mime: _recentMime(o),
      size: o.size,
      imageBytes: imageBytes,
    );
  }

  Future<void> _preview(FulaObject o) async {
    if (_isVideo(o) || _isAudio(o)) {
      await _previewMedia(o);
      return;
    }
    if (_isText(o)) {
      // The whole file is in memory on web; decoding + splitting a huge
      // string would jank the JS thread, so cap inline viewing and fall
      // back to download (#19). Guard on the listed size pre-download.
      if (o.size > kMaxInlineTextBytes) {
        await _download(o);
      } else {
        await _previewText(o);
      }
      return;
    }
    if (!_isImage(o)) {
      await _download(o);
      return;
    }
    final bucket = o.sourceBucket ?? widget.base;
    // One download future shared with the dialog; record once when it
    // resolves (not on FutureBuilder rebuilds, not on failure).
    final future = FulaApiService.instance.downloadObject(bucket, o.key);
    unawaited(future.then((bytes) {
      _recordRecent(o, bucket, imageBytes: bytes);
    }).catchError((_) {}));
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
          child: FutureBuilder<Uint8List>(
            future: future,
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
                    child: InteractiveViewer(
                      maxScale: 8,
                      child: Image.memory(bytes, fit: BoxFit.contain),
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

  /// Full-screen inline text/code viewer (#19). Mirrors [_previewMedia]:
  /// a snackbar while downloading, record the open (Recent strip #17),
  /// then show the viewer with the decrypted bytes.
  Future<void> _previewText(FulaObject o) async {
    _snack('Loading "${_displayName(o)}"…');
    try {
      final bucket = o.sourceBucket ?? widget.base;
      final bytes =
          await FulaApiService.instance.downloadObject(bucket, o.key);
      if (!mounted) return;
      final name = _displayName(o).split('/').last;
      _recordRecent(o, bucket);
      // Backstop the size cap: if the listing size was 0/unset a truly large
      // file would jank the viewer's decode/split, so download it instead.
      if (bytes.length > kMaxInlineTextBytes) {
        saveBytesAsDownload(name, bytes);
        return;
      }
      await showDialog<void>(
        context: context,
        useSafeArea: false,
        builder: (ctx) => Dialog.fullscreen(
          child: WebTextViewer(
            fileName: name,
            bytes: bytes,
            onDownload: () => saveBytesAsDownload(name, bytes),
          ),
        ),
      );
    } catch (e) {
      _snack('Preview failed: $e');
    }
  }

  /// Download + decrypt, then play via a blob URL fed to the HTML5
  /// media element (video_player / just_audio on web). Best-effort:
  /// codec support depends on the browser; the dialog offers Download
  /// as the fallback.
  Future<void> _previewMedia(FulaObject o) async {
    // Audio → the full-screen queue player (#21); video stays on Chewie.
    if (_isAudio(o)) {
      await _openAudioPlayer(o);
      return;
    }
    _snack('Loading "${_displayName(o)}"…');
    try {
      final bucket = o.sourceBucket ?? widget.base;
      final bytes =
          await FulaApiService.instance.downloadObject(bucket, o.key);
      _recordRecent(o, bucket);
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

  /// A player queue item for an audio object in this bucket (the controller
  /// downloads on demand, so nothing is fetched until it plays).
  WebAudioTrack _audioTrackFor(FulaObject o) {
    final bucket = o.sourceBucket ?? widget.base;
    return WebAudioTrack(
      name: _displayName(o).split('/').last,
      mime: _mediaMime(o),
      cloudKey: o.key,
      download: () => FulaApiService.instance.downloadObject(bucket, o.key),
    );
  }

  /// Open the full-screen audio player with a queue of every audio file in
  /// the current listing, starting at [tapped] (#21).
  Future<void> _openAudioPlayer(FulaObject tapped) async {
    final audio = (_objects ?? const <FulaObject>[]).where(_isAudio).toList();
    final tappedBucket = tapped.sourceBucket ?? widget.base;
    var start = audio.indexWhere((o) =>
        o.key == tapped.key &&
        (o.sourceBucket ?? widget.base) == tappedBucket);
    if (start < 0) {
      // Not in the current listing (e.g. a deep-open) — play it on its own.
      audio.insert(0, tapped);
      start = 0;
    }
    _recordRecent(tapped, tappedBucket);
    if (!mounted) return;
    // Start playback on the singleton, then open the (parameterless) player —
    // closing it just minimizes to the mini-player (s2). setExpanded is done
    // here (event context), not in the dialog's initState, to avoid notifying
    // the mini-player mid-build.
    final c = WebAudioController.instance;
    c.playQueue([for (final o in audio) _audioTrackFor(o)], start);
    c.setExpanded(true);
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (ctx) => const Dialog.fullscreen(child: WebAudioPlayer()),
    );
    c.setExpanded(false);
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
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            onPressed: (_objects == null) ? null : _showSortSheet,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed:
                _loading ? null : () => _load(force: true, hardRebuild: true),
          ),
        ],
      ),
      // Always enabled: the upload runs in the global manager, so the user
      // can queue more files (or navigate) while one is in flight. Live
      // progress shows in the shell-level upload tray, not here.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickAndUpload,
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload'),
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

