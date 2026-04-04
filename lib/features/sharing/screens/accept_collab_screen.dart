import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/features/sharing/providers/collaboration_provider.dart';

/// Screen for pasting a collaboration link and selecting a local folder.
/// Desktop only (Windows / macOS / Linux).
class AcceptCollabScreen extends ConsumerStatefulWidget {
  final String? initialFolderPath;

  const AcceptCollabScreen({super.key, this.initialFolderPath});

  @override
  ConsumerState<AcceptCollabScreen> createState() => _AcceptCollabScreenState();
}

class _AcceptCollabScreenState extends ConsumerState<AcceptCollabScreen> {
  final _linkController = TextEditingController();
  String? _groupName;
  String? _groupId;
  String? _selectedFolder;
  bool _isParsing = false;
  bool _isAccepting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialFolderPath != null) {
      _selectedFolder = widget.initialFolderPath;
    }
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _parseLink() async {
    final url = _linkController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isParsing = true;
      _error = null;
      _groupName = null;
      _groupId = null;
    });

    try {
      final payload = CollaborationService.parseCollaborationLink(url);
      if (payload == null) {
        setState(() {
          _error = 'Invalid collaboration link. Please check and try again.';
          _isParsing = false;
        });
        return;
      }

      setState(() {
        _groupId = payload['g'] as String;
        _groupName = payload['n'] as String? ?? 'Untitled';
        _isParsing = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to parse link: $e';
        _isParsing = false;
      });
    }
  }

  Future<void> _pickFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder for collaboration sync',
    );
    if (result != null) {
      setState(() => _selectedFolder = result);
    }
  }

  Future<void> _acceptAndSync() async {
    final url = _linkController.text.trim();
    if (url.isEmpty || _groupId == null) return;

    setState(() {
      _isAccepting = true;
      _error = null;
    });

    try {
      final notifier = ref.read(collaborationProvider.notifier);
      final accepted = await notifier.acceptCollaborationLink(url);

      if (accepted == null) {
        setState(() {
          _error = 'Failed to accept collaboration link.';
          _isAccepting = false;
        });
        return;
      }

      // Assign local folder if selected
      if (_selectedFolder != null) {
        await notifier.assignFolder(accepted.id, _selectedFolder!);
      }

      if (mounted) {
        context.push('/collab/${accepted.id}');
      }
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _isAccepting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isParsed = _groupId != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Accept Collaboration'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Instructions
            Text(
              'Paste a collaboration link to join a shared group.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),

            // Link input
            TextField(
              controller: _linkController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Collaboration Link',
                hintText: 'https://cloud.fx.land/collab/...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(LucideIcons.clipboardPaste),
                  tooltip: 'Paste from clipboard',
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) {
                      _linkController.text = data!.text!;
                      _parseLink();
                    }
                  },
                ),
              ),
              onChanged: (_) {
                if (isParsed) {
                  setState(() {
                    _groupId = null;
                    _groupName = null;
                  });
                }
              },
            ),
            const SizedBox(height: 12),

            // Parse button
            if (!isParsed)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isParsing ? null : _parseLink,
                  icon: _isParsing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(LucideIcons.search),
                  label: Text(_isParsing ? 'Parsing...' : 'Parse Link'),
                ),
              ),

            // Error
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(LucideIcons.alertCircle, color: Colors.red, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Parsed preview
            if (isParsed) ...[
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(LucideIcons.folderCheck, color: Colors.green, size: 24),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _groupName!,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Group ID: ${_groupId!.substring(0, 8)}...',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(LucideIcons.checkCircle2, color: Colors.green),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Folder picker
              Text(
                'Sync to Local Folder (optional)',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Files will be downloaded here and new files you add will be uploaded automatically.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),

              InkWell(
                onTap: _pickFolder,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _selectedFolder != null ? LucideIcons.folderOpen : LucideIcons.folderPlus,
                        color: _selectedFolder != null ? Colors.blue : theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _selectedFolder ?? 'Click to select a folder...',
                          style: TextStyle(
                            color: _selectedFolder != null
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.outline,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_selectedFolder != null)
                        IconButton(
                          icon: const Icon(LucideIcons.x, size: 16),
                          onPressed: () => setState(() => _selectedFolder = null),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Accept button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _isAccepting ? null : _acceptAndSync,
                  icon: _isAccepting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(LucideIcons.checkCircle2),
                  label: Text(
                    _isAccepting
                        ? 'Accepting...'
                        : _selectedFolder != null
                            ? 'Accept & Start Sync'
                            : 'Accept',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
