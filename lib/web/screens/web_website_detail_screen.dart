import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/social_post_record.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/shared/widgets/ipfs_public_disclaimer_dialog.dart';
import 'package:fula_files/web/screens/web_generate_website_screen.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_streaming_file.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_website_asset_upload_logic.dart';
import 'package:fula_files/web/services/web_website_asset_uploader.dart';
import 'package:fula_files/web/services/web_website_assets_logic.dart';
import 'package:fula_files/web/services/web_social_post_service.dart';
import 'package:fula_files/web/services/web_website_service.dart';
import 'package:fula_files/web/widgets/web_social_post_section.dart';

/// Mirror of lib/features/websites/screens/website_detail_screen.dart:
/// assets section (imported files + per-asset notes), the Create
/// Website action, the stable shareable-link section (fxfiles.top
/// front door) and the generation history. Imports upload EAGERLY
/// (streamed from disk by the browser — never read into memory) and are
/// recorded as group members in the tag manifest, so they survive a
/// reload; the screen holds only names + CIDs + notes.
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

  /// Group files with a PRIVATE cloud copy (non-website-assets remoteKey)
  /// and no public CID — the app can include them, the web can't.
  List<String> _cloudOnlyAssets = const [];

  /// website-assets rows whose CID couldn't be resolved (LIST and HEAD
  /// both failed) — shown as warnings with a Remove action.
  final List<PendingCidWebsiteAsset> _unresolvedAssets = [];

  bool _assetsSeeded = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WebWebsiteService.instance.addListener(_onServiceTick);
    WebWebsiteAssetUploader.instance.addListener(_onUploaderTick);
    WebSocialPostService.instance.addListener(_onServiceTick);
    _load();
  }

  @override
  void dispose() {
    WebWebsiteService.instance.removeListener(_onServiceTick);
    WebWebsiteAssetUploader.instance.removeListener(_onUploaderTick);
    WebSocialPostService.instance.removeListener(_onServiceTick);
    for (final a in _assets) {
      _revokePreview(a);
    }
    super.dispose();
  }

  /// Release an adopted `blob:` preview URL (fresh imports) — they live
  /// until explicitly revoked, so removal/replacement/dispose must free
  /// them or every imported image leaks for the tab's lifetime.
  void _revokePreview(WebPickedAsset a) {
    final u = a.previewUrl;
    if (u != null && u.startsWith('blob:')) {
      try {
        web.URL.revokeObjectURL(u);
      } catch (_) {}
    }
  }

  void _onServiceTick() {
    if (mounted) setState(() {});
  }

  /// Fold completed upload jobs into the asset rows (byteless: name +
  /// CID + note + preview URL), then clear them from the queue.
  void _onUploaderTick() {
    if (!mounted) return;
    final done =
        WebWebsiteAssetUploader.instance.doneJobsForTag(widget.tagId);
    setState(() {
      for (final j in done) {
        for (final old in _assets.where((a) => a.fileName == j.fileName)) {
          _revokePreview(old); // replaced row's preview must not leak
        }
        _assets.removeWhere((a) => a.fileName == j.fileName);
        _unresolvedAssets.removeWhere((p) => p.fileName == j.fileName);
        _assets.add(WebPickedAsset(
          fileName: j.fileName,
          cid: j.cid,
          gatewayUrl: j.gatewayUrl,
          size: j.size,
          note: j.note,
          previewUrl: j.takePreviewUrl(),
        ));
      }
    });
    if (done.isNotEmpty) {
      WebWebsiteAssetUploader.instance.clearDone(widget.tagId);
    }
  }

  Future<void> _load() async {
    // Sidecar read + pending-job resume; fail-soft (the social section just
    // stays empty until it loads).
    unawaited(WebSocialPostService.instance.load());
    try {
      await WebTagService.instance.load();
      final r = await WebFeatures.loadWebsites();
      await WebIpnsService.instance.load(force: true);
      final tag = WebTagService.instance.tagById(widget.tagId);
      final rawName = tag?.name ?? 'website';
      final displayName = rawName.startsWith('websites-')
          ? rawName.substring('websites-'.length)
          : rawName;
      // Authoritative CID source (#44): assets that reached IPFS but whose
      // generation recorded uploaded=false/no-CID. Fail-soft → {}.
      final assetCids = await WebFeatures.websiteAssetCids(displayName);
      if (!mounted) return;
      setState(() {
        _tag = tag;
        _cloudGenerations = r.generations
            .where((g) => g.tagId == widget.tagId)
            .toList();
        _pointer = WebIpnsService.instance.pointerFor(widget.tagId) ??
            r.pointersByTag[widget.tagId];
        _seedAssetsFromGroup(assetCids);
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

  /// App parity: the group's existing assets show up and get REUSED by the
  /// next generation. A group file is reusable on web when it has a public
  /// IPFS CID from ANY completed generation (content is public on IPFS); a
  /// file with no CID in any generation AND no cloud copy is device-local
  /// and listed as app-only.
  ///
  /// Resolving the CID-backed set from the UNION of all completed generations
  /// (not just the latest) is the fix for issue #44: per-run upload caps and
  /// transient failures mean the freshest generation can be missing assets an
  /// earlier run uploaded successfully, which the old latest-only code wrongly
  /// flagged "on a device". Scoping to the group's CURRENT tagged files avoids
  /// resurrecting files the user later removed. (Tags are loaded in `_load`
  /// before this runs.)
  void _seedAssetsFromGroup(Map<String, String> websiteAssetCids) {
    if (_assetsSeeded) return;
    _assetsSeeded = true;

    // CIDs from two sources: the generation manifest (union across all
    // completed generations) and — authoritatively — the website-assets
    // bucket, which records what actually reached IPFS even when the
    // manifest saved uploaded=false/no-CID (issue #44). The bucket wins.
    final cidByName = mergeAuthoritativeCids(
      websiteCidAssetsByName(_generations),
      websiteAssetCids,
    );
    final tagged = [
      for (final tf in WebTagService.instance.filesWithTag(widget.tagId))
        (id: tf.id, fileName: tf.fileName, remoteKey: tf.remoteKey),
    ];
    final resolved =
        resolveWebsiteGroupAssets(taggedFiles: tagged, cidByName: cidByName);
    for (final a in resolved.reusable) {
      _assets.add(WebPickedAsset(
        fileName: a.fileName,
        cid: a.cid,
        gatewayUrl: a.gatewayUrl,
        note: a.note,
        taggedFileId: a.taggedFileId,
        parsedContent: a.parsedContent,
      ));
    }
    _appOnlyAssets = resolved.appOnly;
    _cloudOnlyAssets = resolved.cloudOnly;
    // website-assets rows the LIST didn't cover (failed/lagged): resolve
    // each via HEAD instead of dropping them — the sharp edge that used
    // to make web-imported assets vanish.
    if (resolved.pendingCid.isNotEmpty) {
      unawaited(_resolvePendingCids(resolved.pendingCid));
    }
  }

  Future<void> _resolvePendingCids(
      List<PendingCidWebsiteAsset> pending) async {
    for (final p in pending) {
      final cid = await WebFeatures.websiteAssetCidByHead(p.objectKey);
      if (!mounted) return;
      setState(() {
        if (cid != null && cid.isNotEmpty) {
          _assets.removeWhere((a) => a.fileName == p.fileName);
          _assets.add(WebPickedAsset(
            fileName: p.fileName,
            cid: cid,
            taggedFileId: p.taggedFileId,
          ));
        } else {
          _unresolvedAssets.add(p);
        }
      });
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

  /// Known bytes already committed to the group (ready assets + jobs
  /// still in flight) — feeds the aggregate import cap. Best-effort:
  /// assets seeded from a reload don't know their size (counted as 0),
  /// so the cap is permissive across sessions; the backend mirrors the
  /// hard limits as defence in depth.
  int get _knownGroupBytes {
    var total = 0;
    for (final a in _assets) {
      total += a.size ?? 0;
    }
    for (final j in WebWebsiteAssetUploader.instance.jobsForTag(widget.tagId)) {
      if (j.isActive) total += j.size;
    }
    return total;
  }

  /// Pick WITHOUT reading (lazily-readable Blob handles) and hand off to
  /// the eager uploader: caps validated from metadata before any byte
  /// moves, then each file streams from disk via a Blob-body PUT. The
  /// tab's heap stays flat no matter how large the files are.
  Future<void> _importAssets() async {
    final files = await pickFilesForUpload();
    if (files.isEmpty || !mounted) return;
    final r = WebWebsiteAssetUploader.instance.enqueue(
      tagId: widget.tagId,
      websiteName: _displayName,
      files: files,
      groupKnownBytes: _knownGroupBytes,
    );
    if (r.rejectedReasons.isNotEmpty && mounted) {
      final reasons = r.rejectedReasons;
      final summary = reasons.length <= 3
          ? reasons.join('\n')
          : '${reasons.take(3).join('\n')}\n(+${reasons.length - 3} more)';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(summary)));
    }
    setState(() {});
  }

  /// Real removal: drop the tag-manifest membership row (by row id when
  /// known, else by the website-assets remoteKey). The bucket object is
  /// NEVER deleted — it's content-addressed and may be referenced by
  /// earlier generations' live sites.
  Future<void> _removeAsset(int index) async {
    final a = _assets[index];
    _revokePreview(a);
    setState(() => _assets.removeAt(index));
    try {
      if (a.taggedFileId != null) {
        await WebTagService.instance.removeTaggedFile(a.taggedFileId!);
      } else {
        await WebTagService.instance.untagFile(
          tagId: widget.tagId,
          remoteKey: websiteAssetRemoteKey(_displayName, a.fileName),
        );
      }
    } catch (e) {
      debugPrint('Asset untag failed (row may not exist yet): $e');
    }
  }

  List<AssetNote> get _assetNotes => [
        for (final a in _assets)
          if (a.note.trim().isNotEmpty)
            (fileName: a.fileName, cid: a.cid, comment: a.note.trim()),
      ];

  /// Assets eligible for generation: CID-backed (public on IPFS).
  List<WebPickedAsset> get _readyAssets =>
      [for (final a in _assets) if (a.isCidBacked) a];

  Future<void> _publishFromResult(WebGeneratePromptResult result) async {
    final enrichedPrompt = composeEnrichedWebsitePrompt(
      websiteName: result.websiteName,
      category: result.category,
      styles: result.styles,
      languages: result.languages,
      palette: result.palette,
      body: result.prompt,
      contactForm: result.contactForm,
    );
    await WebWebsiteService.instance.startGeneration(
      tagId: widget.tagId,
      tagName: _displayName,
      prompt: enrichedPrompt,
      picked: List.of(_readyAssets),
      enableTracking: result.enableTracking,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Website generation started')),
      );
    }
  }

  Future<void> _createWebsite() async {
    if (WebWebsiteAssetUploader.instance.hasActiveJobs(widget.tagId)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Assets are still uploading — one moment')));
      return;
    }
    if (_readyAssets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Import images, videos, or documents first')));
      return;
    }
    // Public-content disclaimer before the form, matching the native
    // app's step-1 placement (assets + generated site are public IPFS).
    final accepted = await showIpfsPublicDisclaimerDialog(context);
    if (accepted != true || !mounted) return;
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

  /// Send this generation's assets + prompt + public URL to the AI
  /// backend for a 4:5 social image + captions. Disclaimer (public
  /// content) and FULA price share one confirm dialog.
  Future<void> _createSocialPosts(WebsiteGeneration gen) async {
    if (WebSocialPostService.instance.isGenerating(gen.id)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('A social post is already being generated')));
      return;
    }
    final price = await WebSocialPostService.instance.fetchSocialPricing();
    if (!mounted) return;
    final accepted = await showIpfsPublicDisclaimerDialog(
      context,
      variant: PublicDisclaimerVariant.social,
      footnote: price != null
          ? 'Cost: $price FULA (1 image + captions)'
          : 'Charged at the current social-post rate (1 image + captions)',
    );
    if (accepted != true || !mounted) return;
    final pointer =
        _pointer ?? WebIpnsService.instance.pointerFor(widget.tagId);
    try {
      await WebSocialPostService.instance.startGeneration(
        generation: gen,
        frontDoorUrl: pointer?.frontDoorUrl,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Social post generation started')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  /// Native Recreate parity: reopen the generator prefilled from the
  /// generation's parsed prompt, with the prior-site reference seeded
  /// into the creative direction; the group's current assets are
  /// reused on publish.
  Future<void> _recreate(WebsiteGeneration gen) async {
    // Same public-content acknowledgement as Create Website (native parity).
    final accepted = await showIpfsPublicDisclaimerDialog(context);
    if (accepted != true || !mounted) return;
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
          initialLanguages: parsed.languages,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (_readyAssets.isEmpty) {
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
                          child: Builder(builder: (context) {
                            final uploading = WebWebsiteAssetUploader
                                .instance
                                .hasActiveJobs(widget.tagId);
                            return FilledButton.icon(
                              onPressed: (_isGenerating || uploading)
                                  ? null
                                  : _createWebsite,
                              style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.primary),
                              icon:
                                  const Icon(LucideIcons.sparkles, size: 18),
                              label: Text(_isGenerating
                                  ? 'Generating...'
                                  : uploading
                                      ? 'Uploading assets…'
                                      : 'Create Website'),
                            );
                          }),
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
                              socialRecord: WebSocialPostService.instance
                                  .recordFor(g.id),
                              onCreateSocial: g.status ==
                                      WebsiteGenStatus.completed
                                  ? () => _createSocialPosts(g)
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
    final jobs = WebWebsiteAssetUploader.instance.jobsForTag(widget.tagId);
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
        for (final j in jobs) _uploadJobTile(theme, j),
        if (_assets.isEmpty && jobs.isEmpty)
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
        for (final p in List.of(_unresolvedAssets))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${p.fileName}  ·  not reachable right now — refresh, '
                    'or remove and import again',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(LucideIcons.x, size: 14),
                  onPressed: () async {
                    setState(() => _unresolvedAssets.remove(p));
                    try {
                      await WebTagService.instance
                          .removeTaggedFile(p.taggedFileId);
                    } catch (_) {}
                  },
                ),
              ],
            ),
          ),
        if (_appOnlyAssets.isNotEmpty || _cloudOnlyAssets.isNotEmpty) ...[
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
          for (final name in _cloudOnlyAssets)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.cloud_outlined,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$name  ·  in your cloud — include it from the app',
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

  /// One in-flight / failed upload row: name + progress bar (or error) +
  /// cancel / retry.
  Widget _uploadJobTile(ThemeData theme, WebsiteAssetUploadJob j) {
    final failed = j.status == WebsiteAssetUploadStatus.failed;
    final cancelled = j.status == WebsiteAssetUploadStatus.cancelled;
    return Card(
      key: ValueKey('upload-${j.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: failed || cancelled
                  ? Icon(Icons.error_outline,
                      color: failed
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant)
                  : Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        value: j.progress > 0 ? j.progress : null,
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(j.fileName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  if (failed)
                    Text(j.error ?? 'Upload failed',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error))
                  else if (cancelled)
                    Text('Cancelled', style: theme.textTheme.bodySmall)
                  else
                    LinearProgressIndicator(
                        value: j.progress > 0 ? j.progress : null),
                ],
              ),
            ),
            if (failed)
              IconButton(
                tooltip: 'Retry',
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                onPressed: () =>
                    WebWebsiteAssetUploader.instance.retry(j.id),
              ),
            IconButton(
              tooltip: j.isActive ? 'Cancel' : 'Dismiss',
              icon: const Icon(LucideIcons.x, size: 16),
              onPressed: () => j.isActive
                  ? WebWebsiteAssetUploader.instance.cancel(j.id)
                  : WebWebsiteAssetUploader.instance.dismiss(j.id),
            ),
          ],
        ),
      ),
    );
  }

  /// 44×44 leading visual: real thumbnail for images (session preview
  /// URL for fresh imports — bridges gateway propagation lag — else the
  /// public gateway URL), a play tile for videos, a category icon
  /// otherwise. Never bytes.
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
      final url = a.previewUrl ?? a.resolvedGatewayUrl;
      if (url != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            url,
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                fallbackIcon(Icons.image_outlined),
          ),
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

  /// Tap = double-check the asset: images preview in a dialog; everything
  /// else opens from the public gateway in a new tab.
  Future<void> _openAsset(WebPickedAsset a) async {
    final gatewayUrl = a.resolvedGatewayUrl;

    if (a.type == 'image') {
      final viewUrl = a.previewUrl ?? gatewayUrl;
      if (viewUrl != null) {
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
                    title:
                        Text(a.fileName, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (gatewayUrl != null)
                          IconButton(
                            tooltip: 'Open on IPFS',
                            icon: const Icon(Icons.download),
                            onPressed: () => launchUrl(
                                Uri.parse(gatewayUrl),
                                webOnlyWindowName: '_blank'),
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
                      child: Image.network(viewUrl, fit: BoxFit.contain),
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
    }

    if (gatewayUrl != null) {
      await launchUrl(Uri.parse(gatewayUrl), webOnlyWindowName: '_blank');
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
                    onPressed: () => _removeAsset(index),
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

  /// Social-post state for this generation (null = never generated); the
  /// launch button lives in the action Wrap only until a record exists —
  /// after that the section below owns status/result/recreate.
  final SocialPostRecord? socialRecord;
  final VoidCallback? onCreateSocial;

  const _GenerationCard({
    required this.generation,
    this.onRecreate,
    this.socialRecord,
    this.onCreateSocial,
  });

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
                  if (onCreateSocial != null && socialRecord == null)
                    OutlinedButton.icon(
                      icon: const Icon(LucideIcons.megaphone, size: 14),
                      label: const Text('Create Social Posts'),
                      onPressed: onCreateSocial,
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
              WebSocialPostSection(
                generationId: g.id,
                tagName: g.tagName,
                onCreateSocial: onCreateSocial,
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
