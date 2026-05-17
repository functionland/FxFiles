import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Horizontal scrollable bar of placeholder chips. One chip per CSV
/// header — tapping it inserts `{header}` at the cursor of whichever
/// TextField was most recently focused (TO, message, or subject).
///
/// Pattern: the owner widget holds three `(FocusNode, TextEditingController)`
/// pairs (one per field) and passes them all in via [fields]. The bar
/// observes focus changes on each, tracks the most recently focused
/// pair, and routes chip taps to it. If no field has ever been focused
/// (initial state), defaults to the first non-null pair (typically the
/// message field — see the detail screen for the convention).
class PlaceholderChipBar extends StatefulWidget {
  final List<String> headers;
  final List<PlaceholderField> fields;

  const PlaceholderChipBar({
    super.key,
    required this.headers,
    required this.fields,
  });

  @override
  State<PlaceholderChipBar> createState() => _PlaceholderChipBarState();
}

class PlaceholderField {
  final FocusNode focusNode;
  final TextEditingController controller;
  final String label;
  const PlaceholderField({
    required this.focusNode,
    required this.controller,
    required this.label,
  });
}

class _PlaceholderChipBarState extends State<PlaceholderChipBar> {
  PlaceholderField? _lastFocused;

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      f.focusNode.addListener(() {
        if (f.focusNode.hasFocus) {
          setState(() => _lastFocused = f);
        }
      });
    }
  }

  void _insertPlaceholder(String header) {
    final target = _lastFocused ??
        (widget.fields.isNotEmpty ? widget.fields.first : null);
    if (target == null) return;
    final ctrl = target.controller;
    final text = ctrl.text;
    final selection = ctrl.selection;
    final placeholder = '{$header}';

    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final newText = text.replaceRange(start, end, placeholder);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + placeholder.length),
    );
    // Keep focus on the target so the user can keep typing / inserting.
    target.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.headers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(
          'Attach a CSV to see placeholder chips.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    final activeLabel = _lastFocused?.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: Row(
            children: [
              Icon(LucideIcons.tag,
                  size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  activeLabel != null
                      ? 'Tap to insert into the $activeLabel field, '
                          'or type {ColumnName} manually.'
                      : 'Tap a column to insert it as a placeholder, '
                          'or type {ColumnName} manually.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: widget.headers.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final header = widget.headers[i];
              return ActionChip(
                avatar: const Icon(LucideIcons.plus, size: 14),
                label: Text('{$header}'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _insertPlaceholder(header),
              );
            },
          ),
        ),
      ],
    );
  }
}
