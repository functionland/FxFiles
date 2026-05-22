import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/tags/widgets/tag_chip.dart';

/// Grid tile for a single [DumpItem]. Layout: 1:1 thumbnail on top,
/// title + 2-line description below.
///
/// Falls back gracefully when enrichment hasn't run yet (or failed) —
/// title uses [DumpItem.originalName] and description uses
/// `<formatted size> · <category>`. Upload-status overlay surfaces
/// `queued`/`uploading`/`failed`/`pendingAuth` states.
class DumpTile extends ConsumerWidget {
  final DumpItem item;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  static const int maxVisibleTags = 3;

  const DumpTile({
    super.key,
    required this.item,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final title = item.autoTitle ?? item.originalName;
    final description = item.autoDescription ??
        '${_formatBytes(item.sizeBytes)} · ${_categoryLabel(item.category)}';
    final tagsAsync = ref.watch(
      fileTagsProvider(FileTagQuery(localPath: 'dump://${item.id}')),
    );

    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Thumbnail takes most of the cell; text gets whatever
              // height is left after the title + description size
              // themselves. Using Expanded avoids the
              // RenderFlex-overflow scenario the strict AspectRatio
              // layout hit when text metrics rendered slightly taller
              // than expected.
              Expanded(child: _ThumbnailBlock(item: item)),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    _TagsRow(
                      tagsAsync: tagsAsync,
                      maxVisible: maxVisibleTags,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _categoryLabel(DumpCategory category) {
    switch (category) {
      case DumpCategory.link:
        return 'Link';
      case DumpCategory.note:
        return 'Note';
      case DumpCategory.screenshot:
        return 'Screenshot';
      case DumpCategory.image:
        return 'Image';
      case DumpCategory.video:
        return 'Video';
      case DumpCategory.audio:
        return 'Audio';
      case DumpCategory.document:
        return 'Document';
      case DumpCategory.file:
        return 'File';
      case DumpCategory.other:
        return 'Other';
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _TagsRow extends StatelessWidget {
  final AsyncValue<List<FileTag>> tagsAsync;
  final int maxVisible;

  const _TagsRow({required this.tagsAsync, required this.maxVisible});

  @override
  Widget build(BuildContext context) {
    final tags = tagsAsync.maybeWhen(
      data: (v) => v,
      orElse: () => const <FileTag>[],
    );
    if (tags.isEmpty) return const SizedBox.shrink();

    final visible = tags.take(maxVisible).toList(growable: false);
    final overflowCount = tags.length - visible.length;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final t in visible) TagChip(tag: t, compact: true),
          if (overflowCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '+$overflowCount',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThumbnailBlock extends StatelessWidget {
  final DumpItem item;
  const _ThumbnailBlock({required this.item});

  @override
  Widget build(BuildContext context) {
    final hasThumb = item.thumbnailPath != null &&
        File(item.thumbnailPath!).existsSync();

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasThumb)
          Image.file(
            File(item.thumbnailPath!),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _CategoryPlaceholder(category: item.category),
          )
        else
          _CategoryPlaceholder(category: item.category),
        Positioned(
          top: 6,
          right: 6,
          child: _StatusBadge(status: item.uploadStatus),
        ),
      ],
    );
  }
}

class _CategoryPlaceholder extends StatelessWidget {
  final DumpCategory category;
  const _CategoryPlaceholder({required this.category});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primary10,
      alignment: Alignment.center,
      child: Icon(
        _iconForCategory(category),
        size: 40,
        color: AppColors.primary,
      ),
    );
  }

  static IconData _iconForCategory(DumpCategory category) {
    switch (category) {
      case DumpCategory.link:
        return LucideIcons.link;
      case DumpCategory.note:
        return LucideIcons.fileText;
      case DumpCategory.screenshot:
        return LucideIcons.image;
      case DumpCategory.image:
        return LucideIcons.image;
      case DumpCategory.video:
        return LucideIcons.video;
      case DumpCategory.audio:
        return LucideIcons.music;
      case DumpCategory.document:
        return LucideIcons.fileText;
      case DumpCategory.file:
        return LucideIcons.file;
      case DumpCategory.other:
        return LucideIcons.box;
    }
  }
}

class _StatusBadge extends StatelessWidget {
  final DumpUploadStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case DumpUploadStatus.uploaded:
        return const SizedBox.shrink();
      case DumpUploadStatus.queued:
      case DumpUploadStatus.uploading:
        return _badge(
          color: Colors.black.withValues(alpha: 0.55),
          child: const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: Colors.white,
            ),
          ),
        );
      case DumpUploadStatus.pendingAuth:
        return _badge(
          color: AppColors.warning,
          child: const Icon(
            LucideIcons.lock,
            size: 12,
            color: Colors.white,
          ),
        );
      case DumpUploadStatus.failed:
        return _badge(
          color: AppColors.error,
          child: const Icon(
            LucideIcons.alertCircle,
            size: 12,
            color: Colors.white,
          ),
        );
    }
  }

  Widget _badge({required Color color, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
      child: child,
    );
  }
}
