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
import 'package:fula_files/features/websites/widgets/generation_status_card.dart';
import 'package:fula_files/features/websites/widgets/legal_disclaimer_dialog.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';

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

            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                return _AssetTile(
                  taggedFile: file,
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
    showModalBottomSheet(
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

        // Tag the file
        await ref.tagFile(
          tagId: widget.tagId,
          localPath: destPath,
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

    // Step 2: Prompt input
    final prompt = await _showPromptDialog(context);
    if (prompt == null || prompt.trim().isEmpty || !mounted) return;

    // Step 3: Start generation
    final displayName =
        (currentTag?.name ?? 'website').replaceFirst('websites-', '');
    await ref.read(websiteProvider.notifier).startGeneration(
          tagId: widget.tagId,
          tagName: displayName,
          prompt: prompt.trim(),
          files: files,
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Website generation started')),
      );
    }
  }

  Future<String?> _showPromptDialog(BuildContext context) async {
    final promptController = TextEditingController(
      text: 'Create a clean, modern portfolio website showcasing these assets with a gallery layout.',
    );

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generate Website'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: promptController,
              maxLines: 4,
              maxLength: 9000,
              decoration: const InputDecoration(
                labelText: 'Your creative direction',
                hintText: 'e.g. "A photography portfolio with dark theme and grid layout"',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Technical constraints (static site, IPFS hosting, responsive design) are added automatically.',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(promptController.text),
            child: const Text('Publish'),
          ),
        ],
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
}

// ============================================================================
// ASSET TILE WIDGET
// ============================================================================

class _AssetTile extends StatelessWidget {
  final TaggedFile taggedFile;
  final VoidCallback onRemove;

  const _AssetTile({
    required this.taggedFile,
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
    if (path == null) return _placeholder();

    final file = File(path);
    if (!file.existsSync()) return _placeholder();

    try {
      final stat = file.statSync();
      final localFile = LocalFile.fromFileSystemEntity(file, stat);
      return FileThumbnail(file: localFile, size: 48);
    } catch (_) {
      return _placeholder();
    }
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
