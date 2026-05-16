import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/share_folder_sync_service.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/features/sharing/providers/sharing_provider.dart';

/// Desktop-only screen for pasting a share link and picking a local folder
/// the share should be mirrored into. One-way (download-only) counterpart of
/// [AcceptCollabScreen].
class AcceptShareScreen extends ConsumerStatefulWidget {
  /// Optional folder pre-selected by the Windows context menu invocation.
  final String? initialFolderPath;

  const AcceptShareScreen({super.key, this.initialFolderPath});

  @override
  ConsumerState<AcceptShareScreen> createState() => _AcceptShareScreenState();
}

class _AcceptShareScreenState extends ConsumerState<AcceptShareScreen> {
  final _linkController = TextEditingController();
  ShareToken? _parsedToken;
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
      _parsedToken = null;
    });

    try {
      final token = SharingService.instance.parseShareLink(url);
      if (token == null) {
        setState(() {
          _error = 'Invalid share link. Password-protected links are not '
              'supported by this folder-sync flow yet — accept them from '
              'the Shared screen instead.';
          _isParsing = false;
        });
        return;
      }
      if (token.isExpired) {
        setState(() {
          _error = 'This share has expired.';
          _isParsing = false;
        });
        return;
      }
      setState(() {
        _parsedToken = token;
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
      dialogTitle: 'Select folder for share sync',
    );
    if (result != null) {
      setState(() => _selectedFolder = result);
    }
  }

  Future<void> _acceptAndSync() async {
    final url = _linkController.text.trim();
    if (url.isEmpty || _parsedToken == null) return;

    setState(() {
      _isAccepting = true;
      _error = null;
    });

    try {
      final notifier = ref.read(sharesProvider.notifier);
      final accepted = await notifier.acceptShareFromUrl(url);

      if (accepted == null) {
        if (mounted) {
          setState(() => _error = 'Failed to accept share.');
        }
        return;
      }

      if (_selectedFolder != null) {
        // Kicks off background download. The screen pops immediately;
        // progress shows up on the Accepted-Shares tab.
        await ShareFolderSyncService.instance
            .assignFolder(accepted.token.id, _selectedFolder!);
      }

      if (mounted) {
        // Send the user to the shares list so they see the new entry +
        // sync status. pushReplacement so Back from there doesn't return
        // here.
        context.pushReplacement('/shared');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Error: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isAccepting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isParsed = _parsedToken != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Accept Share'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paste a share link to download its files into a local folder. '
              'New files added to the share will sync to your folder '
              'automatically. Files you add to the folder yourself stay '
              'local — shares are one-way.',
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
                labelText: 'Share Link',
                hintText: 'fxblox://share/... or paste token',
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
                  setState(() => _parsedToken = null);
                }
              },
            ),
            const SizedBox(height: 12),

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
                          color: Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          LucideIcons.folderInput,
                          color: Colors.blue,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _parsedToken!.label ??
                                  _parsedToken!.pathScope.split('/').where((s) => s.isNotEmpty).lastOrNull ??
                                  _parsedToken!.pathScope,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_parsedToken!.bucket}/${_parsedToken!.pathScope}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _parsedToken!.permissions.canWrite
                                  ? 'Read + write access'
                                  : 'Read-only access',
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

              Text(
                'Sync to Local Folder (optional)',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Files will be downloaded here. New files added to the '
                'share will sync automatically; files you add yourself stay '
                'local.',
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
                    border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _selectedFolder != null
                            ? LucideIcons.folderOpen
                            : LucideIcons.folderPlus,
                        color: _selectedFolder != null
                            ? Colors.blue
                            : theme.colorScheme.outline,
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
