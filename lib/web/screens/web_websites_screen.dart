import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_website_service.dart';

/// Mirror of lib/features/websites/screens/websites_browser_screen.dart:
/// website GROUPS (websites- tags) with the globe tile, a New Website
/// create flow, and tap-through to the group detail screen (stable
/// link + generation history) — exactly like the app, instead of
/// launching a gateway URL directly.
class WebWebsitesScreen extends StatefulWidget {
  const WebWebsitesScreen({super.key});

  @override
  State<WebWebsitesScreen> createState() => _WebWebsitesScreenState();
}

class _WebWebsitesScreenState extends State<WebWebsitesScreen> {
  List<WebsiteGeneration> _generations = const [];
  Map<String, WebsiteGroupPointer> _pointers = const {};
  bool _loading = true;
  String? _error;

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
      await WebTagService.instance.load(force: true);
      final r = await WebFeatures.loadWebsites();
      setState(() {
        _generations = r.generations;
        _pointers = r.pointersByTag;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Website groups are `websites-` prefixed tags (native model). Tags
  /// referenced only by cloud generations (e.g. created on another
  /// device before tag sync) get a synthetic row so they still open.
  List<({String tagId, String name, int? colorValue})> get _groups {
    final out = <String, ({String tagId, String name, int? colorValue})>{};
    for (final t in WebTagService.instance.tags
        .where((t) => t.name.startsWith('websites-'))) {
      out[t.id] = (tagId: t.id, name: t.name, colorValue: t.colorValue);
    }
    for (final g in _generations) {
      out.putIfAbsent(g.tagId,
          () => (tagId: g.tagId, name: g.tagName, colorValue: null));
    }
    return out.values.toList();
  }

  String _displayName(String raw) =>
      raw.startsWith('websites-') ? raw.substring('websites-'.length) : raw;

  WebsiteGeneration? _latestFor(String tagId) {
    for (final g in _generations) {
      if (g.tagId == tagId) return g; // list is updatedAt-desc already
    }
    return null;
  }

  /// Stable front door first; otherwise the latest generation's
  /// dweb-gateway URL (g.gatewayUrl re-derives from the CID — never the
  /// raw legacy resultGatewayUrl).
  String? _liveUrl(String tagId) {
    final p = _pointers[tagId];
    if (p != null && p.published && p.frontDoorUrl.isNotEmpty) {
      return p.frontDoorUrl;
    }
    return _latestFor(tagId)?.gatewayUrl;
  }

  Future<void> _createWebsite() async {
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Website'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Website name',
            hintText: 'My Portfolio',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (value) => Navigator.of(ctx).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty || !mounted) return;
    try {
      final tag =
          await WebWebsiteService.instance.createWebsite(result.trim());
      if (mounted) context.go('/websites/${tag.id}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not create website: $e')));
      }
    }
  }

  Future<void> _deleteWebsite(
      ({String tagId, String name, int? colorValue}) group) async {
    final displayName = _displayName(group.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Website'),
        content: Text(
          'Are you sure you want to delete "$displayName"? '
          'This will remove the website and all generation history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await WebTagService.instance.deleteTag(group.tagId);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = _groups;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Websites'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createWebsite,
        child: const Icon(LucideIcons.plus),
      ),
      body: _error != null
          ? Center(child: Text('Could not load websites.\n$_error'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : groups.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(LucideIcons.globe,
                              size: 64, color: Colors.grey[400]),
                          const SizedBox(height: 16),
                          Text('No websites yet',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(color: Colors.grey[600])),
                          const SizedBox(height: 8),
                          Text('Create your first website',
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: Colors.grey[500])),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _createWebsite,
                            style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary),
                            icon: const Icon(LucideIcons.plus),
                            label: const Text('Create Website'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 80),
                      itemCount: groups.length,
                      itemBuilder: (ctx, i) {
                        final group = groups[i];
                        final color = group.colorValue != null
                            ? Color(group.colorValue!)
                            : theme.colorScheme.primary;
                        final latest = _latestFor(group.tagId);
                        final url = _liveUrl(group.tagId);
                        return ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: Icon(LucideIcons.globe, size: 20),
                            ),
                          ),
                          title: Text(_displayName(group.name),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            latest == null
                                ? 'No generations yet'
                                : url != null
                                    ? 'published'
                                    : latest.statusMessage ??
                                        'not published',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (url != null) ...[
                                IconButton(
                                  tooltip: 'Copy link',
                                  icon: const Icon(Icons.copy, size: 18),
                                  onPressed: () async {
                                    await Clipboard.setData(
                                        ClipboardData(text: url));
                                    if (ctx.mounted) {
                                      ScaffoldMessenger.of(ctx)
                                          .showSnackBar(const SnackBar(
                                              content: Text(
                                                  'Link copied to clipboard')));
                                    }
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Open website',
                                  icon: const Icon(Icons.open_in_new,
                                      size: 18),
                                  onPressed: () => launchUrl(
                                      Uri.parse(url),
                                      webOnlyWindowName: '_blank'),
                                ),
                              ],
                              PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'delete') {
                                    _deleteWebsite(group);
                                  }
                                },
                                itemBuilder: (ctx) => const [
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: () =>
                              context.go('/websites/${group.tagId}'),
                        );
                      },
                    ),
    );
  }
}
