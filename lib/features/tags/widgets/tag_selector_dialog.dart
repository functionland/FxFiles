import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/tags/widgets/create_tag_dialog.dart';

/// Dialog for selecting tags to apply to a file
class TagSelectorDialog extends ConsumerStatefulWidget {
  final String? localPath;
  final String? remoteKey;
  final String? iosAssetId;
  final String fileName;

  const TagSelectorDialog({
    super.key,
    this.localPath,
    this.remoteKey,
    this.iosAssetId,
    required this.fileName,
  });

  @override
  ConsumerState<TagSelectorDialog> createState() => _TagSelectorDialogState();
}

class _TagSelectorDialogState extends ConsumerState<TagSelectorDialog> {
  final TextEditingController _searchController = TextEditingController();
  Set<String> _selectedTagIds = {};
  String _searchQuery = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCurrentTags();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentTags() async {
    final query = FileTagQuery(
      localPath: widget.localPath,
      remoteKey: widget.remoteKey,
      iosAssetId: widget.iosAssetId,
    );
    final currentTags = await ref.read(fileTagsProvider(query).future);
    setState(() {
      _selectedTagIds = currentTags.map((t) => t.id).toSet();
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tagState = ref.watch(tagProvider);
    final allTags = tagState.tags;

    // Filter tags by search query
    final filteredTags = _searchQuery.isEmpty
        ? allTags
        : allTags.where((t) =>
            t.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Tags')),
          IconButton(
            icon: const Icon(LucideIcons.plus),
            tooltip: 'Create new tag',
            onPressed: _createNewTag,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search field
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search or create tag...',
                prefixIcon: const Icon(LucideIcons.search, size: 20),
                border: const OutlineInputBorder(),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(LucideIcons.x, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
              ),
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
            const SizedBox(height: 16),

            // Tag list or empty state
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else if (filteredTags.isEmpty)
              _buildEmptyState()
            else
              _buildTagList(filteredTags),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _applyTags,
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    if (_searchQuery.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(
              LucideIcons.tag,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'No tags found',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => _createNewTag(initialName: _searchQuery),
              child: Text('Create "$_searchQuery"'),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Icon(
            LucideIcons.tag,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            'No tags yet',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Create your first tag to organize files',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _createNewTag,
            child: const Text('Create Tag'),
          ),
        ],
      ),
    );
  }

  Widget _buildTagList(List<FileTag> tags) {
    return Flexible(
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: tags.length,
        itemBuilder: (context, index) {
          final tag = tags[index];
          final isSelected = _selectedTagIds.contains(tag.id);
          final color = Color(tag.colorValue);

          return ListTile(
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
                ? Text('${tag.fileCount} files')
                : null,
            trailing: Checkbox(
              value: isSelected,
              onChanged: (value) {
                setState(() {
                  if (value == true) {
                    _selectedTagIds.add(tag.id);
                  } else {
                    _selectedTagIds.remove(tag.id);
                  }
                });
              },
            ),
            onTap: () {
              setState(() {
                if (isSelected) {
                  _selectedTagIds.remove(tag.id);
                } else {
                  _selectedTagIds.add(tag.id);
                }
              });
            },
          );
        },
      ),
    );
  }

  Future<void> _createNewTag({String? initialName}) async {
    final tag = await showCreateTagDialog(
      context,
      initialName: initialName ?? _searchQuery,
    );
    if (tag != null && mounted) {
      setState(() {
        _selectedTagIds.add(tag.id);
        _searchController.clear();
        _searchQuery = '';
      });
    }
  }

  Future<void> _applyTags() async {
    final query = FileTagQuery(
      localPath: widget.localPath,
      remoteKey: widget.remoteKey,
      iosAssetId: widget.iosAssetId,
    );

    // Get current tags
    final currentTags = await ref.read(fileTagsProvider(query).future);
    final currentTagIds = currentTags.map((t) => t.id).toSet();

    // Find tags to add and remove
    final toAdd = _selectedTagIds.difference(currentTagIds);
    final toRemove = currentTagIds.difference(_selectedTagIds);

    // Add new tags
    for (final tagId in toAdd) {
      await ref.tagFile(
        tagId: tagId,
        localPath: widget.localPath,
        remoteKey: widget.remoteKey,
        iosAssetId: widget.iosAssetId,
        fileName: widget.fileName,
      );
    }

    // Remove old tags
    for (final tagId in toRemove) {
      await ref.untagFile(
        tagId: tagId,
        localPath: widget.localPath,
        remoteKey: widget.remoteKey,
        iosAssetId: widget.iosAssetId,
      );
    }

    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }
}

/// Show tag selector dialog
Future<bool?> showTagSelectorDialog(
  BuildContext context, {
  String? localPath,
  String? remoteKey,
  String? iosAssetId,
  required String fileName,
}) async {
  return showDialog<bool>(
    context: context,
    builder: (context) => TagSelectorDialog(
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
      fileName: fileName,
    ),
  );
}
