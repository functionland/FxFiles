import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/features/shelf/providers/shelf_providers.dart';

/// Filter chips for category + a Date-range chip. Tag filtering lands
/// in Session 3b once the `FileTag` integration is wired in.
class ShelfFilterBar extends ConsumerWidget {
  const ShelfFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(shelfFilterProvider);
    final notifier = ref.read(shelfFilterProvider.notifier);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _DateChip(
            filter: filter,
            onPick: () => _pickDateRange(
              context,
              current: filter.dateRange,
              notifier: notifier,
            ),
            onClear: () => notifier.setDateRange(null),
          ),
          const SizedBox(width: 8),
          for (final category in _categoryOrder) ...[
            FilterChip(
              label: Text(_categoryLabel(category)),
              avatar: Icon(_iconForCategory(category), size: 16),
              selected: filter.categories.contains(category),
              onSelected: (_) => notifier.toggleCategory(category),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Future<void> _pickDateRange(
    BuildContext context, {
    required DateTimeRange? current,
    required ShelfFilterNotifier notifier,
  }) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: current,
    );
    notifier.setDateRange(picked);
  }

  static const List<ShelfCategory> _categoryOrder = <ShelfCategory>[
    ShelfCategory.image,
    ShelfCategory.screenshot,
    ShelfCategory.video,
    ShelfCategory.link,
    ShelfCategory.note,
    ShelfCategory.document,
    ShelfCategory.audio,
    ShelfCategory.file,
    ShelfCategory.other,
  ];

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

class _DateChip extends StatelessWidget {
  final ShelfFilter filter;
  final VoidCallback onPick;
  final VoidCallback onClear;
  const _DateChip({
    required this.filter,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final range = filter.dateRange;
    final label = range == null ? 'Date' : _formatRange(range);
    return InputChip(
      avatar: const Icon(LucideIcons.calendar, size: 16),
      label: Text(label),
      onPressed: onPick,
      selected: range != null,
      onDeleted: range == null ? null : onClear,
    );
  }

  static String _formatRange(DateTimeRange r) {
    final fmtShort = DateFormat('MMM d');
    final fmtMonth = DateFormat('MMM y');
    final fmtYear = DateFormat('y');
    final sameDay = r.start.year == r.end.year &&
        r.start.month == r.end.month &&
        r.start.day == r.end.day;
    if (sameDay) return fmtShort.format(r.start);
    final sameMonth =
        r.start.year == r.end.year && r.start.month == r.end.month;
    if (sameMonth) {
      return '${fmtShort.format(r.start)}–${r.end.day}';
    }
    final sameYear = r.start.year == r.end.year;
    if (sameYear) {
      return '${fmtShort.format(r.start)} – ${fmtShort.format(r.end)}';
    }
    if (r.start.day == 1 &&
        r.end.day ==
            DateUtils.getDaysInMonth(r.end.year, r.end.month)) {
      // Full-month or full-year ranges look nicer with the month/year
      // form than two day-level dates.
      if (r.start.month == 1 &&
          r.end.month == 12 &&
          r.start.year == r.end.year) {
        return fmtYear.format(r.start);
      }
      return '${fmtMonth.format(r.start)} – ${fmtMonth.format(r.end)}';
    }
    return '${fmtShort.format(r.start)} ${r.start.year} – ${fmtShort.format(r.end)} ${r.end.year}';
  }
}
