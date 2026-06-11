import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/ipns_pointer_service.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/core/services/website_service.dart';
import 'package:fula_files/core/utils/file_type_utils.dart' as file_utils;
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/websites/providers/website_provider.dart';
import 'package:fula_files/features/websites/screens/generate_website_screen.dart';
import 'package:fula_files/features/websites/widgets/generation_status_card.dart';
import 'package:fula_files/features/websites/widgets/legal_disclaimer_dialog.dart';
import 'package:fula_files/features/websites/widgets/tag_asset_picker_dialog.dart';
import 'package:fula_files/shared/utils/adaptive_ui.dart';
import 'package:fula_files/shared/utils/tagged_file_utils.dart';
import 'package:fula_files/shared/widgets/tagged_file_thumbnail.dart';

/// Detail screen for a single website: shows assets + generation history
class WebsiteDetailScreen extends ConsumerStatefulWidget {
  final String tagId;
  final FileTag? tag;

  const WebsiteDetailScreen({
    super.key,
    required this.tagId,
    this.tag,
  });

  @override
  ConsumerState<WebsiteDetailScreen> createState() =>
      _WebsiteDetailScreenState();
}

class _WebsiteDetailScreenState extends ConsumerState<WebsiteDetailScreen> {
  @override
  void initState() {
    super.initState();
    // WebsiteService.init() is fired non-blocking from main.dart. On cold
    // start with a direct route to this screen the box may not be open yet,
    // and a silent empty read of an asset comment followed by a single
    // keystroke would overwrite the persisted comment. Await init here and
    // rebuild once it's ready so the comment reads are safe.
    if (!WebsiteService.instance.isInitialized) {
      WebsiteService.instance.init().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tagState = ref.watch(tagProvider);
    final currentTag = widget.tag ??
        tagState.tags.where((t) => t.id == widget.tagId).firstOrNull;
    final displayName =
        (currentTag?.name ?? 'Website').replaceFirst('websites-', '');
    final tagColor =
        currentTag != null ? Color(currentTag.colorValue) : Colors.indigo;

    final taggedFilesAsync = ref.watch(taggedFilesProvider(widget.tagId));
    final generationsAsync =
        ref.watch(websiteGenerationsProvider(widget.tagId));

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: tagColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(displayName),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.plus),
            tooltip: 'Import items',
            onPressed: () => _showImportSheet(context),
          ),
        ],
      ),
      body: ListView(
        children: [
          // Section A: Assets
          _buildAssetsSection(context, taggedFilesAsync),

          // Section B: Generate button
          taggedFilesAsync.when(
            data: (files) {
              if (files.isEmpty) return const SizedBox.shrink();
              // M1: Disable button while generation is in-flight
              final isGenerating = ref.watch(websiteProvider
                  .select((s) => s.isGenerating));
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: FilledButton.icon(
                  onPressed: isGenerating
                      ? null
                      : () => _startPublishFlow(context, currentTag, files),
                  icon: const Icon(LucideIcons.sparkles),
                  label: Text(isGenerating ? 'Generating...' : 'Create Website'),
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),

          // Section C: Stable shareable link (per group, IPNS-backed)
          _buildStableLinkSection(context),

          // Section D: Generations history
          _buildGenerationsSection(context, generationsAsync, currentTag),
        ],
      ),
    );
  }

  // ============================================================================
  // STABLE LINK SECTION
  // ============================================================================

  /// The group's stable shareable link (IPNS-backed). Appears once the first
  /// generation has published a pointer; it always resolves to the group's
  /// latest generation, so the user shares it once and it never changes — and
  /// it keeps working even if fx's servers are down (the link is served by a
  /// Cloudflare Worker reading the free w3name service, and the content is
  /// fetched from public IPFS gateways — none of which is fx).
  Widget _buildStableLinkSection(BuildContext context) {
    final pointer = IpnsPointerService.instance.pointerFor(widget.tagId);
    if (pointer == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    if (!pointer.published) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation(muted),
              ),
            ),
            const SizedBox(width: 8),
            Text('Preparing shareable link…',
                style: TextStyle(fontSize: 12, color: muted)),
          ],
        ),
      );
    }

    final link = pointer.frontDoorUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.link, size: 15, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('Shareable link',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Always opens the latest version — share once, it never changes.',
              style: TextStyle(fontSize: 11, color: muted),
            ),
            const SizedBox(height: 8),
            SelectableText(
              link,
              maxLines: 2,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _shareStableLink(link),
                    icon: const Icon(LucideIcons.share2, size: 15),
                    label: const Text('Share'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copyStableLink(context, link),
                    icon: const Icon(LucideIcons.copy, size: 15),
                    label: const Text('Copy'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Open',
                  icon: const Icon(LucideIcons.externalLink, size: 16),
                  onPressed: () => _openStableLink(link),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareStableLink(String url) async {
    await SharePlus.instance.share(ShareParams(text: url));
  }

  Future<void> _copyStableLink(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied to clipboard')),
      );
    }
  }

  Future<void> _openStableLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ============================================================================
  // ASSETS SECTION
  // ============================================================================

  Widget _buildAssetsSection(
      BuildContext context, AsyncValue<List<TaggedFile>> taggedFilesAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                'Assets',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showImportSheet(context),
                icon: const Icon(LucideIcons.filePlus, size: 16),
                label: const Text('Import'),
              ),
            ],
          ),
        ),
        taggedFilesAsync.when(
          data: (files) {
            if (files.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Column(
                    children: [
                      Icon(LucideIcons.imageOff, size: 48, color: Colors.grey[400]),
                      const SizedBox(height: 12),
                      Text(
                        'No assets yet',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Import images, videos, or documents',
                        style: TextStyle(
                            color: Colors.grey[500], fontSize: 12),
                      ),
                    ],
                  ),
                ),
              );
            }

            // Don't render the asset tiles (each of which reads its
            // initialComment synchronously) until the comment-storage box
            // is open — otherwise a silent empty read followed by a single
            // keystroke would overwrite the user's previously-saved note.
            if (!WebsiteService.instance.isInitialized) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            // Build fallback URL map from generation assets
            final generations = ref.watch(websiteGenerationsProvider(widget.tagId));
            final fallbackUrls = <String, String>{};
            generations.whenData((gens) {
              for (final gen in gens) {
                for (final asset in gen.assets) {
                  if (asset.gatewayUrl != null && asset.gatewayUrl!.isNotEmpty) {
                    fallbackUrls[asset.fileName] = asset.gatewayUrl!;
                  }
                }
              }
            });

            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                return _AssetTile(
                  key: ValueKey('${widget.tagId}|${file.id}'),
                  taggedFile: file,
                  fallbackImageUrl: fallbackUrls[file.fileName],
                  initialComment: WebsiteService.instance
                          .getAssetComment(widget.tagId, file.id) ??
                      '',
                  onTap: () => openTaggedFile(context, file),
                  onRemove: () => _removeAsset(file),
                  onCommentChanged: (text) => WebsiteService.instance
                      .setAssetComment(widget.tagId, file.id, text),
                );
              },
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Error: $error'),
          ),
        ),
        const Divider(),
      ],
    );
  }

  // ============================================================================
  // GENERATIONS SECTION
  // ============================================================================

  Widget _buildGenerationsSection(
    BuildContext context,
    AsyncValue<List<WebsiteGeneration>> generationsAsync,
    FileTag? currentTag,
  ) {
    return generationsAsync.when(
      data: (generations) {
        if (generations.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Generation History',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            ...generations.map((gen) => GenerationStatusCard(
                  generation: gen,
                  onRetry: gen.status == WebsiteGenStatus.error
                      ? () => _retryGeneration(gen, currentTag)
                      : null,
                  onRecreate: gen.status == WebsiteGenStatus.completed
                      ? () => _recreateWithContext(gen, currentTag)
                      : null,
                )),
            const SizedBox(height: 80),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  // ============================================================================
  // IMPORT FLOW
  // ============================================================================

  void _showImportSheet(BuildContext context) {
    showAdaptiveSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Import Items',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(LucideIcons.image),
              title: const Text('Import Images'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFiles(FileType.image);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.video),
              title: const Text('Add Videos'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFiles(FileType.video);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.fileText),
              title: const Text('Add Documents'),
              onTap: () {
                Navigator.pop(ctx);
                _pickDocuments();
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.music),
              title: const Text('Add Audio'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFiles(FileType.audio);
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(LucideIcons.tag),
              title: const Text('Import from tag'),
              subtitle: const Text(
                'Pick a tag, then choose which of its files to include',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _importFromTag();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _importFromTag() async {
    final selected = await showTagAssetPicker(
      context: context,
      excludeTagId: widget.tagId,
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    // Tag each selected file with this website's tag, preserving whichever
    // identifiers (localPath / remoteKey / iosAssetId) the source TaggedFile
    // already carried. The existing taggedFilesProvider invalidation refreshes
    // the asset list, and the upload pipeline then picks them up the same way
    // it picks up freshly-imported files.
    int added = 0;
    for (final tf in selected) {
      try {
        await ref.tagFile(
          tagId: widget.tagId,
          localPath: tf.localPath,
          remoteKey: tf.remoteKey,
          iosAssetId: tf.iosAssetId,
          fileName: tf.fileName,
        );
        added++;
      } catch (e) {
        debugPrint('WebsiteDetail: failed to tag ${tf.fileName} into website: $e');
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $added file${added == 1 ? '' : 's'} from tag')),
      );
    }
  }

  Future<void> _pickFiles(FileType type) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: type,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      await _importPickedFiles(result.files);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick files: $e')),
        );
      }
    }
  }

  Future<void> _pickDocuments() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'pdf', 'txt', 'md', 'json', 'xml', 'yaml', 'yml',
          'doc', 'docx', 'csv', 'html', 'css', 'js', 'log',
        ],
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      await _importPickedFiles(result.files);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick documents: $e')),
        );
      }
    }
  }

  Future<void> _importPickedFiles(List<PlatformFile> files) async {
    final appDir = await getApplicationDocumentsDirectory();
    final importedDir = Directory(p.join(appDir.path, 'Imported'));
    if (!await importedDir.exists()) {
      await importedDir.create(recursive: true);
    }

    int imported = 0;
    for (final file in files) {
      if (file.path == null) continue;

      try {
        // Copy to app sandbox
        var destName = file.name;
        var destPath = p.join(importedDir.path, destName);
        var counter = 1;
        while (await File(destPath).exists()) {
          final baseName = p.basenameWithoutExtension(file.name);
          final ext = p.extension(file.name);
          destName = '$baseName ($counter)$ext';
          destPath = p.join(importedDir.path, destName);
          counter++;
        }

        await File(file.path!).copy(destPath);

        // Tag the file — store relative path on iOS to survive sandbox UUID changes
        final storedPath = Platform.isIOS ? 'Imported/$destName' : destPath;
        await ref.tagFile(
          tagId: widget.tagId,
          localPath: storedPath,
          fileName: destName,
        );
        imported++;
      } catch (e) {
        debugPrint('Failed to import ${file.name}: $e');
      }
    }

    if (mounted && imported > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported $imported file(s)')),
      );
    }
  }

  Future<void> _removeAsset(TaggedFile file) async {
    await WebsiteService.instance.deleteAssetComment(widget.tagId, file.id);
    await ref.untagFile(
      tagId: widget.tagId,
      localPath: file.localPath,
      remoteKey: file.remoteKey,
      iosAssetId: file.iosAssetId,
    );
  }

  /// Snapshot the current per-asset notes for the given [files] so the
  /// publish-flow preview reflects what the AI will see. Awaits the service
  /// init so a cold-start user who jumps straight into the publish flow
  /// doesn't see an empty preview when comments actually exist.
  Future<List<AssetNote>> _currentAssetNotes(List<TaggedFile> files) async {
    await WebsiteService.instance.init();
    final result = <AssetNote>[];
    for (final f in files) {
      final comment = WebsiteService.instance.getAssetComment(
        widget.tagId,
        f.id,
      );
      if (comment != null && comment.trim().isNotEmpty) {
        result.add((fileName: f.fileName, cid: null, comment: comment));
      }
    }
    return result;
  }

  // ============================================================================
  // PUBLISH FLOW
  // ============================================================================

  Future<void> _startPublishFlow(
    BuildContext context,
    FileTag? currentTag,
    List<TaggedFile> files,
  ) async {
    // Step 1: Legal disclaimer
    final accepted = await showLegalDisclaimerDialog(context);
    if (accepted != true || !mounted) return;

    // Step 2: Prompt input (with website name + category)
    final displayName =
        (currentTag?.name ?? 'website').replaceFirst('websites-', '');
    final assetNotes = await _currentAssetNotes(files);
    if (!mounted) return;
    final result = await _openGenerateScreen(
      context,
      displayName,
      assetNotes: assetNotes,
    );
    if (result == null || !mounted) return;

    // Step 3: Build enriched prompt and start generation
    final enrichedPrompt = _composeEnrichedPrompt(
      websiteName: result.websiteName,
      category: result.category,
      styles: result.styles,
      palette: result.palette,
      body: result.prompt,
      contactForm: result.contactForm,
    );
    await ref.read(websiteProvider.notifier).startGeneration(
          tagId: widget.tagId,
          tagName: displayName,
          prompt: enrichedPrompt,
          files: files,
          enableTracking: result.enableTracking,
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Website generation started')),
      );
    }
  }

  /// Compose the prompt that gets stored on the generation record.
  /// Header lines (Website Name, Category, optional Styles, Palette) are
  /// followed by a blank line and the user's body. Hidden category/style/
  /// palette instructions are added later by [WebsiteService] when calling
  /// the AI endpoint.
  String _composeEnrichedPrompt({
    required String websiteName,
    required String category,
    required List<String> styles,
    required String palette,
    required String body,
    ContactFormConfig? contactForm,
  }) =>
      // Single-sourced with the web shell in website_prompt_builder.dart.
      composeEnrichedWebsitePrompt(
        websiteName: websiteName,
        category: category,
        styles: styles,
        palette: palette,
        body: body,
        contactForm: contactForm,
      );

  Future<GenerateWebsitePromptResult?> _openGenerateScreen(
    BuildContext context,
    String defaultName, {
    String? initialName,
    String? initialCategory,
    List<String>? initialStyles,
    String? initialPalette,
    String? initialPrompt,
    bool initialEnableTracking = false,
    ContactFormConfig? initialContactForm,
    List<AssetNote> assetNotes = const [],
  }) {
    return Navigator.of(context).push<GenerateWebsitePromptResult>(
      MaterialPageRoute(
        builder: (_) => GenerateWebsiteScreen(
          defaultName: defaultName,
          initialName: initialName,
          initialCategory: initialCategory,
          initialStyles: initialStyles,
          initialPalette: initialPalette,
          initialPrompt: initialPrompt,
          initialEnableTracking: initialEnableTracking,
          initialContactForm: initialContactForm,
          assetNotes: assetNotes,
        ),
      ),
    );
  }

  void _retryGeneration(WebsiteGeneration gen, FileTag? currentTag) async {
    final files =
        await ref.read(taggedFilesProvider(widget.tagId).future);
    if (!mounted) return;

    final displayName =
        (currentTag?.name ?? 'website').replaceFirst('websites-', '');
    await ref.read(websiteProvider.notifier).startGeneration(
          tagId: widget.tagId,
          tagName: displayName,
          prompt: gen.prompt,
          files: files,
          enableTracking: gen.trackingEnabled,
        );
  }

  Future<void> _recreateWithContext(
      WebsiteGeneration gen, FileTag? currentTag) async {
    final accepted = await showLegalDisclaimerDialog(context);
    if (accepted != true || !mounted) return;

    final parsed = parseStoredPrompt(gen.prompt);
    final priorUrl = gen.gatewayUrl ?? '';
    final priorPromptForRef =
        parsed.userBody.isNotEmpty ? parsed.userBody : gen.prompt.trim();
    final seededPrompt =
        'The website "$priorUrl" was created for prompt: "$priorPromptForRef"\n\n'
        '[Describe what to change or add for the new version]';

    final displayName =
        (currentTag?.name ?? 'website').replaceFirst('websites-', '');

    final filesForNotes =
        await ref.read(taggedFilesProvider(widget.tagId).future);
    if (!mounted) return;
    final assetNotes = await _currentAssetNotes(filesForNotes);
    if (!mounted) return;

    final result = await _openGenerateScreen(
      context,
      displayName,
      initialName: parsed.websiteName,
      initialCategory: parsed.category,
      initialStyles: parsed.styles,
      initialPalette: parsed.palette,
      initialPrompt: seededPrompt,
      initialEnableTracking: gen.trackingEnabled,
      initialContactForm: parsed.contactForm,
      assetNotes: assetNotes,
    );
    if (result == null || !mounted) return;

    final files = await ref.read(taggedFilesProvider(widget.tagId).future);
    if (!mounted) return;

    final enrichedPrompt = _composeEnrichedPrompt(
      websiteName: result.websiteName,
      category: result.category,
      styles: result.styles,
      palette: result.palette,
      body: result.prompt,
      contactForm: result.contactForm,
    );
    await ref.read(websiteProvider.notifier).startGeneration(
          tagId: widget.tagId,
          tagName: displayName,
          prompt: enrichedPrompt,
          files: files,
          enableTracking: result.enableTracking,
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Website generation started')),
      );
    }
  }
}

// ============================================================================
// ASSET TILE WIDGET
// ============================================================================

class _AssetTile extends StatefulWidget {
  final TaggedFile taggedFile;
  final String? fallbackImageUrl;
  final String initialComment;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final ValueChanged<String> onCommentChanged;

  const _AssetTile({
    super.key,
    required this.taggedFile,
    this.fallbackImageUrl,
    required this.initialComment,
    required this.onTap,
    required this.onRemove,
    required this.onCommentChanged,
  });

  @override
  State<_AssetTile> createState() => _AssetTileState();
}

class _AssetTileState extends State<_AssetTile> {
  late final TextEditingController _commentController;

  @override
  void initState() {
    super.initState();
    _commentController = TextEditingController(text: widget.initialComment);
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                    child: Row(
                      children: [
                        TaggedFileThumbnail(
                          taggedFile: widget.taggedFile,
                          fallbackImageUrl: widget.fallbackImageUrl,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.taggedFile.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                file_utils.getFileTypeLabel(
                                    widget.taggedFile.fileName),
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(LucideIcons.x, size: 18),
                tooltip: 'Remove',
                onPressed: widget.onRemove,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: TextField(
              controller: _commentController,
              onChanged: widget.onCommentChanged,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Add a note (optional)',
                hintStyle:
                    TextStyle(fontSize: 13, color: Colors.grey[500]),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
              ),
              maxLines: 2,
              minLines: 1,
              textInputAction: TextInputAction.done,
            ),
          ),
        ],
      ),
    );
  }
}
