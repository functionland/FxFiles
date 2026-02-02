import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Dialog for creating a new tag
class CreateTagDialog extends ConsumerStatefulWidget {
  final String? initialName;

  const CreateTagDialog({super.key, this.initialName});

  @override
  ConsumerState<CreateTagDialog> createState() => _CreateTagDialogState();
}

class _CreateTagDialogState extends ConsumerState<CreateTagDialog> {
  late TextEditingController _nameController;
  int _selectedColor = TagColors.presetColors[0];
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _selectedColor = TagColors.getRandomColor();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Tag'),
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
              onSubmitted: (_) => _createTag(),
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
          onPressed: _isCreating ? null : _createTag,
          child: _isCreating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
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

  Future<void> _createTag() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a tag name')),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      final tag = await ref.read(tagProvider.notifier).createTag(
        name: name,
        colorValue: _selectedColor,
      );

      if (mounted) {
        Navigator.of(context).pop(tag);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create tag: $e')),
        );
        setState(() => _isCreating = false);
      }
    }
  }
}

/// Show create tag dialog and return the created tag
Future<FileTag?> showCreateTagDialog(
  BuildContext context, {
  String? initialName,
}) async {
  return showDialog<FileTag>(
    context: context,
    builder: (context) => CreateTagDialog(initialName: initialName),
  );
}
