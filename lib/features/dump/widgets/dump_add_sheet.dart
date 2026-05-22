import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/dump_service.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/tags/widgets/tag_chip.dart';

/// Modal bottom sheet shown from `DumpScreen`'s FAB. Three actions:
///   - Add note → push `/dump/add/note`
///   - Take photo → `image_picker` camera → push `/dump/doodle`
///   - Import file → `file_picker` → stage + `ingestAndSchedule`
///
/// `image_picker` is wired up with `retrieveLostData()` (H1) on the
/// DumpScreen so an Android Activity-death during capture doesn't lose
/// the photo.
class DumpAddSheet extends ConsumerWidget {
  const DumpAddSheet({super.key});

  /// Convenience entry point — opens the sheet via `showModalBottomSheet`.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const DumpAddSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(LucideIcons.fileText),
            title: const Text('Add note'),
            subtitle: const Text('Type some text — saved to your Dump'),
            onTap: () => _addNote(context),
          ),
          ListTile(
            leading: const Icon(LucideIcons.camera),
            title: const Text('Take photo'),
            subtitle: const Text('Capture + doodle, then save'),
            onTap: () => _takePhoto(context, ref),
          ),
          ListTile(
            leading: const Icon(LucideIcons.upload),
            title: const Text('Import file'),
            subtitle: const Text('Pick one or more files from your device'),
            onTap: () => _importFile(context, ref),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _addNote(BuildContext context) {
    Navigator.of(context).pop();
    context.push('/dump/add/note');
  }

  Future<void> _takePhoto(BuildContext context, WidgetRef ref) async {
    Navigator.of(context).pop();
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );
      if (xfile == null) return; // user cancelled
      if (!context.mounted) return;
      context.push('/dump/doodle', extra: xfile.path);
    } catch (e) {
      debugPrint('DumpAddSheet camera failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open camera: $e')),
        );
      }
    }
  }

  Future<void> _importFile(BuildContext context, WidgetRef ref) async {
    Navigator.of(context).pop();
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
      );
    } catch (e) {
      debugPrint('DumpAddSheet pickFiles failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file picker: $e')),
        );
      }
      return;
    }
    if (result == null) return; // cancelled
    final picked = result.files.where((f) => f.path != null).toList();
    if (picked.isEmpty) return;

    final stagedPaths = <String>[];
    final mimeTypes = <String?>[];
    final names = <String>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      final stagingDir = Directory(p.join(docs.path, 'dump_pending'));
      if (!await stagingDir.exists()) {
        await stagingDir.create(recursive: true);
      }
      for (final f in picked) {
        final dest = p.join(stagingDir.path, '${const Uuid().v4()}-${f.name}');
        await File(f.path!).copy(dest);
        stagedPaths.add(dest);
        mimeTypes.add(lookupMimeType(f.name));
        names.add(f.name);
      }
    } catch (e) {
      debugPrint('DumpAddSheet staging failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stage files: $e')),
        );
      }
      return;
    }

    final created = await DumpService.instance.ingestAndSchedule(
      cachedPaths: stagedPaths,
      mimeTypes: mimeTypes,
      originalNames: names,
      sourcePackage: 'fxfiles-import',
    );

    // Optional one-shot tag-picker — applies the selected tags to ALL
    // imported items (mirrors the Android share-multiple flow's UX).
    if (created.isNotEmpty && context.mounted) {
      final tagState = ref.read(tagProvider);
      if (tagState.tags.isNotEmpty) {
        final picked = await showModalBottomSheet<Set<String>>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _ImportTagSheet(allTags: tagState.tags),
        );
        if (picked != null && picked.isNotEmpty) {
          for (final item in created) {
            final syntheticUri = 'dump://${item.id}';
            for (final tagId in picked) {
              await ref.tagFile(
                tagId: tagId,
                localPath: syntheticUri,
                fileName: item.originalName,
              );
            }
          }
        }
      }
    }
  }
}

class _ImportTagSheet extends StatefulWidget {
  final List<FileTag> allTags;
  const _ImportTagSheet({required this.allTags});

  @override
  State<_ImportTagSheet> createState() => _ImportTagSheetState();
}

class _ImportTagSheetState extends State<_ImportTagSheet> {
  final Set<String> _selected = <String>{};

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
              'Apply tags to imported items?',
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
                  child: const Text('Skip'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Helper used by `DumpScreen.initState` to drain any photo that was
/// lost when Android killed the activity during `pickImage` (H1).
class DumpLostDataHandler {
  DumpLostDataHandler._();
  static final DumpLostDataHandler instance = DumpLostDataHandler._();

  /// Returns the file path of a recovered lost photo, or `null` if
  /// there isn't one. Caller is expected to push `/dump/doodle` with
  /// the path. Safe to call from any platform — `retrieveLostData` is
  /// an Android-only operation; non-Android returns null.
  Future<String?> retrievePendingPhoto() async {
    if (!Platform.isAndroid) return null;
    try {
      final picker = ImagePicker();
      final lost = await picker.retrieveLostData();
      if (lost.isEmpty) return null;
      if (lost.file == null) return null;
      return lost.file!.path;
    } catch (e) {
      debugPrint('DumpLostDataHandler.retrievePendingPhoto failed: $e');
      return null;
    }
  }
}
