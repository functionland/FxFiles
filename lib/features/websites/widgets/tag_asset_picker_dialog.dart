import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/shared/utils/tagged_file_utils.dart';
import 'package:fula_files/shared/widgets/tagged_file_thumbnail.dart';

/// Two-step picker used by the website generator's import sheet to pull in
/// files that are already tagged with some other tag. Step 1 shows the tag
/// list (excluding the website's own tag); step 2 shows the files inside the
/// chosen tag with checkboxes — every available file is pre-selected by
/// default, and the user unchecks the ones they don't want.
///
/// Files whose only identifier is `remoteKey` (cloud-only) or `iosAssetId`
/// (iOS Photos asset that hasn't been resolved to a path) are shown but
/// disabled with a "not available locally" hint, because the website upload
/// pipeline reads `WebsiteAsset.localPath` directly via `File(...).readAsBytes`.
///
/// Returns the list of selected TaggedFile entries, or null if the user
/// cancelled at any point.
Future<List<TaggedFile>?> showTagAssetPicker({
  required BuildContext context,
  required String excludeTagId,
}) {
  return showModalBottomSheet<List<TaggedFile>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _TagAssetPickerDialog(excludeTagId: excludeTagId),
  );
}

class _TagAssetPickerDialog extends ConsumerStatefulWidget {
  final String excludeTagId;

  const _TagAssetPickerDialog({required this.excludeTagId});

  @override
  ConsumerState<_TagAssetPickerDialog> createState() =>
      _TagAssetPickerDialogState();
}

class _TagAssetPickerDialogState extends ConsumerState<_TagAssetPickerDialog> {
  FileTag? _selectedTag;
  // Map of TaggedFile.id → checked-state. Initialised when a tag is opened;
  // entries for `localPath == null` files stay false and the checkbox is
  // disabled.
  final Map<String, bool> _checked = {};

  final _tagSearchController = TextEditingController();
  String _tagSearchQuery = '';

  @override
  void dispose() {
    _tagSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            _header(context),
            const Divider(height: 1),
            Expanded(
              child: _selectedTag == null
                  ? _buildTagList(context, scrollCtrl)
                  : _buildFileList(context, scrollCtrl),
            ),
            if (_selectedTag != null) _buildActionBar(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    if (_selectedTag == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Import from tag',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: const Icon(LucideIcons.x, size: 20),
              onPressed: () => Navigator.pop(context),
              tooltip: 'Close',
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(LucideIcons.arrowLeft, size: 20),
            onPressed: () => setState(() {
              _selectedTag = null;
              _checked.clear();
            }),
            tooltip: 'Back to tag list',
          ),
          Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: Color(_selectedTag!.colorValue),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Text(
              _selectedTag!.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.x, size: 20),
            onPressed: () => Navigator.pop(context),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _buildTagList(BuildContext context, ScrollController scrollCtrl) {
    final theme = Theme.of(context);
    final tagState = ref.watch(tagProvider);
    final allTags =
        tagState.tags.where((t) => t.id != widget.excludeTagId).toList();

    if (tagState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (allTags.isEmpty) {
      return _EmptyState(
        icon: LucideIcons.tag,
        title: 'No other tags',
        subtitle: 'Tag files first, then import them from here.',
      );
    }

    final query = _tagSearchQuery.trim().toLowerCase();
    final filteredTags = query.isEmpty
        ? allTags
        : allTags
            .where((t) => t.name.toLowerCase().contains(query))
            .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _tagSearchController,
            decoration: InputDecoration(
              hintText: 'Search tags...',
              prefixIcon: const Icon(LucideIcons.search, size: 20),
              suffixIcon: _tagSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(LucideIcons.x, size: 18),
                      onPressed: () {
                        _tagSearchController.clear();
                        setState(() => _tagSearchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[300]!),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[300]!),
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.3),
            ),
            onChanged: (value) => setState(() => _tagSearchQuery = value),
          ),
        ),
        Expanded(
          child: filteredTags.isEmpty
              ? Center(
                  child: Text(
                    'No tags matching "$_tagSearchQuery"',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                )
              : ListView.builder(
                  controller: scrollCtrl,
                  itemCount: filteredTags.length,
                  itemBuilder: (ctx, i) {
                    final tag = filteredTags[i];
                    return ListTile(
                      leading: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color:
                              Color(tag.colorValue).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: Color(tag.colorValue),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                      title: Text(tag.name),
                      subtitle: Text(
                          '${tag.fileCount} file${tag.fileCount == 1 ? '' : 's'}'),
                      trailing:
                          const Icon(LucideIcons.chevronRight, size: 18),
                      onTap: () => _openTag(tag),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _openTag(FileTag tag) {
    setState(() {
      _selectedTag = tag;
      _checked.clear();
    });
  }

  Widget _buildFileList(BuildContext context, ScrollController scrollCtrl) {
    final theme = Theme.of(context);
    final filesAsync = ref.watch(taggedFilesProvider(_selectedTag!.id));

    return filesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _EmptyState(
        icon: LucideIcons.alertCircle,
        title: 'Could not load files',
        subtitle: '$e',
      ),
      data: (files) {
        if (files.isEmpty) {
          return _EmptyState(
            icon: LucideIcons.fileX,
            title: 'No files in this tag',
            subtitle: 'Tag some files first, then come back.',
          );
        }

        // First-time initialisation: every available file pre-selected,
        // unavailable files left unchecked (and disabled).
        if (_checked.isEmpty) {
          for (final tf in files) {
            _checked[tf.id] = tf.localPath != null;
          }
        }

        final availableCount = files.where((tf) => tf.localPath != null).length;
        final allAvailableSelected = files
            .where((tf) => tf.localPath != null)
            .every((tf) => _checked[tf.id] == true);

        return Column(
          children: [
            if (availableCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$availableCount available • '
                        '${files.length - availableCount} unavailable',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        for (final tf in files) {
                          if (tf.localPath != null) {
                            _checked[tf.id] = !allAvailableSelected;
                          }
                        }
                      }),
                      child: Text(allAvailableSelected ? 'Deselect all' : 'Select all'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: files.length,
                itemBuilder: (ctx, i) {
                  final tf = files[i];
                  final available = tf.localPath != null;
                  final isChecked = _checked[tf.id] ?? false;
                  return ListTile(
                    leading: Opacity(
                      opacity: available ? 1.0 : 0.4,
                      child: TaggedFileThumbnail(taggedFile: tf, size: 40),
                    ),
                    title: Text(
                      tf.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: available ? null : theme.disabledColor,
                      ),
                    ),
                    subtitle: available
                        ? null
                        : Text(
                            tf.iosAssetId != null
                                ? 'iOS Photos asset — open it in the file browser first'
                                : tf.remoteKey != null
                                    ? 'Cloud-only — download to use as a website asset'
                                    : 'Not available locally',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                    trailing: Checkbox(
                      value: isChecked,
                      onChanged: available
                          ? (v) =>
                              setState(() => _checked[tf.id] = v ?? false)
                          : null,
                    ),
                    onTap: available
                        ? () => openTaggedFile(context, tf)
                        : null,
                    dense: true,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActionBar(BuildContext context) {
    final theme = Theme.of(context);
    final files = ref.read(taggedFilesProvider(_selectedTag!.id)).asData?.value
        ?? const <TaggedFile>[];
    final selected = files.where((tf) => _checked[tf.id] == true).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              selected.isEmpty
                  ? 'Pick at least one file'
                  : '${selected.length} of ${files.length} selected',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(context, selected),
            icon: const Icon(LucideIcons.plus, size: 16),
            label: Text(selected.length == 1 ? 'Add 1 file' : 'Add ${selected.length} files'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
