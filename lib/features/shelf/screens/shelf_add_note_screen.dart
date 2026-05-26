import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/shelf_service.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/tags/widgets/tag_chip.dart';

/// Manual "Add note" flow. The user enters multi-line text + optional
/// tags; on Save the text is staged as a `.txt` file and pushed
/// through the standard ingest pipeline (`ShelfService.ingestAndSchedule`).
/// Tags are attached to the resulting [ShelfItem] via a synthetic URI
/// `dump://<id>` (revision H6 — keeps the tag link stable across cache
/// GC / file moves).
class ShelfAddNoteScreen extends ConsumerStatefulWidget {
  const ShelfAddNoteScreen({super.key});

  @override
  ConsumerState<ShelfAddNoteScreen> createState() => _ShelfAddNoteScreenState();
}

class _ShelfAddNoteScreenState extends ConsumerState<ShelfAddNoteScreen> {
  final TextEditingController _controller = TextEditingController();
  final Set<String> _selectedTagIds = <String>{};
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_saving && _controller.text.trim().isNotEmpty;

  Future<void> _openTagPicker() async {
    final state = ref.read(tagProvider);
    final allTags = state.tags;
    if (allTags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No tags yet — create one from the Tags screen first.'),
        ),
      );
      return;
    }
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TagPickerSheet(
        allTags: allTags,
        initialSelected: _selectedTagIds,
      ),
    );
    if (result != null) {
      setState(() {
        _selectedTagIds
          ..clear()
          ..addAll(result);
      });
    }
  }

  Future<void> _save() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    setState(() => _saving = true);

    try {
      final docs = await getApplicationDocumentsDirectory();
      final stagingDir = Directory(p.join(docs.path, 'dump_pending'));
      if (!await stagingDir.exists()) {
        await stagingDir.create(recursive: true);
      }

      final id = const Uuid().v4();
      final filename = '$id-note.txt';
      final filePath = p.join(stagingDir.path, filename);
      await File(filePath).writeAsString(text, flush: true);

      final originalName = _deriveOriginalName(text);

      final created = await ShelfService.instance.ingestAndSchedule(
        cachedPaths: [filePath],
        mimeTypes: const <String?>['text/plain'],
        originalNames: [originalName],
        textPayload: text,
        sourcePackage: 'fxfiles-add-note',
      );

      if (created.isNotEmpty && _selectedTagIds.isNotEmpty) {
        final item = created.first;
        final syntheticUri = 'dump://${item.id}';
        for (final tagId in _selectedTagIds) {
          await ref.tagFile(
            tagId: tagId,
            localPath: syntheticUri,
            fileName: originalName,
          );
        }
      }

      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/shelf');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save note: $e')),
      );
      setState(() => _saving = false);
    }
  }

  String _deriveOriginalName(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    String firstLine = '';
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        firstLine = trimmed;
        break;
      }
    }
    if (firstLine.isEmpty) {
      // All-whitespace / emoji-only / etc. fall through to a stamped
      // default per the Session 3b "long / emoji / whitespace" edge
      // case in the plan.
      return 'Note ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}';
    }
    if (firstLine.length > 60) {
      return '${firstLine.substring(0, 59)}…';
    }
    return firstLine;
  }

  @override
  Widget build(BuildContext context) {
    final tagState = ref.watch(tagProvider);
    final selectedTags = tagState.tags
        .where((t) => _selectedTagIds.contains(t.id))
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('New note'),
        actions: [
          TextButton(
            onPressed: _canSave ? _save : null,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Type a note…',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _TagRow(
              tags: selectedTags,
              onAdd: _openTagPicker,
              onClear: _selectedTagIds.isEmpty
                  ? null
                  : () => setState(_selectedTagIds.clear),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagRow extends StatelessWidget {
  final List<FileTag> tags;
  final VoidCallback onAdd;
  final VoidCallback? onClear;

  const _TagRow({
    required this.tags,
    required this.onAdd,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ActionChip(
          avatar: const Icon(LucideIcons.plus, size: 16),
          label: Text(tags.isEmpty ? 'Add tags' : 'Edit tags'),
          onPressed: onAdd,
        ),
        for (final t in tags) TagChip(tag: t),
        if (onClear != null)
          TextButton(
            onPressed: onClear,
            child: const Text('Clear'),
          ),
      ],
    );
  }
}

class _TagPickerSheet extends StatefulWidget {
  final List<FileTag> allTags;
  final Set<String> initialSelected;

  const _TagPickerSheet({
    required this.allTags,
    required this.initialSelected,
  });

  @override
  State<_TagPickerSheet> createState() => _TagPickerSheetState();
}

class _TagPickerSheetState extends State<_TagPickerSheet> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Select tags',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in widget.allTags)
                  TagChip(
                    tag: t,
                    selected: _selected.contains(t.id),
                    onTap: () => setState(() {
                      if (!_selected.add(t.id)) _selected.remove(t.id);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
