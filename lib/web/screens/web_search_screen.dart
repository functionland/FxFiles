import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';
import 'package:fula_files/web/services/web_search_logic.dart';

/// Global file search (#8), mirroring the mobile search icon (next to
/// settings). Web is cloud-only, so this enumerates every category's -v8
/// listing — the exact same listings the browse screens show. Web is
/// v8-only for categories by owner decision (2026-06-11; legacy buckets
/// carry a gc-damaged forest whose repair paths are native-only), so search
/// has identical coverage to browse; pre-v8 files stay reachable from the
/// mobile/desktop apps. Builds an in-memory index and name-filters as you
/// type. Tapping a result deep-opens the file via `/b/<base>?open=<key>`.
class WebSearchScreen extends StatefulWidget {
  const WebSearchScreen({super.key});

  @override
  State<WebSearchScreen> createState() => _WebSearchScreenState();
}

class _WebSearchScreenState extends State<WebSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<WebSearchEntry>? _index; // null while building
  // Per-category entries, so a background revalidation can patch ONE
  // category in place without clobbering the others. _index is the flat,
  // category-ordered view rebuilt from this.
  final Map<String, List<WebSearchEntry>> _byBase = {};
  String _query = '';

  // Category base → display label (mirrors WebBucketScreen.labels, which is
  // private to that screen's State). Drives which buckets the index covers.
  static const _categoryLabel = <String, String>{
    'images': 'Images',
    'videos': 'Videos',
    'audio': 'Audio',
    'documents': 'Documents',
    'downloads': 'Downloads',
    'archives': 'Archives',
  };

  static const _categoryIcon = <String, IconData>{
    'images': Icons.image_outlined,
    'videos': Icons.movie_outlined,
    'audio': Icons.audiotrack_outlined,
    'documents': Icons.description_outlined,
    'downloads': Icons.download_outlined,
    'archives': Icons.folder_zip_outlined,
  };

  @override
  void initState() {
    super.initState();
    _buildIndex();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _buildIndex() =>
      Future.wait(_categoryLabel.keys.map(_loadCategory));

  // Load ONE category into the index: apply the immediate SWR snapshot,
  // then — if the cache was stale/expired — patch in the fresher listing
  // when its revalidation lands. Mirrors web_bucket_screen._load. On a
  // cold miss the snapshot is itself the live listing (revalidation null);
  // on a stale/empty cache the revalidation is what makes a search run
  // before the category was opened reflect files added on another device.
  Future<void> _loadCategory(String base) async {
    final List<FulaObject> objects;
    final Future<({List<FulaObject> objects, bool offlineStale})?>? reval;
    try {
      final bucket = BucketVersionResolver.writeBucket(base);
      // Foreground-wrapped so the prefetch scheduler yields to this
      // user-initiated build.
      final listing = await WebForegroundActivity.instance
          .run(() => WebListingSwr.instance.getListing(bucket));
      objects = listing.objects;
      reval = listing.revalidation;
    } catch (_) {
      _apply(base, const []); // a failed category never breaks search
      return;
    }
    _apply(base, objects);
    if (reval == null) return;
    // Copy to a fresh non-nullable local: promotion from the null check
    // above doesn't flow into the run() closure when the variable was
    // assigned inside the try (vs. at its initializer).
    final pending = reval;
    final fresh = await WebForegroundActivity.instance.run(() => pending);
    if (fresh != null) _apply(base, fresh.objects);
  }

  // Store one category's non-directory objects as searchable entries and
  // rebuild the flat, category-ordered index the pure filter runs over.
  void _apply(String base, List<FulaObject> objects) {
    if (!mounted) return;
    setState(() {
      _byBase[base] = [
        for (final o in objects)
          if (!o.isDirectory) WebSearchEntry(base, o),
      ];
      _index = [for (final b in _categoryLabel.keys) ...?_byBase[b]];
    });
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value);
    });
  }

  void _open(WebSearchEntry e) {
    context.go('/b/${e.base}?open=${Uri.encodeComponent(e.object.key)}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = _index;
    final results = index == null ? const <WebSearchEntry>[]
        : searchEntries(index, _query);
    final trimmed = _query.trim();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search your files by name',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                _debounce?.cancel();
                setState(() => _query = '');
              },
            ),
        ],
      ),
      body: index == null
          ? const Center(child: CircularProgressIndicator())
          : trimmed.isEmpty
              ? _hint(theme, Icons.search,
                  'Search your files by name', 'Type to find files across all categories.')
              : results.isEmpty
                  ? _hint(theme, Icons.search_off, 'No results',
                      'Nothing matches "$trimmed".')
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final e = results[i];
                        return ListTile(
                          leading: Icon(_categoryIcon[e.base] ??
                              Icons.insert_drive_file_outlined),
                          title: Text(e.object.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_categoryLabel[e.base] ?? e.base),
                          onTap: () => _open(e),
                        );
                      },
                    ),
    );
  }

  Widget _hint(ThemeData theme, IconData icon, String title, String body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
