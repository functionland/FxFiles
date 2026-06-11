import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

// Mirrors of the native tag dialogs for the web shell:
// - create_tag_dialog.dart  → showWebCreateTagDialog
// - edit_tag_dialog.dart    → showWebEditTagDialog
// - tag_selector_dialog.dart → showWebTagSelectorDialog
// Same strings, same 19-color preset wrap, same preview chip; mutations
// go through WebTagService (cloud-synced in the native manifest format).

/// Shared name + color form body.
class _TagForm extends StatelessWidget {
  final TextEditingController nameController;
  final int selectedColor;
  final ValueChanged<int> onColorSelected;

  const _TagForm({
    required this.nameController,
    required this.selectedColor,
    required this.onColorSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: nameController,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Tag name',
            hintText: 'Enter tag name',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        Text('Color',
            style: theme.textTheme.labelMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in TagColors.presetColors)
              InkWell(
                onTap: () => onColorSelected(c),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: selectedColor == c
                        ? Border.all(color: Colors.white, width: 3)
                        : null,
                    boxShadow: selectedColor == c
                        ? [
                            BoxShadow(
                              color: Color(c).withValues(alpha: 0.5),
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                  child: selectedColor == c
                      ? const Icon(Icons.check,
                          size: 16, color: Colors.white)
                      : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        // Preview chip (native parity).
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: nameController,
          builder: (ctx, value, _) {
            final name =
                value.text.trim().isEmpty ? 'Tag name' : value.text.trim();
            final color = Color(selectedColor);
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
                border:
                    Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(name,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Create-tag dialog — returns the created tag, or null on cancel.
Future<FileTag?> showWebCreateTagDialog({
  required BuildContext context,
  String? initialName,
}) {
  final nameController = TextEditingController(text: initialName ?? '');
  var color = TagColors.presetColors.first;
  var busy = false;
  return showDialog<FileTag>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Create Tag'),
        content: SizedBox(
          width: 360,
          child: _TagForm(
            nameController: nameController,
            selectedColor: color,
            onColorSelected: (c) => setLocal(() => color = c),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final name = nameController.text.trim();
                    if (name.isEmpty) return;
                    setLocal(() => busy = true);
                    try {
                      final tag = await WebTagService.instance
                          .createTag(name: name, colorValue: color);
                      if (ctx.mounted) Navigator.pop(ctx, tag);
                    } catch (e) {
                      setLocal(() => busy = false);
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                            content: Text('Could not create tag: $e')));
                      }
                    }
                  },
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create'),
          ),
        ],
      ),
    ),
  );
}

/// Edit-tag dialog — returns true when a change was saved.
Future<bool> showWebEditTagDialog({
  required BuildContext context,
  required FileTag tag,
}) async {
  final nameController = TextEditingController(text: tag.name);
  var color = tag.colorValue;
  var busy = false;
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final hasChanges =
            nameController.text.trim() != tag.name || color != tag.colorValue;
        return AlertDialog(
          title: const Text('Edit Tag'),
          content: SizedBox(
            width: 360,
            child: _TagForm(
              nameController: nameController,
              selectedColor: color,
              onColorSelected: (c) => setLocal(() => color = c),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy || !hasChanges
                  ? null
                  : () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) return;
                      setLocal(() => busy = true);
                      try {
                        await WebTagService.instance.updateTag(tag.id,
                            name: name, colorValue: color);
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        setLocal(() => busy = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text('Could not save tag: $e')));
                        }
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
  return saved ?? false;
}

/// Tag-selector for one cloud file (mirror of tag_selector_dialog.dart):
/// search-or-create field, checkbox rows, Apply commits the deltas via
/// WebTagService. Returns true when anything changed.
Future<bool> showWebTagSelectorDialog({
  required BuildContext context,
  required String remoteKey,
  required String fileName,
  required Set<String> initialTagIds,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (ctx) => _WebTagSelectorDialog(
      remoteKey: remoteKey,
      fileName: fileName,
      initialTagIds: initialTagIds,
    ),
  );
  return changed ?? false;
}

class _WebTagSelectorDialog extends StatefulWidget {
  final String remoteKey;
  final String fileName;
  final Set<String> initialTagIds;

  const _WebTagSelectorDialog({
    required this.remoteKey,
    required this.fileName,
    required this.initialTagIds,
  });

  @override
  State<_WebTagSelectorDialog> createState() => _WebTagSelectorDialogState();
}

class _WebTagSelectorDialogState extends State<_WebTagSelectorDialog> {
  final _searchController = TextEditingController();
  late final Set<String> _selected = {...widget.initialTagIds};
  bool _busy = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createTag() async {
    final tag = await showWebCreateTagDialog(
      context: context,
      initialName: _searchController.text.trim(),
    );
    if (tag != null && mounted) {
      setState(() {
        _selected.add(tag.id);
        _searchController.clear();
      });
    }
  }

  Future<void> _apply() async {
    setState(() => _busy = true);
    try {
      final toAdd = _selected.difference(widget.initialTagIds);
      final toRemove = widget.initialTagIds.difference(_selected);
      for (final tagId in toAdd) {
        await WebTagService.instance.tagFile(
          tagId: tagId,
          remoteKey: widget.remoteKey,
          fileName: widget.fileName,
        );
      }
      for (final tagId in toRemove) {
        await WebTagService.instance.untagFile(
          tagId: tagId,
          remoteKey: widget.remoteKey,
        );
      }
      if (mounted) {
        Navigator.pop(context, toAdd.isNotEmpty || toRemove.isNotEmpty);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save tags: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _searchController.text.trim().toLowerCase();
    final allTags = WebTagService.instance.tags;
    final tags = allTags
        .where((t) => query.isEmpty || t.name.toLowerCase().contains(query))
        .toList();

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Tags')),
          IconButton(
            tooltip: 'Create new tag',
            icon: const Icon(LucideIcons.plus, size: 20),
            onPressed: _busy ? null : _createTag,
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        height: 380,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search or create tag...',
                prefixIcon: const Icon(LucideIcons.search, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(LucideIcons.x, size: 18),
                        onPressed: () =>
                            setState(() => _searchController.clear()),
                      )
                    : null,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: allTags.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(LucideIcons.tag, size: 44),
                          const SizedBox(height: 8),
                          Text('No tags yet',
                              style: theme.textTheme.titleSmall),
                          const SizedBox(height: 4),
                          Text('Create your first tag to organize files',
                              style: theme.textTheme.bodySmall),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _busy ? null : _createTag,
                            child: const Text('Create Tag'),
                          ),
                        ],
                      ),
                    )
                  : tags.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(LucideIcons.tag, size: 44),
                              const SizedBox(height: 8),
                              Text('No tags found',
                                  style: theme.textTheme.titleSmall),
                              const SizedBox(height: 12),
                              FilledButton(
                                onPressed: _busy ? null : _createTag,
                                child: Text(
                                    'Create "${_searchController.text.trim()}"'),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: tags.length,
                          itemBuilder: (ctx, i) {
                            final tag = tags[i];
                            final color = Color(tag.colorValue);
                            final selected = _selected.contains(tag.id);
                            return ListTile(
                              dense: true,
                              leading: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              title: Text(tag.name),
                              subtitle: tag.fileCount > 0
                                  ? Text('${tag.fileCount} files',
                                      style:
                                          const TextStyle(fontSize: 11))
                                  : null,
                              trailing: Checkbox(
                                value: selected,
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() {
                                          if (v == true) {
                                            _selected.add(tag.id);
                                          } else {
                                            _selected.remove(tag.id);
                                          }
                                        }),
                              ),
                              onTap: _busy
                                  ? null
                                  : () => setState(() {
                                        if (selected) {
                                          _selected.remove(tag.id);
                                        } else {
                                          _selected.add(tag.id);
                                        }
                                      }),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _apply,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Apply'),
        ),
      ],
    );
  }
}
