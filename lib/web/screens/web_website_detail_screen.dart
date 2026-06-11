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
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_website_service.dart';

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

  Future<void> _createWebsite() async {
    if (_assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Import images, videos, or documents first')));
      return;
    }
    final assetNotes = <AssetNote>[
      for (final a in _assets)
        if (a.note.trim().isNotEmpty)
          (fileName: a.fileName, cid: null, comment: a.note.trim()),
    ];
    final result =
        await Navigator.of(context).push<WebGeneratePromptResult>(
      MaterialPageRoute(
        builder: (_) => WebGenerateWebsiteScreen(
          defaultName: _displayName,
          assetNotes: assetNotes,
        ),
      ),
    );
    if (result == null || !mounted) return;

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
                            _GenerationCard(generation: g),
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
      ],
    );
  }

  Widget _assetTile(ThemeData theme, int index) {
    final a = _assets[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  switch (a.type) {
                    'image' => Icons.image_outlined,
                    'video' => Icons.movie_outlined,
                    'audio' => Icons.audiotrack_outlined,
                    _ => Icons.description_outlined,
                  },
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(a.fileName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Text(
                  '${(a.bytes.length / 1024).toStringAsFixed(0)} KB',
                  style: theme.textTheme.bodySmall,
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(LucideIcons.x, size: 16),
                  onPressed: () => setState(() => _assets.removeAt(index)),
                ),
              ],
            ),
            TextField(
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
/// message, upload progress, completed URL + actions, error block,
/// relative timestamp).
class _GenerationCard extends StatelessWidget {
  final WebsiteGeneration generation;
  const _GenerationCard({required this.generation});

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
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(LucideIcons.externalLink, size: 14),
                    label: const Text('Open'),
                    onPressed: () => launchUrl(Uri.parse(url),
                        webOnlyWindowName: '_blank'),
                  ),
                  const SizedBox(width: 8),
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
                ],
              ),
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
