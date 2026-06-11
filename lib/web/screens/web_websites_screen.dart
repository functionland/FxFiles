import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';
import 'package:fula_files/web/services/web_features.dart';

/// Mirror of lib/features/websites/screens/websites_browser_screen.dart
/// (view-only): same row anatomy (globe leading, stripped display name,
/// count subtitle) and empty-state copy. Creation/generation stays
/// native; rows open or copy the live link (stable IPNS front door
/// when published, else the result CID gateway).
class WebWebsitesScreen extends StatefulWidget {
  const WebWebsitesScreen({super.key});

  @override
  State<WebWebsitesScreen> createState() => _WebWebsitesScreenState();
}

class _WebWebsitesScreenState extends State<WebWebsitesScreen> {
  List<WebsiteGeneration>? _generations;
  Map<String, WebsiteGroupPointer> _pointers = const {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _generations = null;
      _error = null;
    });
    try {
      final r = await WebFeatures.loadWebsites();
      setState(() {
        _generations = r.generations;
        _pointers = r.pointersByTag;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  String _displayName(WebsiteGeneration g) =>
      g.tagName.startsWith('websites-')
          ? g.tagName.substring('websites-'.length)
          : g.tagName;

  /// Stable front door first, then canonical IPNS gateway, then the
  /// generation's own CID gateway URL.
  String? _liveUrl(WebsiteGeneration g) {
    final p = _pointers[g.tagId];
    if (p != null && p.frontDoorUrl.isNotEmpty) return p.frontDoorUrl;
    if (g.resultGatewayUrl != null && g.resultGatewayUrl!.isNotEmpty) {
      return g.resultGatewayUrl;
    }
    if (g.resultCid != null && g.resultCid!.isNotEmpty) {
      return 'https://${g.resultCid}.ipfs.dweb.link/';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Latest generation per website group (tagId), like the native list.
    final latestByTag = <String, WebsiteGeneration>{};
    for (final g in _generations ?? const <WebsiteGeneration>[]) {
      latestByTag.putIfAbsent(g.tagId, () => g);
    }
    final rows = latestByTag.values.toList();

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
      body: _error != null
          ? Center(child: Text('Could not load websites.\n$_error'))
          : _generations == null
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.public, size: 64),
                          const SizedBox(height: 12),
                          Text('No websites yet',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: 6),
                          Text('Create your first website in the FxFiles app',
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 80),
                      itemCount: rows.length,
                      itemBuilder: (ctx, i) {
                        final g = rows[i];
                        final url = _liveUrl(g);
                        return ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer
                                  .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.public, size: 20),
                          ),
                          title: Text(_displayName(g),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${g.totalAssets} asset${g.totalAssets == 1 ? '' : 's'}'
                            '  ·  ${url != null ? 'published' : g.statusMessage ?? 'not published'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: url == null
                              ? null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
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
                                        webOnlyWindowName: '_blank',
                                      ),
                                    ),
                                  ],
                                ),
                          onTap: url == null
                              ? null
                              : () => launchUrl(Uri.parse(url),
                                  webOnlyWindowName: '_blank'),
                        );
                      },
                    ),
    );
  }
}
