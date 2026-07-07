import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/core/services/cloud_collaboration_storage_service.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/services/web_share_service.dart';

/// Mirror of lib/features/sharing/screens/share_screen.dart: three
/// tabs — Shared by Me (outgoing shares with Copy Link / Revoke /
/// Delete), Shared with Me (accepted shares with Download / Remove +
/// the Accept Share dialog), and Collaborate (groups with create /
/// accept-link; CollaborationService is reused directly). Desktop
/// folder-sync flows stay native.
class WebSharedScreen extends StatefulWidget {
  const WebSharedScreen({super.key});

  @override
  State<WebSharedScreen> createState() => _WebSharedScreenState();
}

class _WebSharedScreenState extends State<WebSharedScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 3, vsync: this);

  List<OutgoingShare> _outgoing = const [];
  List<AcceptedShare> _accepted = const [];
  List<OutgoingCollaboration> _outgoingCollabs = const [];
  List<AcceptedCollaboration> _acceptedCollabs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final outgoing = await WebShareService.listOutgoingShares();
      final accepted = await WebShareService.listAcceptedShares();
      // Sync collaborations with the per-user cloud index so groups created on
      // ANOTHER device / browser / incognito show up here. The web screen used
      // to read only THIS browser's local storage and never touched
      // CloudCollaborationStorageService, so a group created on web was neither
      // uploaded to nor pulled from `.fula/collaborations/{userId}.json` — it
      // stayed invisible on every other device even though its manifest + files
      // are in the cloud (still reachable via the share link / AI MCP). This
      // mirrors the native CollaborationNotifier's cloud sync.
      List<OutgoingCollaboration> outCollabs;
      try {
        final localOut =
            await CollaborationService.instance.getOutgoingCollaborations();
        // MERGE (download cloud + union with local + upload the merge). It is
        // never a destructive overwrite, so a device holding only a subset of
        // groups can't clobber groups created elsewhere.
        outCollabs = await CloudCollaborationStorageService.instance
            .syncCollaborations(localOut);
        if (outCollabs.length != localOut.length) {
          await CollaborationService.instance
              .importOutgoingCollaborations(outCollabs);
        }
      } catch (_) {
        // Cloud sync is best-effort; fall back to local so the tab still loads.
        outCollabs =
            await CollaborationService.instance.getOutgoingCollaborations();
      }

      var accCollabs =
          await CollaborationService.instance.getAcceptedCollaborations();
      if (accCollabs.isEmpty) {
        try {
          final cloudAcc = await CloudCollaborationStorageService.instance
              .downloadAcceptedCollaborations();
          if (cloudAcc.isNotEmpty) {
            await CollaborationService.instance
                .importAcceptedCollaborations(cloudAcc);
            accCollabs = cloudAcc;
          }
        } catch (_) {
          // best-effort
        }
      }
      if (mounted) {
        setState(() {
          _outgoing = outgoing;
          _accepted = accepted;
          _outgoingCollabs = outCollabs;
          _acceptedCollabs = accCollabs;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ------------------------------------------------------ accept share

  Future<void> _showAcceptShareDialog() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Accept Share'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Paste the share link or token:'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'fxblox://share/... or paste token',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
    if (input == null || input.trim().isEmpty || !mounted) return;
    try {
      final accepted = await WebShareService.acceptFromInput(input);
      _snack('Share accepted: ${accepted.token.pathScope}');
      _tabController.animateTo(1);
      await _load();
    } catch (e) {
      _snack(e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  // ------------------------------------------------------- collaborate

  Future<void> _createCollaboration() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Collaborate'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Group name',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    _snack('Creating group…');
    try {
      final collab = await CollaborationService.instance.createGroup(
        name: name.trim(),
        files: const [],
      );
      final link =
          CollaborationService.instance.generateCollaborationLink(collab);
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Group created'),
        action: SnackBarAction(
          label: 'Copy link',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: link));
          },
        ),
      ));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
      _snack('Could not create group: $e');
    }
  }

  Future<void> _acceptCollaborationLink() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Accept Collaboration Link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://cloud.fx.land/collab/...',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
    if (input == null || input.trim().isEmpty || !mounted) return;
    try {
      final accepted = await CollaborationService.instance
          .acceptCollaboration(input.trim());
      _snack('Joined "${accepted.name}"');
      await _load();
    } catch (e) {
      _snack('Could not accept link: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Shared'),
        actions: [
          IconButton(
            tooltip: 'Accept share link',
            icon: const Icon(LucideIcons.clipboardCheck),
            onPressed: _showAcceptShareDialog,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Shared by Me'),
            Tab(text: 'Shared with Me'),
            Tab(text: 'Collaborate'),
          ],
        ),
      ),
      body: _error != null
          ? Center(child: Text('Could not load shares.\n$_error'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _outgoingTab(),
                    _acceptedTab(),
                    _collaborateTab(),
                  ],
                ),
    );
  }

  // ------------------------------------------------------- shared by me

  Widget _outgoingTab() {
    final theme = Theme.of(context);
    if (_outgoing.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.share2, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('No shares yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Share files from your categories',
                style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _outgoing.length,
      itemBuilder: (ctx, i) => _outgoingCard(theme, _outgoing[i]),
    );
  }

  Widget _outgoingCard(ThemeData theme, OutgoingShare share) {
    final token = share.token;
    final (icon, color) = token.isRevoked
        ? (LucideIcons.ban, Colors.red)
        : token.isExpired
            ? (LucideIcons.clock, Colors.orange)
            : switch (token.shareType) {
                ShareType.publicLink => (LucideIcons.link, Colors.blue),
                ShareType.passwordProtected => (
                    LucideIcons.lock,
                    Colors.orange
                  ),
                ShareType.recipient => (
                    LucideIcons.userCheck,
                    AppColors.primary
                  ),
              };
    final days = token.daysUntilExpiry;
    final expiryChip = token.isRevoked
        ? ('Revoked', Colors.red)
        : token.isExpired
            ? ('Expired', Colors.orange)
            : days != null
                ? ('${days}d left', Colors.green)
                : ('Never expires', Colors.green);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(share.recipientName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              token.fileName ?? token.pathScope,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                _chip(token.shareType.displayName,
                    theme.colorScheme.onSurfaceVariant),
                _chip(token.permissions.displayName,
                    theme.colorScheme.onSurfaceVariant),
                _chip(expiryChip.$1, expiryChip.$2),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'copy') {
              await Clipboard.setData(
                  ClipboardData(text: WebShareService.shareUrlFor(share)));
              _snack('Link copied to clipboard');
            }
            if (v == 'revoke') {
              try {
                await WebShareService.revokeShare(share.id);
                _snack('Share revoked');
                await _load();
              } catch (e) {
                _snack('Revoke failed: $e');
              }
            }
            if (v == 'delete') {
              try {
                await WebShareService.deleteOutgoingShare(share.id);
                await _load();
              } catch (e) {
                _snack('Delete failed: $e');
              }
            }
          },
          itemBuilder: (ctx) => [
            const PopupMenuItem(value: 'copy', child: Text('Copy Link')),
            if (!share.token.isRevoked)
              const PopupMenuItem(value: 'revoke', child: Text('Revoke')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w600, color: color)),
      );

  // ----------------------------------------------------- shared with me

  Widget _acceptedTab() {
    final theme = Theme.of(context);
    if (_accepted.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.inbox, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('Nothing shared with you yet',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Use Accept Share to paste a link someone sent you',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _showAcceptShareDialog,
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.primary),
              icon: const Icon(LucideIcons.clipboardCheck, size: 18),
              label: const Text('Accept Share'),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _accepted.length,
      itemBuilder: (ctx, i) {
        final share = _accepted[i];
        final token = share.token;
        final valid = token.isValid;
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(
              valid ? LucideIcons.fileCheck : LucideIcons.fileX,
              color: valid ? AppColors.primary : Colors.orange,
            ),
            title: Text(token.fileName ?? token.pathScope,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              valid
                  ? 'Accepted ${share.acceptedAt.toLocal().toString().split('.').first}'
                  : token.isRevoked
                      ? 'Revoked by owner'
                      : 'Expired',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (valid)
                  IconButton(
                    tooltip: 'Download',
                    icon: const Icon(Icons.download, size: 20),
                    onPressed: () => _downloadAccepted(share),
                  ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(LucideIcons.x, size: 18),
                  onPressed: () async {
                    await WebShareService.removeAcceptedShare(share.id);
                    await _load();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _downloadAccepted(AcceptedShare share) async {
    _snack('Downloading…');
    try {
      final bytes = await WebForegroundActivity.instance
          .run(() => WebShareService.downloadSharedFile(share));
      final name = share.token.fileName ??
          share.token.pathScope.split('/').last;
      saveBytesAsDownload(
        name.isEmpty ? 'shared-file' : name,
        bytes,
        mimeType: share.token.contentType ?? 'application/octet-stream',
      );
    } catch (e) {
      _snack('Download failed: $e');
    }
  }

  // ------------------------------------------------------- collaborate

  Widget _collaborateTab() {
    final theme = Theme.of(context);
    final entries = <({
      String id,
      String name,
      int fileCount,
      bool isOwner,
      bool isValid
    })>[
      for (final c in _outgoingCollabs)
        (
          id: c.id,
          name: c.name,
          fileCount: c.group.fileCount,
          isOwner: true,
          isValid: c.isValid,
        ),
      for (final c in _acceptedCollabs)
        (
          id: c.id,
          name: c.name,
          fileCount: c.group.fileCount,
          isOwner: false,
          isValid: c.isValid,
        ),
    ];

    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.users, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('No collaboration groups yet',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Create a group and share documents with collaborators',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _createCollaboration,
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary),
                  icon: const Icon(LucideIcons.folderPlus, size: 18),
                  label: const Text('New Collaborate'),
                ),
                OutlinedButton.icon(
                  onPressed: _acceptCollaborationLink,
                  icon: const Icon(LucideIcons.link, size: 18),
                  label: const Text('Accept Collaboration Link'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: _createCollaboration,
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary),
                icon: const Icon(LucideIcons.folderPlus, size: 16),
                label: const Text('New Collaborate'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _acceptCollaborationLink,
                icon: const Icon(LucideIcons.link, size: 16),
                label: const Text('Accept Link'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: entries.length,
            itemBuilder: (ctx, i) {
              final entry = entries[i];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    LucideIcons.folderOpen,
                    color: entry.isOwner ? Colors.blue : Colors.green,
                  ),
                  title: Text(entry.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${entry.fileCount} file${entry.fileCount == 1 ? '' : 's'}'
                    '${entry.isValid ? '' : '  ·  expired'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: _chip(
                    entry.isOwner ? 'Owner' : 'Received',
                    entry.isOwner ? Colors.blue : Colors.green,
                  ),
                  onTap: () => context.go('/collab/${entry.id}'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
