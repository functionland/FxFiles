import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/web/screens/web_generate_website_screen.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_website_service.dart';
import 'package:fula_files/web/widgets/media_preview_dialog.dart';

/// Mirror of lib/features/websites/screens/website_detail_screen.dart:
/// assets section (browser-picked files + per-asset notes), the Create
/// Website action, the stable shareable-link section (fxfiles.top
/// front door) and the generation history. Assets live in memory for
/// the session — the app's local-file import flows don't apply here.
class WebWebsiteDetailScreen extends StatefulWidget {
  final String tagId;
  const WebWebsiteDetailScreen({super.key, required this.tagId});

  @override
  State<WebWebsiteDetailScreen> createState() =>
      _WebWebsiteDetailScreenState();
}

class _WebWebsiteDetailScreenState extends State<WebWebsiteDetailScreen> {
  FileTag? _tag;
  List<WebsiteGeneration> _cloudGenerations = const [];
  WebsiteGroupPointer? _pointer;
  final List<WebPickedAsset> _assets = [];

  /// Group assets that exist only on a device (tagged files with no
  /// uploaded copy in any generation) — listed for awareness, but only
  /// the app can include them.
  List<String> _appOnlyAssets = const [];
  bool _assetsSeeded = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WebWebsiteService.instance.addListener(_onServiceTick);
    _load();
  }

  @override
  void dispose() {
    WebWebsiteService.instance.removeListener(_onServiceTick);
    super.dispose();
  }

  void _onServiceTick() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await WebTagService.instance.load();
      final r = await WebFeatures.loadWebsites();
      await WebIpnsService.instance.load(force: true);
      if (!mounted) return;
      setState(() {
        _tag = WebTagService.instance.tagById(widget.tagId);
        _cloudGenerations = r.generations
            .where((g) => g.tagId == widget.tagId)
            .toList();
        _pointer = WebIpnsService.instance.pointerFor(widget.tagId) ??
            r.pointersByTag[widget.tagId];
        _seedAssetsFromGroup();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// App parity: the group's existing assets show up and get REUSED by
  /// the next generation. The web sources them from the latest
  /// generation's uploaded assets (CID-backed — content is public on
  /// IPFS); group files that never uploaded are listed as app-only.
  void _seedAssetsFromGroup() {
    if (_assetsSeeded) return;
    _assetsSeeded = true;

    final latest = _generations
        .where((g) =>
            g.status == WebsiteGenStatus.completed && g.assets.isNotEmpty)
        .firstOrNull;
    final seededNames = <String>{};
    if (latest != null) {
      for (final a in latest.assets) {
        if (!a.uploaded || a.cid == null || a.cid!.isEmpty) continue;
        if (!seededNames.add(a.fileName)) continue;
        _assets.add(WebPickedAsset(
          fileName: a.fileName,
          cid: a.cid,
          gatewayUrl: a.gatewayUrl,
          note: a.comment ?? '',
        ));
      }
    }

    // Tagged files of this group with no uploaded counterpart =
    // device-local assets only the app can include.
    _appOnlyAssets = [
      for (final tf in WebTagService.instance.filesWithTag(widget.tagId))
        if (!seededNames.contains(tf.fileName) &&
            (tf.remoteKey == null || tf.remoteKey!.isEmpty))
          tf.fileName,
    ];
  }

  String get _displayName {
    final name = _tag?.name ?? 'website';
    return name.startsWith('websites-')
        ? name.substring('websites-'.length)
        : name;
  }

  /// Live (this session) + cloud generations, live wins by id.
  List<WebsiteGeneration> get _generations {
    final byId = <String, WebsiteGeneration>{};
    for (final g in WebWebsiteService.instance.liveGenerations
        .where((g) => g.tagId == widget.tagId)) {
      byId[g.id] = g;
    }
    for (final g in _cloudGenerations) {
      byId.putIfAbsent(g.id, () => g);
    }
    final list = byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  bool get _isGenerating => _generations.any((g) =>
      g.status == WebsiteGenStatus.uploading ||
      g.status == WebsiteGenStatus.parsing ||
      g.status == WebsiteGenStatus.generating);

  Future<void> _importAssets() async {
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      allowMultiple: true,
      type: FileType.any,
    );
    if (picked == null || picked.files.isEmpty) return;
    setState(() {
      for (final f in picked.files) {
        final data = f.bytes;
        if (data == null) continue;
        _assets.add(WebPickedAsset(fileName: f.name, bytes: data));
      }
    });
  }

  List<AssetNote> get _assetNotes => [
        for (final a in _assets)
          if (a.note.trim().isNotEmpty)
            (fileName: a.fileName, cid: a.cid, comment: a.note.trim()),
      ];

  Future<void> _publishFromResult(WebGeneratePromptResult result) async {
    final enrichedPrompt = composeEnrichedWebsitePrompt(
      websiteName: result.websiteName,
      category: result.category,
      styles: result.styles,
      palette: result.palette,
      body: result.prompt,
      contactForm: result.contactForm,
    );
    await WebWebsiteService.instance.startGeneration(
      tagId: widget.tagId,
      tagName: _displayName,
      prompt: enrichedPrompt,
      picked: List.of(_assets),
      enableTracking: result.enableTracking,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Website generation started')),
      );
    }
  }

  Future<void> _createWebsite() async {
    if (_assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Import images, videos, or documents first')));
      return;
    }
    final result =
        await Navigator.of(context).push<WebGeneratePromptResult>(
      MaterialPageRoute(
        builder: (_) => WebGenerateWebsiteScreen(
          defaultName: _displayName,
          assetNotes: _assetNotes,
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _publishFromResult(result);
  }

  /// Native Recreate parity: reopen the generator prefilled from the
  /// generation's parsed prompt, with the prior-site reference seeded
  /// into the creative direction; the group's current assets are
  /// reused on publish.
  Future<void> _recreate(WebsiteGeneration gen) async {
    final parsed = parseStoredWebsitePrompt(gen.prompt);
    final priorUrl = gen.gatewayUrl ?? '';
    final priorPromptForRef =
        parsed.userBody.isNotEmpty ? parsed.userBody : gen.prompt.trim();
    final seededPrompt =
        'The website "$priorUrl" was created for prompt: "$priorPromptForRef"\n\n'
        '[Describe what to change or add for the new version]';

    final result =
        await Navigator.of(context).push<WebGeneratePromptResult>(
      MaterialPageRoute(
        builder: (_) => WebGenerateWebsiteScreen(
          defaultName: _displayName,
          assetNotes: _assetNotes,
          initialName: parsed.websiteName,
          initialCategory: parsed.category,
          initialStyles: parsed.styles,
          initialPalette: parsed.palette,
          initialPrompt: seededPrompt,
          initialEnableTracking: gen.trackingEnabled,
          initialContactForm: parsed.contactForm,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (_assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'No reusable assets in this group — import files first')));
      return;
    }
    await _publishFromResult(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _tag != null ? Color(_tag!.colorValue) : null;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/websites'),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: 12,
                height: 12,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
            ],
            Text(_displayName),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load website.\n$_error'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _stableLinkSection(theme),
                        _assetsSection(theme),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed:
                                _isGenerating ? null : _createWebsite,
                            style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary),
                            icon: const Icon(LucideIcons.sparkles, size: 18),
                            label: Text(_isGenerating
                                ? 'Generating...'
                                : 'Create Website'),
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (_generations.isNotEmpty) ...[
                          Text('Generation History',
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          for (final g in _generations)
                            _GenerationCard(
                              generation: g,
                              onRecreate: g.status ==
                                          WebsiteGenStatus.completed &&
                                      !_isGenerating
                                  ? () => _recreate(g)
                                  : null,
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _stableLinkSection(ThemeData theme) {
    final pointer = _pointer ??
        WebIpnsService.instance.pointerFor(widget.tagId);
    if (pointer == null) return const SizedBox.shrink();

    if (!pointer.published) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primaryFaint,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Preparing shareable link…'),
          ],
        ),
      );
    }

    final link = pointer.frontDoorUrl;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primaryFaint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(LucideIcons.link, size: 16, color: AppColors.primary),
              SizedBox(width: 8),
              Text('Shareable link',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Always opens the latest version — share once, it never changes.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SelectableText(
            link,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(LucideIcons.copy, size: 14),
                label: const Text('Copy'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: link));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Link copied to clipboard')));
                },
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(LucideIcons.externalLink, size: 14),
                label: const Text('Open'),
                onPressed: () => launchUrl(Uri.parse(link),
                    webOnlyWindowName: '_blank'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _assetsSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Assets',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: _importAssets,
              icon: const Icon(LucideIcons.plus, size: 16),
              label: const Text('Import'),
            ),
          ],
        ),
        if (_assets.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                const Icon(LucideIcons.imageOff, size: 36),
                const SizedBox(height: 8),
                Text('No assets yet', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text('Import images, videos, or documents',
                    style: theme.textTheme.bodySmall),
              ],
            ),
          )
        else
          for (var i = 0; i < _assets.length; i++)
            _assetTile(theme, i),
        if (_appOnlyAssets.isNotEmpty) ...[
          const SizedBox(height: 4),
          for (final name in _appOnlyAssets)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.smartphone,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$name  ·  on a device — include it from the app',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  /// 44×44 leading visual: real thumbnail for images (picked bytes or
  /// the public gateway URL), a play tile for videos, a category icon
  /// otherwise.
  Widget _assetThumb(ThemeData theme, WebPickedAsset a) {
    Widget fallbackIcon(IconData icon) => Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 22),
        );

    if (a.type == 'image') {
      final bytes = a.bytes;
      final url = a.resolvedGatewayUrl;
      Widget? img;
      if (bytes != null) {
        img = Image.memory(bytes, width: 44, height: 44, fit: BoxFit.cover);
      } else if (url != null) {
        img = Image.network(
          url,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              fallbackIcon(Icons.image_outlined),
        );
      }
      if (img != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: img,
        );
      }
      return fallbackIcon(Icons.image_outlined);
    }
    if (a.type == 'video') {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
        ),
        child:
            const Icon(Icons.play_arrow, size: 24, color: Colors.white70),
      );
    }
    return fallbackIcon(switch (a.type) {
      'audio' => Icons.audiotrack_outlined,
      _ => Icons.description_outlined,
    });
  }

  /// Tap = double-check the asset: images preview in a dialog (with a
  /// download action), picked files download directly, CID-backed
  /// files open from the public gateway in a new tab.
  Future<void> _openAsset(WebPickedAsset a) async {
    final bytes = a.bytes;
    final url = a.resolvedGatewayUrl;

    if (a.type == 'image' && (bytes != null || url != null)) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: 900, maxHeight: 700),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(a.fileName, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Download',
                        icon: const Icon(Icons.download),
                        onPressed: () {
                          if (bytes != null) {
                            saveBytesAsDownload(a.fileName, bytes);
                          } else if (url != null) {
                            launchUrl(Uri.parse(url),
                                webOnlyWindowName: '_blank');
                          }
                        },
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
                    child: bytes != null
                        ? Image.memory(bytes, fit: BoxFit.contain)
                        : Image.network(url!, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
      return;
    }

    if (bytes != null) {
      if (a.type == 'video' || a.type == 'audio') {
        await showDialog<void>(
          context: context,
          builder: (ctx) => MediaPreviewDialog(
            title: a.fileName,
            bytes: bytes,
            mimeType: a.type == 'video' ? 'video/mp4' : 'audio/mpeg',
            isVideo: a.type == 'video',
          ),
        );
      } else {
        saveBytesAsDownload(a.fileName, bytes);
      }
      return;
    }
    if (url != null) {
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This asset has no openable copy.')));
  }

  Widget _assetTile(ThemeData theme, int index) {
    final a = _assets[index];
    final size = a.knownSize;
    return Card(
      key: ValueKey('${a.fileName}|${a.cid ?? 'picked-$index'}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          children: [
            InkWell(
              onTap: () => _openAsset(a),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  _assetThumb(theme, a),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(a.fileName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    size != null
                        ? '${(size / 1024).toStringAsFixed(0)} KB'
                        : 'from last generation',
                    style: theme.textTheme.bodySmall,
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(LucideIcons.x, size: 16),
                    onPressed: () =>
                        setState(() => _assets.removeAt(index)),
                  ),
                ],
              ),
            ),
            TextFormField(
              initialValue: a.note,
              decoration: const InputDecoration(
                hintText: 'Add a note (optional)',
                isDense: true,
                border: UnderlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12),
              onChanged: (v) => a.note = v,
            ),
          ],
        ),
      ),
    );
  }
}

/// Mirror of the native GenerationStatusCard (web subset: status header,
/// message, upload progress, completed URL + actions + Recreate,
/// analytics for tracked generations, error block, relative timestamp).
class _GenerationCard extends StatelessWidget {
  final WebsiteGeneration generation;
  final VoidCallback? onRecreate;
  const _GenerationCard({required this.generation, this.onRecreate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = generation;
    final (icon, color, label) = switch (g.status) {
      WebsiteGenStatus.uploading => (
          LucideIcons.upload,
          Colors.blue,
          'Uploading'
        ),
      WebsiteGenStatus.parsing => (
          LucideIcons.scan,
          Colors.orange,
          'Parsing'
        ),
      WebsiteGenStatus.generating => (
          LucideIcons.sparkles,
          Colors.purple,
          'Generating'
        ),
      WebsiteGenStatus.completed => (
          LucideIcons.checkCircle,
          Colors.green,
          'Completed'
        ),
      WebsiteGenStatus.error => (
          LucideIcons.alertCircle,
          Colors.red,
          'Error'
        ),
    };
    final active = g.status == WebsiteGenStatus.uploading ||
        g.status == WebsiteGenStatus.parsing ||
        g.status == WebsiteGenStatus.generating;
    final url = g.gatewayUrl;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.w600)),
                if (active) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                const Spacer(),
                Text(_relative(g.updatedAt),
                    style: theme.textTheme.bodySmall),
              ],
            ),
            if (g.statusMessage != null && g.statusMessage!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(g.statusMessage!, style: theme.textTheme.bodySmall),
            ],
            if (g.status == WebsiteGenStatus.uploading &&
                g.totalAssets > 0) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                  value: g.uploadedAssets / g.totalAssets),
              const SizedBox(height: 4),
              Text('${g.uploadedAssets}/${g.totalAssets} assets uploaded',
                  style: theme.textTheme.bodySmall),
            ],
            if (g.status == WebsiteGenStatus.completed && url != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(LucideIcons.globe,
                        size: 14, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        url,
                        maxLines: 2,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(LucideIcons.externalLink, size: 14),
                    label: const Text('Open'),
                    onPressed: () => launchUrl(Uri.parse(url),
                        webOnlyWindowName: '_blank'),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(LucideIcons.copy, size: 14),
                    label: const Text('Copy URL'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content:
                                  Text('Link copied to clipboard')));
                    },
                  ),
                  if (onRecreate != null)
                    OutlinedButton.icon(
                      icon: const Icon(LucideIcons.refreshCw, size: 14),
                      label: const Text('Recreate'),
                      onPressed: onRecreate,
                    ),
                ],
              ),
              // Click-tracking stats below the link (native parity:
              // shown only for generations created with tracking on).
              if (g.trackingEnabled &&
                  g.resultCid != null &&
                  g.resultCid!.isNotEmpty) ...[
                const SizedBox(height: 8),
                _AnalyticsRow(cid: g.resultCid!),
              ],
            ],
            if (g.status == WebsiteGenStatus.error &&
                g.errorMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.errorFaint,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.errorBorder),
                ),
                child: Text(
                  g.errorMessage!,
                  style:
                      const TextStyle(fontSize: 12, color: AppColors.error),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${t.day.toString().padLeft(2, '0')}/'
        '${t.month.toString().padLeft(2, '0')}/${t.year}';
  }
}

/// Click-tracking stats line for one generation — mirror of the native
/// card's analytics block: 'Loading analytics…' → 'X views · Y
/// visitors' (or 'Analytics unavailable'), with a refresh button.
class _AnalyticsRow extends StatefulWidget {
  final String cid;
  const _AnalyticsRow({required this.cid});

  @override
  State<_AnalyticsRow> createState() => _AnalyticsRowState();
}

class _AnalyticsRowState extends State<_AnalyticsRow> {
  ({int pageviews, int uniqueVisitors})? _stats;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    final stats =
        await WebWebsiteService.instance.fetchAnalytics(widget.cid);
    if (mounted) {
      setState(() {
        _stats = stats;
        _loading = false;
      });
    }
  }

  String _formatCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
    }
    return '${(n / 1000000).toStringAsFixed(n < 10000000 ? 1 : 0)}M';
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final Widget content;
    if (_loading) {
      content = Row(
        children: [
          const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Text('Loading analytics…',
              style: TextStyle(fontSize: 12, color: muted)),
        ],
      );
    } else if (_stats == null) {
      content = Text('Analytics unavailable',
          style: TextStyle(fontSize: 12, color: muted));
    } else {
      content = Text(
        '${_formatCount(_stats!.pageviews)} views · '
        '${_formatCount(_stats!.uniqueVisitors)} visitors',
        style: TextStyle(fontSize: 12, color: muted),
      );
    }
    return Row(
      children: [
        Icon(LucideIcons.barChart3, size: 14, color: muted),
        const SizedBox(width: 6),
        Expanded(child: content),
        IconButton(
          tooltip: 'Refresh analytics',
          iconSize: 14,
          visualDensity: VisualDensity.compact,
          icon: Icon(LucideIcons.refreshCw, size: 14, color: muted),
          onPressed: _loading ? null : _fetch,
        ),
      ],
    );
  }
}
