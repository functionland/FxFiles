import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/web/services/web_recent_files_service.dart';

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

  @override
  void initState() {
    super.initState();
    WebRecentFilesService.instance.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    WebRecentFilesService.instance.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await WebRecentFilesService.instance.list();
    if (!mounted) return;
    setState(() {
      _items = items.take(10).toList();
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Hidden until there's something to show (keeps a fresh home clean).
    if (!_loaded || _items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'Recent',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(
          // 30% taller than the original 120 (s1).
          height: 156,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _items.length,
            itemBuilder: (context, i) => _RecentCard(entry: _items[i]),
          ),
        ),
      ],
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
