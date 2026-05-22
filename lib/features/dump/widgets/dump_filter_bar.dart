import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/features/dump/providers/dump_providers.dart';

/// Filter chips for category + a Date-range chip. Tag filtering lands
/// in Session 3b once the `FileTag` integration is wired in.
class DumpFilterBar extends ConsumerWidget {
  const DumpFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(dumpFilterProvider);
    final notifier = ref.read(dumpFilterProvider.notifier);

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
    required DumpFilterNotifier notifier,
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

  static const List<DumpCategory> _categoryOrder = <DumpCategory>[
    DumpCategory.image,
    DumpCategory.screenshot,
    DumpCategory.video,
    DumpCategory.link,
    DumpCategory.note,
    DumpCategory.document,
    DumpCategory.audio,
    DumpCategory.file,
    DumpCategory.other,
  ];

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

class _DateChip extends StatelessWidget {
  final DumpFilter filter;
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
