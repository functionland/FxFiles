import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/shelf_service.dart';
import 'package:fula_files/core/services/shelf_suggestion_dismissals_service.dart';
import 'package:fula_files/core/services/shelf_tag_suggester.dart';
import 'package:fula_files/features/shelf/providers/shelf_suggestions_provider.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/tags/widgets/tag_chip.dart';
import 'package:fula_files/features/tags/widgets/tag_selector_dialog.dart';
import 'package:fula_files/shared/utils/adaptive_ui.dart';

/// Grid tile for a single [ShelfItem]. Layout: 1:1 thumbnail on top,
/// title + 2-line description below.
///
/// Falls back gracefully when enrichment hasn't run yet (or failed) —
/// title uses [ShelfItem.originalName] and description uses
/// `<formatted size> · <category>`. Upload-status overlay surfaces
/// `queued`/`uploading`/`failed`/`pendingAuth` states.
class ShelfTile extends ConsumerWidget {
  final ShelfItem item;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  static const int maxVisibleTags = 3;

  const ShelfTile({
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
                        fontSize: 10,
                        height: 1.25,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    _TagsRow(
                      tagsAsync: tagsAsync,
                      maxVisible: maxVisibleTags,
                    ),
                    _SuggestionsRow(
                      itemId: item.id,
                      fileName: item.originalName,
                      remoteKey: item.remoteKey,
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

  static String _categoryLabel(ShelfCategory category) {
    switch (category) {
      case ShelfCategory.link:
        return 'Link';
      case ShelfCategory.note:
        return 'Note';
      case ShelfCategory.screenshot:
        return 'Screenshot';
      case ShelfCategory.image:
        return 'Image';
      case ShelfCategory.video:
        return 'Video';
      case ShelfCategory.audio:
        return 'Audio';
      case ShelfCategory.document:
        return 'Document';
      case ShelfCategory.file:
        return 'File';
      case ShelfCategory.other:
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

/// Renders the suggested-tag chips beneath the applied-tag row. Each
/// chip is tap-to-apply and has a small `×` to dismiss (persists in
/// [ShelfSuggestionDismissalsService] so we don't keep nagging the user
/// about a tag they've rejected).
///
/// Watches [shelfSuggestionsProvider] which is a sync `Provider.family`,
/// so this widget rebuilds the instant a tag is applied/dismissed or
/// the underlying enrichment/tag-state changes. No `AsyncValue.when`
/// is needed and there's no loading flicker.
class _SuggestionsRow extends ConsumerWidget {
  final String itemId;
  final String fileName;
  final String? remoteKey;

  const _SuggestionsRow({
    required this.itemId,
    required this.fileName,
    required this.remoteKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestions = ref.watch(shelfSuggestionsProvider(itemId));
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final s in suggestions)
            _SuggestionChip(
              suggestion: s,
              onApply: () async {
                await ref.tagFile(
                  tagId: s.tag.id,
                  localPath: 'dump://$itemId',
                  remoteKey: remoteKey,
                  fileName: fileName,
                );
              },
              onDismiss: () async {
                await ShelfSuggestionDismissalsService.instance
                    .dismiss(itemId, s.tag.id);
              },
            ),
        ],
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  final TagSuggestion suggestion;
  final Future<void> Function() onApply;
  final Future<void> Function() onDismiss;

  const _SuggestionChip({
    required this.suggestion,
    required this.onApply,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagColor = Color(suggestion.tag.colorValue);
    // The chip itself stays visually compact to fit the dense tile,
    // but each tap region has padding that puts the touch target around
    // 24×24 — small for Material guidelines (48dp) but a deliberate
    // tradeoff: chips share row real-estate with applied tags and the
    // tile is only ~180 px wide. The dismiss area gets a noticeably
    // bigger pad than the apply icon would suggest so users don't
    // mis-tap apply when they meant dismiss.
    return Tooltip(
      message: 'Suggested: tap to apply, × to dismiss',
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: tagColor.withValues(alpha: 0.75)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onApply,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.plus, size: 12, color: tagColor),
                    const SizedBox(width: 3),
                    Text(
                      suggestion.tag.name,
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Visual separator so the two tap regions read as distinct.
            Container(
              width: 1,
              height: 14,
              color: tagColor.withValues(alpha: 0.4),
            ),
            InkWell(
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                child: Icon(
                  LucideIcons.x,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

class _ThumbnailBlock extends StatefulWidget {
  final ShelfItem item;
  const _ThumbnailBlock({required this.item});

  @override
  State<_ThumbnailBlock> createState() => _ThumbnailBlockState();
}

class _ThumbnailBlockState extends State<_ThumbnailBlock> {
  bool _lazyFetchKicked = false;

  bool get _hasLocalThumb {
    final p = widget.item.thumbnailPath;
    if (p == null || p.isEmpty) return false;
    try {
      return File(p).existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeKickLazyFetch();
  }

  @override
  void didUpdateWidget(covariant _ThumbnailBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _lazyFetchKicked = false;
    }
    _maybeKickLazyFetch();
  }

  void _maybeKickLazyFetch() {
    if (_lazyFetchKicked) return;
    if (_hasLocalThumb) return;
    final remoteKey = widget.item.thumbnailRemoteKey;
    if (remoteKey == null || remoteKey.isEmpty) return;
    _lazyFetchKicked = true;
    // Fire-and-forget; the Hive watch stream will re-render this tile
    // when the local path is updated on success.
    unawaited(ShelfService.instance.ensureLocalThumbnail(widget.item));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_hasLocalThumb)
          Image.file(
            File(widget.item.thumbnailPath!),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _CategoryPlaceholder(category: widget.item.category),
          )
        else
          _CategoryPlaceholder(category: widget.item.category),
        Positioned(
          top: 6,
          right: 6,
          child: _StatusBadge(status: widget.item.uploadStatus),
        ),
        Positioned(
          top: 2,
          left: 2,
          child: _ActionsMenuButton(item: widget.item),
        ),
      ],
    );
  }
}

class _ActionsMenuButton extends StatelessWidget {
  final ShelfItem item;
  const _ActionsMenuButton({required this.item});

  @override
  Widget build(BuildContext context) {
    // Wrapped in GestureDetector with an empty `onLongPress` so a
    // long-press on the 3-dot button does NOT bubble up to the parent
    // ReorderableGridView and start a drag — the user expects the
    // menu (via tap), not to pick this tile up to move it.
    return GestureDetector(
      onLongPress: () {},
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          iconSize: 16,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          visualDensity: VisualDensity.compact,
          tooltip: 'More options',
          icon: const Icon(LucideIcons.moreVertical, color: Colors.white),
          onPressed: () => _openActions(context),
        ),
      ),
    );
  }

  Future<void> _openActions(BuildContext context) async {
    final theme = Theme.of(context);
    await showAdaptiveSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.tag),
              title: const Text('Tags'),
              subtitle: const Text('Add or manage tags'),
              onTap: () async {
                Navigator.pop(sheetCtx);
                if (!context.mounted) return;
                await showTagSelectorDialog(
                  context,
                  localPath: 'dump://${item.id}',
                  remoteKey: item.remoteKey,
                  fileName: item.originalName,
                );
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                LucideIcons.trash2,
                color: theme.colorScheme.error,
              ),
              title: Text(
                'Remove from Shelf',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text(
                'Also removes from cloud. Can\'t be undone.',
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                if (!context.mounted) return;
                await _confirmAndDelete(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndDelete(BuildContext context) async {
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Remove from Shelf?'),
        content: const Text(
          'This item will be removed from this device and from cloud '
          'storage. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    // Capture messenger now — `deleteItem` is async and the tile may
    // unmount mid-call once the tombstone hides it.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ShelfService.instance.deleteItem(item);
      messenger?.showSnackBar(
        const SnackBar(content: Text('Removed from Shelf')),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not remove: $e')),
      );
    }
  }
}

class _CategoryPlaceholder extends StatelessWidget {
  final ShelfCategory category;
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

  static IconData _iconForCategory(ShelfCategory category) {
    switch (category) {
      case ShelfCategory.link:
        return LucideIcons.link;
      case ShelfCategory.note:
        return LucideIcons.fileText;
      case ShelfCategory.screenshot:
        return LucideIcons.image;
      case ShelfCategory.image:
        return LucideIcons.image;
      case ShelfCategory.video:
        return LucideIcons.video;
      case ShelfCategory.audio:
        return LucideIcons.music;
      case ShelfCategory.document:
        return LucideIcons.fileText;
      case ShelfCategory.file:
        return LucideIcons.file;
      case ShelfCategory.other:
        return LucideIcons.box;
    }
  }
}

class _StatusBadge extends StatelessWidget {
  final ShelfUploadStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case ShelfUploadStatus.uploaded:
        return const SizedBox.shrink();
      case ShelfUploadStatus.queued:
      case ShelfUploadStatus.uploading:
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
      case ShelfUploadStatus.pendingAuth:
        return _badge(
          color: AppColors.warning,
          child: const Icon(
            LucideIcons.lock,
            size: 12,
            color: Colors.white,
          ),
        );
      case ShelfUploadStatus.failed:
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
