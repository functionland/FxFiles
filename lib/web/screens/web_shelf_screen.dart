import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/widgets/media_preview_dialog.dart';

/// Mirror of lib/features/shelf/screens/shelf_screen.dart (view-only):
/// same grid metrics (180px cells, 0.70 aspect), tile anatomy
/// (thumbnail/category block, title, two-line description) and
/// empty-state copy. Capture/reorder/tagging stay native.
class WebShelfScreen extends StatefulWidget {
  const WebShelfScreen({super.key});

  @override
  State<WebShelfScreen> createState() => _WebShelfScreenState();
}

class _WebShelfScreenState extends State<WebShelfScreen> {
  List<ShelfItem>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // SWR: initial open serves the cached shelf manifest; Refresh/Retry
  // force the awaited live read.
  Future<void> _load({bool force = false}) async {
    setState(() {
      _items = null;
      _error = null;
    });
    try {
      final items = await WebFeatures.loadShelf(force: force);
      setState(() => _items = items);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  IconData _categoryIcon(ShelfItem item) =>
      switch (item.category.name) {
        'link' => Icons.link,
        'note' => Icons.sticky_note_2_outlined,
        'screenshot' => Icons.screenshot_monitor_outlined,
        'image' => Icons.image_outlined,
        'video' => Icons.movie_outlined,
        'audio' => Icons.audiotrack_outlined,
        'document' => Icons.description_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Future<void> _open(ShelfItem item) async {
    // Notes and links carry their text in the manifest itself. URLs in
    // the payload are clickable (native opens link items directly via
    // launchUrl — the web keeps the details popup but makes the link
    // tappable, plus an explicit Open Link action for link items).
    final text = (item.textPayload ?? '').trim();
    if (text.isNotEmpty) {
      final linkUri =
          item.category == ShelfCategory.link ? Uri.tryParse(text) : null;
      final openableLink = linkUri != null &&
          (linkUri.scheme == 'http' || linkUri.scheme == 'https');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(item.autoTitle ?? item.originalName,
              overflow: TextOverflow.ellipsis),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
            child: SingleChildScrollView(
              child: _LinkifiedText(text),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            if (openableLink)
              FilledButton.icon(
                onPressed: () => launchUrl(
                  linkUri,
                  webOnlyWindowName: '_blank',
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open Link'),
              ),
          ],
        ),
      );
      return;
    }
    if (item.remoteKey == null || item.remoteKey!.isEmpty) {
      _snack('This item has no cloud copy yet — open it in the app.');
      return;
    }
    _snack('Loading "${item.originalName}"…');
    try {
      final bytes = await WebFeatures.downloadShelfItem(item);
      final mime = item.mimeType ?? 'application/octet-stream';
      if (!mounted) return;
      if (mime.startsWith('image/')) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: 900, maxHeight: 700),
              child: InteractiveViewer(
                maxScale: 8,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
          ),
        );
      } else if (mime.startsWith('video/') || mime.startsWith('audio/')) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => MediaPreviewDialog(
            title: item.autoTitle ?? item.originalName,
            bytes: bytes,
            mimeType: mime,
            isVideo: mime.startsWith('video/'),
          ),
        );
      } else if (mime.startsWith('text/') || mime == 'application/json') {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(item.originalName, overflow: TextOverflow.ellipsis),
            content: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: 700, maxHeight: 520),
              child: SingleChildScrollView(
                child: SelectableText(utf8.decode(bytes,
                    allowMalformed: true)),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      } else {
        saveBytesAsDownload(item.originalName, bytes, mimeType: mime);
      }
    } catch (e) {
      _snack('Could not open: $e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Shelf'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(force: true),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 44),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text('Could not load the shelf.\n$_error',
                        textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: () => _load(force: true),
                      child: const Text('Retry')),
                ],
              ),
            )
          : _items == null
              ? const Center(child: CircularProgressIndicator())
              : _items!.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.inbox_outlined, size: 56),
                          const SizedBox(height: 12),
                          Text('No items yet',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: 6),
                          Text(
                            'Share content from any app to "Shelf" to '
                            'capture it here.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        childAspectRatio: 0.70,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: _items!.length,
                      itemBuilder: (ctx, i) {
                        final item = _items![i];
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _open(item),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.stretch,
                              children: [
                                AspectRatio(
                                  aspectRatio: 1,
                                  child: Container(
                                    color: theme.colorScheme
                                        .surfaceContainerHighest,
                                    child: Icon(
                                      _categoryIcon(item),
                                      size: 40,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.autoTitle ?? item.originalName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                                fontWeight:
                                                    FontWeight.w600),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        item.autoDescription ??
                                            '${_fmtSize(item.sizeBytes)} · ${item.category.name}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

/// Selectable text whose http(s) URLs are tappable — each opens in a
/// new tab. Used by the shelf details popup so captured links and
/// note-embedded links behave like links.
class _LinkifiedText extends StatefulWidget {
  final String text;
  const _LinkifiedText(this.text);

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  static final RegExp _urlPattern = RegExp(r'https?://[^\s]+');
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _urlPattern.allMatches(widget.text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      }
      final url = m.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap =
            () => launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
        recognizer: recognizer,
      ));
      last = m.end;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last)));
    }
    return SelectableText.rich(
      TextSpan(style: theme.textTheme.bodyMedium, children: spans),
    );
  }
}
