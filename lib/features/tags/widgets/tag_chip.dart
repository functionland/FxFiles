import 'package:flutter/material.dart';
import 'package:fula_files/core/models/file_tag.dart';

/// A chip widget displaying a tag with its color
class TagChip extends StatelessWidget {
  final FileTag tag;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final bool selected;
  final bool compact;

  const TagChip({
    super.key,
    required this.tag,
    this.onTap,
    this.onDelete,
    this.selected = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(tag.colorValue);
    final isDark = ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          tag.name,
          style: TextStyle(
            fontSize: 10,
            color: textColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return FilterChip(
      label: Text(tag.name),
      selected: selected,
      onSelected: onTap != null ? (_) => onTap!() : null,
      backgroundColor: color.withValues(alpha: 0.2),
      selectedColor: color.withValues(alpha: 0.4),
      checkmarkColor: color,
      labelStyle: TextStyle(
        color: selected ? color : textColor,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
      side: BorderSide(color: color.withValues(alpha: 0.5)),
      deleteIcon: onDelete != null
          ? Icon(Icons.close, size: 16, color: textColor)
          : null,
      onDeleted: onDelete,
      avatar: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// A row of tag chips for displaying multiple tags
class TagChipRow extends StatelessWidget {
  final List<FileTag> tags;
  final int maxVisible;
  final VoidCallback? onMorePressed;
  final bool compact;

  const TagChipRow({
    super.key,
    required this.tags,
    this.maxVisible = 3,
    this.onMorePressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();

    final visibleTags = tags.take(maxVisible).toList();
    final remaining = tags.length - maxVisible;

    return Wrap(
      spacing: compact ? 4 : 8,
      runSpacing: compact ? 4 : 8,
      children: [
        ...visibleTags.map((tag) => TagChip(tag: tag, compact: compact)),
        if (remaining > 0)
          GestureDetector(
            onTap: onMorePressed,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 6 : 8,
                vertical: compact ? 2 : 4,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(compact ? 4 : 8),
              ),
              child: Text(
                '+$remaining',
                style: TextStyle(
                  fontSize: compact ? 10 : 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
