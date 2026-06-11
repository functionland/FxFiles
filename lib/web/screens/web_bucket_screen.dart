import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:chewie/chewie.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/share_token.dart' as share_model;
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/share_link_builder.dart';
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

  /// Web lists ONLY the category's -v8 bucket (owner decision,
  /// 2026-06-11): the legacy buckets carry the gc-damaged forest whose
  /// repair paths (404 forest-walk, forest backups) are native-only —
  /// touching them from wasm produces 404 floods, 410 write-guard hits
  /// and corrupt legacy reads. The fresh v8 sibling is the write target
  /// for every platform and is fully healthy. Pre-migration files stay
  /// reachable from the mobile/desktop apps.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final bucket = BucketVersionResolver.writeBucket(widget.base);
    try {
      final r = await FulaApiService.instance.listObjectsCached(bucket);
      final objects = r.objects
          .map((o) => o.withSourceBucket(bucket))
          .toList()
        ..sort((a, b) {
          final at = a.lastModified?.millisecondsSinceEpoch ?? 0;
          final bt = b.lastModified?.millisecondsSinceEpoch ?? 0;
          return bt.compareTo(at);
        });
      setState(() {
        _objects = objects;
        _stale = r.stale;
        _loading = false;
      });
    } catch (e) {
      // A category nobody has uploaded to yet has no -v8 bucket at all:
      // that's the empty state, not an error.
      final msg = '$e';
      if (msg.contains('NoSuchBucket') || msg.contains('bucket not found')) {
        setState(() {
          _objects = const [];
          _stale = false;
          _loading = false;
        });
        return;
      }
      setState(() {
        _error = msg;
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

  /// Create a 7-day public link for a single file. Mirrors the native
  /// SharingService.createPublicLink single-file path: disposable
  /// X25519 keypair, fula share token, v2 payload via the shared
  /// buildPublicShareUrl. (v1 web limitation: the link is not recorded
  /// locally, so revoke-before-expiry isn't available from the web UI.)
  Future<void> _share(FulaObject o) async {
    const expiryDays = 7;
    _snack('Creating public link…');
    try {
      final bucket = o.sourceBucket ?? widget.base;
      final storageKey = o.storageKey ?? o.key;
      final expiresAtUnix = DateTime.now()
              .add(const Duration(days: expiryDays))
              .millisecondsSinceEpoch ~/
          1000;

      final random = Random.secure();
      final privateKeyBytes = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        privateKeyBytes[i] = random.nextInt(256);
      }
      final publicKeyBytes = Uint8List.fromList(
        await fula.derivePublicKeyFromSecret(
            secretKeyBytes: privateKeyBytes.toList()),
      );

      final fulaToken = await FulaApiService.instance.createShareToken(
        bucket,
        storageKey,
        publicKeyBytes,
        share_model.ShareMode.temporal,
        expiresAtUnix,
      );

      final fileName = _displayName(o).split('/').last;
      final url = buildPublicShareUrl(
        baseUrl: kShareGatewayBaseUrl,
        tokenId: const Uuid().v4(),
        fulaToken: fulaToken,
        bucket: bucket,
        pathScope: o.key,
        storageKey: storageKey,
        linkSecretKey: privateKeyBytes,
        fileName: fileName,
      );

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Public link'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Anyone with this link can download '
                    '"$fileName" for $expiryDays days.'),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Theme.of(ctx).colorScheme.outline),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    url,
                    maxLines: 3,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
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
    } catch (e) {
      _snack('Could not create link: $e');
    }
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
        builder: (ctx) => _MediaPreviewDialog(
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
                    subtitle: Text([
                      _fmtSize(o.size),
                      if (o.lastModified != null)
                        '${o.lastModified!.toLocal()}'.split('.').first,
                    ].join('  ·  ')),
                    onTap: () => _preview(o),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'download') _download(o);
                        if (v == 'share') _share(o);
                        if (v == 'delete') _delete(o);
                      },
                      itemBuilder: (ctx) => const [
                        PopupMenuItem(
                          value: 'download',
                          child: Text('Download'),
                        ),
                        PopupMenuItem(
                          value: 'share',
                          child: Text('Copy public link'),
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

/// Plays decrypted bytes through the browser media stack: bytes -> Blob
/// object URL -> HTML5 <video>/<audio> (via video_player / just_audio).
/// Codec support is the browser's own; Download stays one click away.
class _MediaPreviewDialog extends StatefulWidget {
  final String title;
  final Uint8List bytes;
  final String mimeType;
  final bool isVideo;

  const _MediaPreviewDialog({
    required this.title,
    required this.bytes,
    required this.mimeType,
    required this.isVideo,
  });

  @override
  State<_MediaPreviewDialog> createState() => _MediaPreviewDialogState();
}

class _MediaPreviewDialogState extends State<_MediaPreviewDialog> {
  late final String _blobUrl =
      createBlobUrl(widget.bytes, mimeType: widget.mimeType);
  VideoPlayerController? _video;
  ChewieController? _chewie;
  AudioPlayer? _audio;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      if (widget.isVideo) {
        final video = VideoPlayerController.networkUrl(Uri.parse(_blobUrl));
        await video.initialize();
        _video = video;
        _chewie = ChewieController(
          videoPlayerController: video,
          autoPlay: true,
          looping: false,
        );
      } else {
        final audio = AudioPlayer();
        await audio.setUrl(_blobUrl);
        _audio = audio;
        unawaited(audio.play());
      }
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    _audio?.dispose();
    revokeBlobUrl(_blobUrl);
    super.dispose();
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(widget.title, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Download',
                    icon: const Icon(Icons.download),
                    onPressed: () => saveBytesAsDownload(
                      widget.title.split('/').last,
                      widget.bytes,
                      mimeType: widget.mimeType,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'This browser could not play the file '
                  '(${widget.mimeType}). Use Download instead.\n$_error',
                  textAlign: TextAlign.center,
                ),
              )
            else if (!_ready)
              const Padding(
                padding: EdgeInsets.all(48),
                child: CircularProgressIndicator(),
              )
            else if (widget.isVideo)
              Flexible(
                child: AspectRatio(
                  aspectRatio: _video!.value.aspectRatio == 0
                      ? 16 / 9
                      : _video!.value.aspectRatio,
                  child: Chewie(controller: _chewie!),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StreamBuilder<PlayerState>(
                      stream: _audio!.playerStateStream,
                      builder: (ctx, snap) {
                        final playing = snap.data?.playing ?? false;
                        return IconButton.filled(
                          iconSize: 36,
                          icon: Icon(
                              playing ? Icons.pause : Icons.play_arrow),
                          onPressed: () =>
                              playing ? _audio!.pause() : _audio!.play(),
                        );
                      },
                    ),
                    const SizedBox(width: 16),
                    StreamBuilder<Duration>(
                      stream: _audio!.positionStream,
                      builder: (ctx, snap) {
                        final pos = snap.data ?? Duration.zero;
                        final total = _audio!.duration ?? Duration.zero;
                        return Text(
                            '${_fmtDur(pos)} / ${_fmtDur(total)}');
                      },
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
