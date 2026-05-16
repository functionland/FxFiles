import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/shared/utils/tagged_file_utils.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';

/// Thumbnail for a [TaggedFile]. Handles:
/// - iOS PhotoKit assets (uses [FileThumbnail]'s native iOS branch when an
///   `iosAssetId` is available or resolvable from a virtual path)
/// - regular filesystem files (resolved via [resolveTaggedFilePath])
/// - an optional [fallbackImageUrl] (e.g. an IPFS gateway URL) shown when no
///   local file is available
/// - a generic placeholder icon as the final fallback
class TaggedFileThumbnail extends StatelessWidget {
  final TaggedFile taggedFile;
  final double size;
  final String? fallbackImageUrl;

  const TaggedFileThumbnail({
    super.key,
    required this.taggedFile,
    this.size = 48,
    this.fallbackImageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final path = taggedFile.localPath;
    if (path == null) return _fallback();

    // Fast path on iOS: if we already have a PhotoKit asset id (either stored
    // on the TaggedFile or recoverable from a virtual path), build a
    // LocalFile carrying that id and let FileThumbnail render via PhotoKit.
    if (Platform.isIOS) {
      final iosAssetId = taggedFile.iosAssetId
          ?? (path.startsWith('/') ? null : lookupIosAssetId(path));
      if (iosAssetId != null) {
        final localFile = LocalFile(
          path: path,
          name: taggedFile.fileName,
          size: 0,
          modifiedAt: taggedFile.taggedAt,
          isDirectory: false,
          iosAssetId: iosAssetId,
        );
        return FileThumbnail(file: localFile, size: size);
      }
    }

    return FutureBuilder<String?>(
      future: resolveTaggedFilePath(taggedFile),
      builder: (ctx, snap) {
        final resolved = snap.data;
        if (resolved == null) return _fallback();
        final file = File(resolved);
        if (!file.existsSync()) return _fallback();
        try {
          final stat = file.statSync();
          final localFile = LocalFile.fromFileSystemEntity(file, stat);
          return FileThumbnail(file: localFile, size: size);
        } catch (_) {
          return _fallback();
        }
      },
    );
  }

  Widget _fallback() {
    if (fallbackImageUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          fallbackImageUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(),
        ),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(LucideIcons.file, color: Colors.grey),
    );
  }
}
