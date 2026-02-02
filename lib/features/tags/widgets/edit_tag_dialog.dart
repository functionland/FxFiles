import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Dialog for editing an existing tag
class EditTagDialog extends ConsumerStatefulWidget {
  final FileTag tag;

  const EditTagDialog({super.key, required this.tag});

  @override
  ConsumerState<EditTagDialog> createState() => _EditTagDialogState();
}

class _EditTagDialogState extends ConsumerState<EditTagDialog> {
  late TextEditingController _nameController;
  late int _selectedColor;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.tag.name);
    _selectedColor = widget.tag.colorValue;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _hasChanges {
    return _nameController.text.trim() != widget.tag.name ||
        _selectedColor != widget.tag.colorValue;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Tag'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Tag name',
                hintText: 'Enter tag name',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _saveTag(),
            ),
            const SizedBox(height: 16),
            Text(
              'Color',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            _buildColorPicker(),
            const SizedBox(height: 16),
            _buildPreview(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving || !_hasChanges ? null : _saveTag,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildColorPicker() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: TagColors.presetColors.map((colorValue) {
        final isSelected = colorValue == _selectedColor;
        return GestureDetector(
          onTap: () => setState(() => _selectedColor = colorValue),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Color(colorValue),
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(color: Colors.white, width: 3)
                  : null,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: Color(colorValue).withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 2,
                      )
                    ]
                  : null,
            ),
            child: isSelected
                ? const Icon(Icons.check, color: Colors.white, size: 18)
                : null,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPreview() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return const SizedBox.shrink();

    final color = Color(_selectedColor);
    final isDark = ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Preview: ',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  name,
                  style: TextStyle(color: textColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveTag() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a tag name')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final notifier = ref.read(tagProvider.notifier);

      // Update name if changed
      if (name != widget.tag.name) {
        await notifier.updateTagName(widget.tag.id, name);
      }

      // Update color if changed
      if (_selectedColor != widget.tag.colorValue) {
        await notifier.updateTagColor(widget.tag.id, _selectedColor);
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update tag: $e')),
        );
        setState(() => _isSaving = false);
      }
    }
  }
}

/// Show edit tag dialog and return true if tag was updated
Future<bool?> showEditTagDialog(
  BuildContext context, {
  required FileTag tag,
}) async {
  return showDialog<bool>(
    context: context,
    builder: (context) => EditTagDialog(tag: tag),
  );
}
