import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/features/sharing/providers/sharing_provider.dart';
import 'package:fula_files/app/theme/app_colors.dart';

class ShareScreen extends ConsumerStatefulWidget {
  const ShareScreen({super.key});

  @override
  ConsumerState<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends ConsumerState<ShareScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _syncShares() async {
    setState(() => _isSyncing = true);

    try {
      await ref.read(sharesProvider.notifier).syncFromCloud();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Shares synced')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sharing'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Shared by Me'),
            Tab(text: 'Shared with Me'),
          ],
        ),
        actions: [
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw),
            onPressed: _isSyncing ? null : _syncShares,
            tooltip: 'Sync from cloud',
          ),
          IconButton(
            icon: const Icon(LucideIcons.qrCode),
            onPressed: _showMyPublicKey,
            tooltip: 'My Share Key',
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _OutgoingSharesTab(),
          _AcceptedSharesTab(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _acceptShareFromLink,
        icon: const Icon(LucideIcons.link),
        label: const Text('Accept Share'),
      ),
    );
  }

  void _showMyPublicKey() async {
    final publicKey = await ref.read(userPublicKeyProvider.future);
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('My Share Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Share this key with others so they can share files with you:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                publicKey ?? 'Not available',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              if (publicKey != null) {
                Clipboard.setData(ClipboardData(text: publicKey));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Key copied to clipboard')),
                );
              }
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  void _acceptShareFromLink() {
    final controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Accept Share'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Paste the share link or token:'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'fxblox://share/... or paste token',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final input = controller.text.trim();
              if (input.isEmpty) return;
              
              Navigator.pop(context);
              
              final notifier = ref.read(sharesProvider.notifier);
              AcceptedShare? accepted;
              
              if (input.startsWith('fxblox://') || input.contains('?token=')) {
                accepted = await notifier.acceptShareFromUrl(input);
              } else {
                accepted = await notifier.acceptShare(input);
              }
              
              if (!context.mounted) return;
              
              final messenger = ScaffoldMessenger.of(context);
              if (accepted != null) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('Share accepted: ${accepted.pathScope}'),
                  ),
                );
                _tabController.animateTo(1);
              } else {
                final error = ref.read(sharesProvider).error;
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(error ?? 'Failed to accept share'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }
}

class _OutgoingSharesTab extends ConsumerWidget {
  const _OutgoingSharesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sharesState = ref.watch(sharesProvider);
    
    if (sharesState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    
    final shares = sharesState.outgoingShares;
    
    if (shares.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.share2,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              'No shares yet',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Share files from the file browser',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: shares.length,
      itemBuilder: (context, index) {
        final share = shares[index];
        return _OutgoingShareCard(share: share);
      },
    );
  }
}

class _OutgoingShareCard extends ConsumerWidget {
  final OutgoingShare share;

  const _OutgoingShareCard({required this.share});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isExpired = share.isExpired;
    final isRevoked = share.isRevoked;
    final shareType = share.token.shareType;

    // Determine icon and color based on share type and status
    IconData typeIcon;
    Color typeColor;
    String typeLabel;

    if (isRevoked) {
      typeIcon = LucideIcons.ban;
      typeColor = Colors.red;
      typeLabel = share.recipientName;
    } else if (isExpired) {
      typeIcon = LucideIcons.clock;
      typeColor = Colors.orange;
      typeLabel = share.recipientName;
    } else {
      switch (shareType) {
        case ShareType.publicLink:
          typeIcon = LucideIcons.link;
          typeColor = Colors.blue;
          typeLabel = share.token.label ?? 'Public Link';
          break;
        case ShareType.passwordProtected:
          typeIcon = LucideIcons.lock;
          typeColor = Colors.orange;
          typeLabel = share.token.label ?? 'Password Link';
          break;
        case ShareType.recipient:
          typeIcon = LucideIcons.userCheck;
          typeColor = Colors.green;
          typeLabel = share.recipientName;
          break;
      }
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: typeColor.withValues(alpha: 0.15),
          child: Icon(typeIcon, color: typeColor),
        ),
        title: Text(typeLabel),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              share.pathScope,
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _ShareTypeChip(shareType: shareType),
                _PermissionChip(permissions: share.permissions),
                if (isRevoked)
                  const _StatusChip(label: 'Revoked', color: Colors.red)
                else if (isExpired)
                  const _StatusChip(label: 'Expired', color: Colors.orange)
                else if (share.token.daysUntilExpiry != null)
                  _StatusChip(
                    label: '${share.token.daysUntilExpiry}d left',
                    color: Colors.green,
                  ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) => _handleAction(context, ref, value),
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'copy',
              child: ListTile(
                leading: Icon(LucideIcons.copy),
                title: Text('Copy Link'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            if (!isRevoked)
              const PopupMenuItem(
                value: 'revoke',
                child: ListTile(
                  leading: Icon(LucideIcons.ban, color: Colors.red),
                  title: Text('Revoke', style: TextStyle(color: Colors.red)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _handleAction(BuildContext context, WidgetRef ref, String action) async {
    switch (action) {
      case 'copy':
        // Use generateShareLinkFromOutgoing to properly handle all share types
        final link = ref.read(sharesProvider.notifier).generateShareLinkFromOutgoing(share);
        Clipboard.setData(ClipboardData(text: link));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Share link copied')),
        );
        break;
      case 'revoke':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Revoke Share?'),
            content: Text(
              'This will revoke access to ${share.pathScope}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Revoke'),
              ),
            ],
          ),
        );

        if (confirmed == true) {
          await ref.read(sharesProvider.notifier).revokeShare(share.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Share revoked')),
            );
          }
        }
        break;
    }
  }
}

class _AcceptedSharesTab extends ConsumerWidget {
  const _AcceptedSharesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sharesState = ref.watch(sharesProvider);
    
    if (sharesState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    
    final shares = sharesState.acceptedShares;
    
    if (shares.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.folderInput,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              'No shared files',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Accept shares using the button below',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: shares.length,
      itemBuilder: (context, index) {
        final share = shares[index];
        return _AcceptedShareCard(share: share);
      },
    );
  }
}

class _AcceptedShareCard extends ConsumerWidget {
  final AcceptedShare share;

  const _AcceptedShareCard({required this.share});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isExpired = share.isExpired;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isExpired ? Colors.orange[100] : Colors.blue[100],
          child: Icon(
            isExpired ? LucideIcons.clock : LucideIcons.folderInput,
            color: isExpired ? Colors.orange : Colors.blue,
          ),
        ),
        title: Text(share.pathScope.split('/').where((s) => s.isNotEmpty).lastOrNull ?? share.pathScope),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${share.bucket}/${share.pathScope}'),
            const SizedBox(height: 4),
            Row(
              children: [
                _PermissionChip(permissions: share.permissions),
                const SizedBox(width: 8),
                if (isExpired)
                  const _StatusChip(label: 'Expired', color: Colors.orange)
                else if (share.token.daysUntilExpiry != null)
                  _StatusChip(
                    label: '${share.token.daysUntilExpiry}d left',
                    color: Colors.blue,
                  ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) => _handleAction(context, ref, value),
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'browse',
              child: ListTile(
                leading: Icon(LucideIcons.folderOpen),
                title: Text('Browse'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'remove',
              child: ListTile(
                leading: Icon(LucideIcons.trash2, color: Colors.red),
                title: Text('Remove', style: TextStyle(color: Colors.red)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleAction(BuildContext context, WidgetRef ref, String action) async {
    switch (action) {
      case 'browse':
        if (share.isExpired) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This share has expired'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }
        context.push(
          '/fula?bucket=${Uri.encodeComponent(share.bucket)}&prefix=${Uri.encodeComponent(share.pathScope)}',
        );
        break;
      case 'remove':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remove Share?'),
            content: const Text(
              'This will remove this share from your list. You can accept it again if you have the link.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        
        if (confirmed == true) {
          await ref.read(sharesProvider.notifier).removeAcceptedShare(share.token.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Share removed')),
            );
          }
        }
        break;
    }
  }
}

class _PermissionChip extends StatelessWidget {
  final SharePermissions permissions;

  const _PermissionChip({required this.permissions});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        permissions.displayName,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: color),
      ),
    );
  }
}

class _ShareTypeChip extends StatelessWidget {
  final ShareType shareType;

  const _ShareTypeChip({required this.shareType});

  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    IconData icon;

    switch (shareType) {
      case ShareType.publicLink:
        label = 'Public';
        color = Colors.blue;
        icon = LucideIcons.globe;
        break;
      case ShareType.passwordProtected:
        label = 'Password';
        color = Colors.orange;
        icon = LucideIcons.keyRound;
        break;
      case ShareType.recipient:
        label = 'Private';
        color = Colors.green;
        icon = LucideIcons.user;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
