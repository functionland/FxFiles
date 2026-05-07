import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/utils/file_type_utils.dart' as file_utils;
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/websites/providers/website_provider.dart';
import 'package:fula_files/features/websites/screens/generate_website_screen.dart';
import 'package:fula_files/features/websites/widgets/generation_status_card.dart';
import 'package:fula_files/features/websites/widgets/legal_disclaimer_dialog.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';
import 'package:fula_files/shared/utils/adaptive_ui.dart';

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

          // Section C: Generations history
          _buildGenerationsSection(context, generationsAsync, currentTag),
        ],
      ),
    );
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
                  taggedFile: file,
                  fallbackImageUrl: fallbackUrls[file.fileName],
                  onRemove: () => _removeAsset(file),
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
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
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
    await ref.untagFile(
      tagId: widget.tagId,
      localPath: file.localPath,
      remoteKey: file.remoteKey,
      iosAssetId: file.iosAssetId,
    );
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
    final result = await _openGenerateScreen(context, displayName);
    if (result == null || !mounted) return;

    // Step 3: Build enriched prompt and start generation
    final enrichedPrompt = _composeEnrichedPrompt(
      websiteName: result.websiteName,
      category: result.category,
      styles: result.styles,
      palette: result.palette,
      body: result.prompt,
    );
    await ref.read(websiteProvider.notifier).startGeneration(
          tagId: widget.tagId,
          tagName: displayName,
          prompt: enrichedPrompt,
          files: files,
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
  }) {
    final buffer = StringBuffer()
      ..writeln('Website Name: $websiteName')
      ..writeln('Category: $category');
    if (styles.isNotEmpty) {
      buffer.writeln('Styles: ${styles.join(', ')}');
    }
    if (palette.isNotEmpty) {
      buffer.writeln('Palette: $palette');
    }
    buffer
      ..writeln()
      ..write(body);
    return buffer.toString().trim();
  }

  Future<GenerateWebsitePromptResult?> _openGenerateScreen(
    BuildContext context,
    String defaultName, {
    String? initialName,
    String? initialCategory,
    List<String>? initialStyles,
    String? initialPalette,
    String? initialPrompt,
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

    final result = await _openGenerateScreen(
      context,
      displayName,
      initialName: parsed.websiteName,
      initialCategory: parsed.category,
      initialStyles: parsed.styles,
      initialPalette: parsed.palette,
      initialPrompt: seededPrompt,
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
    );
    await ref.read(websiteProvider.notifier).startGeneration(
          tagId: widget.tagId,
          tagName: displayName,
          prompt: enrichedPrompt,
          files: files,
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Website generation started')),
      );
    }
  }
}

// ============================================================================
// PATH RESOLUTION
// ============================================================================

/// Resolves a stored file path to a valid absolute path.
/// Handles relative paths (new iOS imports) and stale absolute paths
/// (old iOS imports where the sandbox UUID has changed).
Future<String> _resolveFilePath(String path) async {
  if (path.startsWith('/')) {
    if (File(path).existsSync()) return path; // absolute and valid
    // Try to recover: extract relative portion after "Documents/"
    final docsMarker = 'Documents/';
    final idx = path.indexOf(docsMarker);
    if (idx != -1) {
      final relativePart = path.substring(idx + docsMarker.length);
      final appDir = await getApplicationDocumentsDirectory();
      final resolved = p.join(appDir.path, relativePart);
      if (File(resolved).existsSync()) return resolved;
    }
    return path; // can't resolve, return original
  }
  // Relative path — resolve against documents dir
  final appDir = await getApplicationDocumentsDirectory();
  return p.join(appDir.path, path);
}

// ============================================================================
// ASSET TILE WIDGET
// ============================================================================

class _AssetTile extends StatelessWidget {
  final TaggedFile taggedFile;
  final String? fallbackImageUrl;
  final VoidCallback onRemove;

  const _AssetTile({
    required this.taggedFile,
    this.fallbackImageUrl,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _buildThumbnail(),
      title: Text(
        taggedFile.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _getTypeBadge(),
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
      ),
      trailing: IconButton(
        icon: const Icon(LucideIcons.x, size: 18),
        tooltip: 'Remove',
        onPressed: onRemove,
      ),
    );
  }

  Widget _buildThumbnail() {
    final path = taggedFile.localPath;
    if (path == null) return _fallbackOrPlaceholder();

    return FutureBuilder<String>(
      future: _resolveFilePath(path),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return _fallbackOrPlaceholder();
        final resolvedPath = snapshot.data!;
        final file = File(resolvedPath);
        if (!file.existsSync()) return _fallbackOrPlaceholder();
        try {
          final stat = file.statSync();
          final localFile = LocalFile.fromFileSystemEntity(file, stat);
          return FileThumbnail(file: localFile, size: 48);
        } catch (_) {
          return _fallbackOrPlaceholder();
        }
      },
    );
  }

  /// Try IPFS gateway URL fallback, otherwise show generic placeholder
  Widget _fallbackOrPlaceholder() {
    if (fallbackImageUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          fallbackImageUrl!,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(),
        ),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(LucideIcons.file, color: Colors.grey),
    );
  }

  String _getTypeBadge() {
    return file_utils.getFileTypeLabel(taggedFile.fileName);
  }
}
