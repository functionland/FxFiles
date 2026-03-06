import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/features/nft/providers/nft_provider.dart';
import 'package:fula_files/features/nft/widgets/nft_card.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';

/// Detail screen for a single NFT collection: shows assets + minted NFTs
class NftDetailScreen extends ConsumerStatefulWidget {
  final String tagId;
  final FileTag? tag;

  const NftDetailScreen({
    super.key,
    required this.tagId,
    this.tag,
  });

  @override
  ConsumerState<NftDetailScreen> createState() => _NftDetailScreenState();
}

class _NftDetailScreenState extends ConsumerState<NftDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final tagState = ref.watch(tagProvider);
    final currentTag = widget.tag ??
        tagState.tags.where((t) => t.id == widget.tagId).firstOrNull;
    final displayName =
        (currentTag?.name ?? 'NFT Collection').replaceFirst('nft-', '');
    final tagColor =
        currentTag != null ? Color(currentTag.colorValue) : Colors.pink;

    final taggedFilesAsync = ref.watch(taggedFilesProvider(widget.tagId));
    final mintsAsync = ref.watch(nftMintsProvider(widget.tagId));

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
            tooltip: 'Import images',
            onPressed: () => _pickImages(),
          ),
        ],
      ),
      body: ListView(
        children: [
          // Section A: Assets
          _buildAssetsSection(context, taggedFilesAsync),

          // Section B: Mint button (Phase 2 — disabled for now)
          taggedFilesAsync.when(
            data: (files) {
              if (files.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: FilledButton.icon(
                  onPressed: null, // Enabled in Phase 2 when contract is deployed
                  icon: const Icon(LucideIcons.sparkles),
                  label: const Text('Mint NFTs'),
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),

          // Section C: Minted NFTs
          _buildMintsSection(context, mintsAsync),
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
                onPressed: () => _pickImages(),
                icon: const Icon(LucideIcons.imagePlus, size: 16),
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
                        'Import images to mint as NFTs',
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
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
                return _NftAssetTile(
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
  // MINTED NFTS SECTION
  // ============================================================================

  Widget _buildMintsSection(
      BuildContext context, AsyncValue<List<NftMintRecord>> mintsAsync) {
    return mintsAsync.when(
      data: (mints) {
        if (mints.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Minted NFTs',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            ...mints.map((mint) => NftCard(record: mint)),
            const SizedBox(height: 80),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  // ============================================================================
  // IMPORT FLOW (images only for NFTs)
  // ============================================================================

  Future<void> _pickImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      await _importPickedFiles(result.files);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick images: $e')),
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
        SnackBar(content: Text('Imported $imported image(s)')),
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
}

// ============================================================================
// ASSET TILE
// ============================================================================

Future<String> _resolveFilePath(String path) async {
  if (path.startsWith('/')) {
    if (File(path).existsSync()) return path;
    final docsMarker = 'Documents/';
    final idx = path.indexOf(docsMarker);
    if (idx != -1) {
      final relativePart = path.substring(idx + docsMarker.length);
      final appDir = await getApplicationDocumentsDirectory();
      final resolved = p.join(appDir.path, relativePart);
      if (File(resolved).existsSync()) return resolved;
    }
    return path;
  }
  final appDir = await getApplicationDocumentsDirectory();
  return p.join(appDir.path, path);
}

class _NftAssetTile extends StatelessWidget {
  final TaggedFile taggedFile;
  final VoidCallback onRemove;

  const _NftAssetTile({
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
        'Image',
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

    return FutureBuilder<String>(
      future: _resolveFilePath(path),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return _placeholder();
        final resolvedPath = snapshot.data!;
        final file = File(resolvedPath);
        if (!file.existsSync()) return _placeholder();
        try {
          final stat = file.statSync();
          final localFile = LocalFile.fromFileSystemEntity(file, stat);
          return FileThumbnail(file: localFile, size: 48);
        } catch (_) {
          return _placeholder();
        }
      },
    );
  }

  Widget _placeholder() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(LucideIcons.image, color: Colors.grey),
    );
  }
}
