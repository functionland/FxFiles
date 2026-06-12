import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_save.dart';

/// Mirror of lib/features/sharing/screens/collaboration_detail_screen.dart
/// for the web shell: the group's files (download / remove), Add File
/// (browser-picked bytes uploaded into the collab storage — same
/// uploadCollabFileFromLocal path the app's receiver-upload uses),
/// Copy Link / Refresh / Revoke for owners. Local-folder assignment
/// stays native.
class WebCollabDetailScreen extends StatefulWidget {
  final String groupId;
  const WebCollabDetailScreen({super.key, required this.groupId});

  @override
  State<WebCollabDetailScreen> createState() => _WebCollabDetailScreenState();
}

class _WebCollabDetailScreenState extends State<WebCollabDetailScreen> {
  CollaborationGroup? _group;
  OutgoingCollaboration? _outgoing;
  AcceptedCollaboration? _accepted;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _isOwner => _outgoing != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final outgoing =
          await CollaborationService.instance.getOutgoingCollaborations();
      final accepted =
          await CollaborationService.instance.getAcceptedCollaborations();
      _outgoing =
          outgoing.where((c) => c.id == widget.groupId).firstOrNull;
      _accepted =
          accepted.where((c) => c.id == widget.groupId).firstOrNull;

      // Refresh pulls the merged manifest (S3 + server DB).
      final fresh =
          await CollaborationService.instance.refreshGroup(widget.groupId);
      _group = fresh ?? _outgoing?.group ?? _accepted?.group;
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      _group = _outgoing?.group ?? _accepted?.group;
      if (mounted) {
        setState(() {
          _error = _group == null ? '$e' : null;
          _loading = false;
        });
      }
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _addFile() async {
    final linkSecretKey =
        _outgoing?.linkSecretKey ?? _accepted?.linkSecretKey;
    if (linkSecretKey == null) {
      _snack('Missing link secret key for this group.');
      return;
    }
    final picked = await FilePicker.platform.pickFiles(withData: true);
    final file = picked?.files.firstOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null || !mounted) return;

    // Encryption copies the buffer, so a big file spikes tab memory at
    // 2×+ its size on the main thread. Confirm before committing.
    if (bytes.length > 100 * 1024 * 1024) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Large file'),
          content: Text(
              '"${file.name}" is ${_fmtSize(bytes.length)}. Encrypting '
              'and uploading a file this size can freeze this browser '
              'tab for a while. Continue?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    setState(() => _busy = true);
    _snack('Uploading "${file.name}"…');
    try {
      await WebForegroundActivity.instance.run(
        () => CollaborationService.instance.uploadCollabFileFromLocal(
          groupId: widget.groupId,
          fileName: file.name,
          fileData: bytes,
          linkSecretKey: linkSecretKey,
        ),
      );
      if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
      _snack('Added "${file.name}"');
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
      _snack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(CollaborationFile file) async {
    _snack('Downloading "${file.fileName}"…');
    try {
      final bytes = await WebForegroundActivity.instance.run(
        () => CollaborationService.instance
            .downloadCollabFile(widget.groupId, file),
      );
      saveBytesAsDownload(
        file.fileName,
        bytes,
        mimeType: file.contentType ?? 'application/octet-stream',
      );
    } catch (e) {
      _snack('Download failed: $e');
    }
  }

  Future<void> _removeFile(CollaborationFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove file?'),
        content: Text('"${file.fileName}" will be removed from the group.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await CollaborationService.instance.removeFileFromGroup(
        groupId: widget.groupId,
        fileId: file.id,
      );
      await _load();
    } catch (e) {
      _snack('Remove failed: $e');
    }
  }

  Future<void> _copyLink() async {
    final outgoing = _outgoing;
    if (outgoing == null) return;
    final link =
        CollaborationService.instance.generateCollaborationLink(outgoing);
    await Clipboard.setData(ClipboardData(text: link));
    _snack('Link copied to clipboard');
  }

  Future<void> _revokeGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Group'),
        content: const Text(
            'Collaborators will lose access to this group. This cannot be '
            'undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await CollaborationService.instance.revokeGroup(widget.groupId);
      if (mounted) context.go('/shared');
    } catch (e) {
      _snack('Revoke failed: $e');
    }
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = _group;
    final files = group?.files ?? const <CollaborationFile>[];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/shared'),
        ),
        title: Text(group?.name ?? 'Collaboration'),
        actions: [
          if (_isOwner)
            IconButton(
              tooltip: 'Copy Link',
              icon: const Icon(LucideIcons.link),
              onPressed: _copyLink,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          if (_isOwner)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'revoke') _revokeGroup();
              },
              itemBuilder: (ctx) => const [
                PopupMenuItem(value: 'revoke', child: Text('Revoke Group')),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addFile,
        icon: const Icon(LucideIcons.filePlus),
        label: Text(_busy ? 'Uploading…' : 'Add File'),
      ),
      body: _error != null
          ? Center(child: Text('Could not load group.\n$_error'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : files.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(LucideIcons.folderOpen, size: 56),
                          const SizedBox(height: 12),
                          Text('No files yet',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: 6),
                          Text(
                              'Add files here, or from any category via '
                              '"Add to Collaborate".',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: files.length,
                      itemBuilder: (ctx, i) {
                        final f = files[i];
                        return ListTile(
                          leading: const Icon(
                              Icons.insert_drive_file_outlined),
                          title: Text(f.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${_fmtSize(f.fileSize)}  ·  '
                            '${f.addedAt.toLocal().toString().split('.').first}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Download',
                                icon:
                                    const Icon(Icons.download, size: 20),
                                onPressed: () => _download(f),
                              ),
                              if (_isOwner)
                                IconButton(
                                  tooltip: 'Remove',
                                  icon:
                                      const Icon(LucideIcons.x, size: 18),
                                  onPressed: () => _removeFile(f),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
    );
  }
}
