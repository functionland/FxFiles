import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/utils/file_type_utils.dart';
import 'package:fula_files/web/services/web_recent_files_service.dart';
import 'package:fula_files/web/services/web_session.dart';
import 'package:fula_files/web/services/web_streaming_file.dart';
import 'package:fula_files/web/services/web_upload_manager.dart';

/// Web home "Recent" strip — mirror of the native
/// lib/features/home/widgets/recent_files_section.dart: a 120px-tall
/// horizontal list (max 10) of recently-opened cloud files. 80px media
/// cards (image thumbnail + gradient + filename, play badge for video)
/// and 100px doc cards (colored icon + filename). Hidden entirely when
/// there are no recents yet. Tapping a card reopens the file by routing
/// to its category with an `?open=<key>` param.
class WebRecentFilesSection extends StatefulWidget {
  const WebRecentFilesSection({super.key});

  @override
  State<WebRecentFilesSection> createState() => _WebRecentFilesSectionState();
}

class _WebRecentFilesSectionState extends State<WebRecentFilesSection> {
  List<WebRecentEntry> _items = const [];
  bool _loaded = false;

  /// True while a dragged file hovers the add tile (drives its highlight).
  bool _dragOverAddTile = false;

  /// Locates the add tile so a page-level drop can be hit-tested against it.
  final GlobalKey _addTileKey = GlobalKey();

  // Held so the document drag listeners can be removed on dispose.
  JSFunction? _onDragOver;
  JSFunction? _onDrop;
  JSFunction? _onDragLeave;

  @override
  void initState() {
    super.initState();
    // Rebuild on auth change: the whole strip (incl. the add tile) is
    // signed-in only, and a `const` parent rebuild wouldn't reach this widget
    // after an in-place (sheet) sign-in.
    WebSession.instance.addListener(_onAuthChanged);
    WebRecentFilesService.instance.addListener(_reload);
    _reload();
    _attachDropListeners();
  }

  @override
  void dispose() {
    WebSession.instance.removeListener(_onAuthChanged);
    WebRecentFilesService.instance.removeListener(_reload);
    _detachDropListeners();
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final items = await WebRecentFilesService.instance.list();
    if (!mounted) return;
    setState(() {
      _items = items.take(10).toList();
      _loaded = true;
    });
  }

  // ---- cross-category upload (tap the add tile, or drop a file onto it) ----

  Future<void> _pickAndUpload() async {
    // No accept filter — this tile takes ANY file and routes it by type.
    final picked = await pickFilesForUpload();
    _enqueueByCategory(picked);
  }

  /// Group files by their auto-detected category and enqueue one batch per
  /// category, each to that category's write bucket. The job's `base` carries
  /// the category so the upload tray can show "→ Images" etc. Rides the same
  /// streaming `enqueue` path as the per-category upload (no OOM regression).
  void _enqueueByCategory(List<WebPickedFile> files) {
    if (files.isEmpty) return;
    final byBase = <String, List<WebPickedFile>>{};
    for (final f in files) {
      (byBase[uploadCategoryBase(f.name)] ??= <WebPickedFile>[]).add(f);
    }
    byBase.forEach((base, group) {
      WebUploadManager.instance.enqueue(
        base: base,
        bucket: BucketVersionResolver.writeBucket(base),
        files: group,
      );
    });
  }

  // ---- tile-scoped drag & drop: document listeners + a per-event hit-test
  //      against the add tile's rect (no HtmlElementView → no platform-view
  //      compositing jank in the scrolling strip; the position test also makes
  //      dragenter/dragleave flicker bookkeeping unnecessary). ----

  void _attachDropListeners() {
    final over = ((web.Event e) {
      if (!mounted || !WebSession.instance.isSignedIn) return;
      // Page-wide preventDefault so a near-miss never makes the browser
      // navigate to the dropped file; we only UPLOAD when over the tile.
      e.preventDefault();
      final de = e as web.DragEvent;
      final isOver =
          _pointerOverAddTile(de.clientX.toDouble(), de.clientY.toDouble());
      if (isOver != _dragOverAddTile) {
        setState(() => _dragOverAddTile = isOver);
      }
    }).toJS;
    final drop = ((web.Event e) {
      if (!mounted || !WebSession.instance.isSignedIn) return;
      e.preventDefault();
      final de = e as web.DragEvent;
      final isOver =
          _pointerOverAddTile(de.clientX.toDouble(), de.clientY.toDouble());
      if (_dragOverAddTile) setState(() => _dragOverAddTile = false);
      if (isOver) _enqueueByCategory(filesFromDataTransfer(de.dataTransfer));
    }).toJS;
    final leave = ((web.Event e) {
      if (!mounted) return;
      // Clear the highlight only when the cursor leaves the WINDOW (crossing a
      // child element also fires dragleave — those are ignored).
      final de = e as web.DragEvent;
      final leftWindow = de.clientX <= 0 ||
          de.clientY <= 0 ||
          de.clientX >= web.window.innerWidth ||
          de.clientY >= web.window.innerHeight;
      if (leftWindow && _dragOverAddTile) {
        setState(() => _dragOverAddTile = false);
      }
    }).toJS;
    web.document.addEventListener('dragover', over);
    web.document.addEventListener('drop', drop);
    web.document.addEventListener('dragleave', leave);
    _onDragOver = over;
    _onDrop = drop;
    _onDragLeave = leave;
  }

  void _detachDropListeners() {
    if (_onDragOver != null) {
      web.document.removeEventListener('dragover', _onDragOver);
    }
    if (_onDrop != null) {
      web.document.removeEventListener('drop', _onDrop);
    }
    if (_onDragLeave != null) {
      web.document.removeEventListener('dragleave', _onDragLeave);
    }
  }

  /// Whether the viewport point (x, y) — a drag event's clientX/clientY in CSS
  /// px — is over the add tile. Assumes the standard full-page web app where the
  /// Flutter view sits at the viewport origin, so Flutter logical px
  /// (localToGlobal) line up with CSS px (devicePixelRatio / browser zoom scale
  /// both coordinate spaces together). A future embed via a custom hostElement
  /// or an offset <base> would need the host's offset subtracted here.
  bool _pointerOverAddTile(double x, double y) {
    final box = _addTileKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final origin = box.localToGlobal(Offset.zero);
    return (origin & box.size).contains(Offset(x, y));
  }

  @override
  Widget build(BuildContext context) {
    // The cross-category upload needs an authenticated cloud, so the whole
    // strip (incl. the add tile) is signed-in only. Logged out, the home shows
    // the login sheet/bar instead.
    if (!WebSession.instance.isSignedIn) return const SizedBox.shrink();

    final hasRecents = _loaded && _items.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasRecents)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Recent',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          )
        else
          const SizedBox(height: 8),
        SizedBox(
          // 30% taller than the original 120 (s1).
          height: 156,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            // +1 for the cross-category add tile pinned at the start.
            itemCount: _items.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return _AddTile(
                  key: _addTileKey,
                  dragOver: _dragOverAddTile,
                  onTap: _pickAndUpload,
                );
              }
              return _RecentCard(entry: _items[i - 1]);
            },
          ),
        ),
      ],
    );
  }
}

/// The cross-category quick-upload tile at the start of the home Recent strip.
/// Tap opens the file picker; dropping a file onto it (hit-tested by the
/// section's document listeners) uploads too. Same footprint as a recent card,
/// auto-routes by file type, and highlights while a file is dragged over it.
class _AddTile extends StatelessWidget {
  final bool dragOver;
  final VoidCallback onTap;
  const _AddTile({super.key, required this.dragOver, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Card(
      margin: const EdgeInsets.all(4),
      clipBehavior: Clip.antiAlias,
      color: dragOver ? color.withValues(alpha: 0.12) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: dragOver ? color : color.withValues(alpha: 0.4),
          width: dragOver ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 100,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, color: color, size: 30),
              const SizedBox(height: 6),
              Text(
                'Upload',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: color, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                dragOver ? 'Drop to add' : 'any file',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  final WebRecentEntry entry;
  const _RecentCard({required this.entry});

  bool get _isMedia => entry.isImage || entry.isVideo;

  IconData get _icon {
    if (entry.isImage) return LucideIcons.image;
    if (entry.isVideo) return LucideIcons.video;
    if (entry.isAudio) return LucideIcons.music;
    return LucideIcons.fileText;
  }

  Color get _iconColor {
    if (entry.isImage) return Colors.green;
    if (entry.isVideo) return Colors.red;
    if (entry.isAudio) return Colors.orange;
    return Colors.blue;
  }

  void _open(BuildContext context) {
    context.go('/b/${entry.base}?open=${Uri.encodeComponent(entry.key)}');
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: _isMedia ? 80 : 100,
          child: _isMedia ? _mediaCard() : _docCard(),
        ),
      ),
    );
  }

  Widget _mediaCard() {
    return Stack(
      fit: StackFit.expand,
      children: [
        entry.isImage && entry.hasThumb
            ? _RecentThumb(entry: entry, fallback: _placeholder())
            : _placeholder(),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: Text(
              entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ),
        ),
        if (entry.isVideo)
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child:
                  const Icon(LucideIcons.play, size: 14, color: Colors.white),
            ),
          ),
      ],
    );
  }

  Widget _placeholder() {
    return Container(
      color: _iconColor.withValues(alpha: 0.2),
      child: Center(child: Icon(_icon, color: _iconColor, size: 32)),
    );
  }

  Widget _docCard() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_icon, color: _iconColor, size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            entry.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Loads + caches one entry's decrypted thumbnail (decrypt once, not on
/// every rebuild).
class _RecentThumb extends StatefulWidget {
  final WebRecentEntry entry;
  final Widget fallback;
  const _RecentThumb({required this.entry, required this.fallback});

  @override
  State<_RecentThumb> createState() => _RecentThumbState();
}

class _RecentThumbState extends State<_RecentThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    WebRecentFilesService.instance.loadThumbnail(widget.entry).then((b) {
      if (!mounted) return;
      setState(() => _bytes = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    // Until loaded (and on failure) show the icon placeholder.
    if (bytes == null) return widget.fallback;
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => widget.fallback,
    );
  }
}
