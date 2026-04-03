import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/features/sharing/providers/collaboration_provider.dart';

/// Show the create collaboration group dialog.
///
/// Returns the generated collaboration link URL, or null if cancelled.
/// [initialFolderPath] and [initialName] can pre-fill the dialog when
/// launched from the Windows Explorer context menu.
Future<String?> showCreateCollaborationDialog(
  BuildContext context,
  WidgetRef ref, {
  String? initialFolderPath,
  String? initialName,
}) async {
  return showDialog<String>(
    context: context,
    builder: (context) => _CreateCollaborationDialog(
      initialFolderPath: initialFolderPath,
      initialName: initialName,
    ),
  );
}

class _CreateCollaborationDialog extends ConsumerStatefulWidget {
  final String? initialFolderPath;
  final String? initialName;

  const _CreateCollaborationDialog({
    this.initialFolderPath,
    this.initialName,
  });

  @override
  ConsumerState<_CreateCollaborationDialog> createState() =>
      _CreateCollaborationDialogState();
}

class _CreateCollaborationDialogState
    extends ConsumerState<_CreateCollaborationDialog> {
  final _nameController = TextEditingController();
  ShareExpiry _expiry = ShareExpiry.oneYear;
  bool _isLoading = false;
  String? _error;
  String? _generatedLink;
  String? _localFolderPath; // Desktop: optional local folder for sync

  // Files selected for the group (added from cloud browser)
  final List<CollabFileInput> _selectedFiles = [];

  final bool _isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    if (widget.initialName != null) {
      _nameController.text = widget.initialName!;
    }
    if (widget.initialFolderPath != null) {
      _localFolderPath = widget.initialFolderPath;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // After creation, show the link
    if (_generatedLink != null) {
      return AlertDialog(
        title: Row(
          children: [
            const Icon(LucideIcons.checkCircle, color: Colors.green),
            const SizedBox(width: 8),
            const Expanded(child: Text('Group Created')),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Share this link with your collaborator:'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _generatedLink!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Anyone with this link can view and add documents.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _generatedLink!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied')),
              );
            },
            child: const Text('Copy Link'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _generatedLink),
            child: const Text('Done'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Row(
        children: [
          const Icon(LucideIcons.folderPlus),
          const SizedBox(width: 8),
          const Expanded(child: Text('New Collaboration Group')),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Group name
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Group Name',
                  hintText: 'e.g. Legal Docs, Client 1',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(LucideIcons.tag),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),

              // Selected files
              Text(
                'Files (${_selectedFiles.length})',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              if (_selectedFiles.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.3),
                      style: BorderStyle.solid,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      'No files added yet.\nYou can add files after creating the group.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                )
              else
                ...(_selectedFiles.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Chip(
                        avatar: const Icon(LucideIcons.file, size: 16),
                        label: Text(
                          f.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onDeleted: () {
                          setState(() => _selectedFiles.remove(f));
                        },
                      ),
                    ))),
              const SizedBox(height: 16),

              // Expiry
              DropdownButtonFormField<ShareExpiry>(
                value: _expiry,
                decoration: const InputDecoration(
                  labelText: 'Expires After',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(LucideIcons.clock),
                ),
                items: ShareExpiry.values
                    .map((e) => DropdownMenuItem(
                          value: e,
                          child: Text(e.displayName),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _expiry = v);
                },
              ),
              const SizedBox(height: 12),

              // Local folder picker (desktop only)
              if (_isDesktop) ...[
                Text(
                  'Link Local Folder (optional)',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Files in this folder will auto-sync with the collaboration.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final result = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: 'Select folder for collaboration sync',
                    );
                    if (result != null) setState(() => _localFolderPath = result);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.3),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _localFolderPath != null ? LucideIcons.folderOpen : LucideIcons.folderPlus,
                          size: 18,
                          color: _localFolderPath != null ? Colors.blue : theme.colorScheme.outline,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _localFolderPath ?? 'Select folder...',
                            style: TextStyle(
                              fontSize: 13,
                              color: _localFolderPath != null
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.outline,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_localFolderPath != null)
                          GestureDetector(
                            onTap: () => setState(() => _localFolderPath = null),
                            child: Icon(LucideIcons.x, size: 16, color: theme.colorScheme.outline),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Info box
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(LucideIcons.info, size: 18, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Both you and the recipient can add documents to this group.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.blue.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isLoading ? null : _createGroup,
          icon: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.share2, size: 16),
          label: const Text('Create & Share'),
        ),
      ],
    );
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a group name');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final link = await ref.read(collaborationProvider.notifier).createGroup(
            name: name,
            files: _selectedFiles,
            expiryDays: _expiry.days,
          );

      if (link != null && mounted) {
        // If a local folder was selected, assign it and start sync
        if (_localFolderPath != null) {
          // Extract group ID from the link
          try {
            final payload = CollaborationService.parseCollaborationLink(link);
            if (payload != null) {
              final groupId = payload['g'] as String;
              await ref.read(collaborationProvider.notifier).assignFolder(groupId, _localFolderPath!);
            }
          } catch (e) {
            debugPrint('[CreateCollabDialog] Folder assignment failed: $e');
          }
        }

        setState(() {
          _generatedLink = link;
          _isLoading = false;
        });
      } else {
        final error = ref.read(collaborationProvider).error;
        setState(() {
          _error = error ?? 'Failed to create group';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }
}
