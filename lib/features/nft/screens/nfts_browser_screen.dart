import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shimmer/shimmer.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/models/billing/wallet_info.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/features/billing/providers/billing_provider.dart';
import 'package:fula_files/features/nft/providers/nft_provider.dart';
import 'package:fula_files/features/nft/widgets/receive_nft_dialog.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Screen listing NFTs in two tabs: Created and Received.
class NftsBrowserScreen extends ConsumerStatefulWidget {
  const NftsBrowserScreen({super.key});

  @override
  ConsumerState<NftsBrowserScreen> createState() => _NftsBrowserScreenState();
}

class _NftsBrowserScreenState extends ConsumerState<NftsBrowserScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NFTs'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.qrCode),
            tooltip: 'Receive NFT',
            onPressed: () => showReceiveNftDialog(context),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Created'),
            Tab(text: 'Received'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _CreatedTab(
            onCreateCollection: () => _createCollection(context, ref),
          ),
          const _ReceivedTab(),
        ],
      ),
      floatingActionButton: ListenableBuilder(
        listenable: _tabController,
        builder: (context, _) {
          // Show FAB only on the Created tab
          if (_tabController.index == 0) {
            return FloatingActionButton(
              onPressed: () => _createCollection(context, ref),
              child: const Icon(LucideIcons.plus),
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }

  Future<void> _createCollection(BuildContext context, WidgetRef ref) async {
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New NFT Collection'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Collection name',
            hintText: 'My NFTs',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (value) => Navigator.of(ctx).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == null || result.trim().isEmpty) return;

    final tag = await ref.read(nftProvider.notifier).createCollection(result.trim());
    if (tag != null && context.mounted) {
      context.push('/nfts/${tag.id}', extra: tag);
    }
  }
}

// =============================================================================
// Created Tab
// =============================================================================

class _CreatedTab extends ConsumerWidget {
  final VoidCallback onCreateCollection;

  const _CreatedTab({required this.onCreateCollection});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagState = ref.watch(tagProvider);
    final nftTags = ref.watch(nftTagsProvider);

    if (tagState.isLoading) return _buildShimmer(context);
    if (nftTags.isEmpty) return _buildEmpty(context);
    return _buildList(context, ref, nftTags);
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.gem, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No NFT collections yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create your first NFT collection',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onCreateCollection,
            icon: const Icon(LucideIcons.plus),
            label: const Text('Create Collection'),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmer(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: 3,
        itemBuilder: (context, index) {
          return ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            title: Container(
              height: 14,
              width: 120,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            subtitle: Container(
              height: 10,
              width: 80,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, List<FileTag> tags) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: tags.length,
      itemBuilder: (context, index) {
        final tag = tags[index];
        return _NftCollectionTile(
          tag: tag,
          onTap: () => context.push('/nfts/${tag.id}', extra: tag),
          onDelete: () => _deleteCollection(context, ref, tag),
        );
      },
    );
  }

  Future<void> _deleteCollection(
      BuildContext context, WidgetRef ref, FileTag tag) async {
    final displayName = tag.name.replaceFirst('nft-', '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Collection'),
        content: Text(
          'Are you sure you want to delete "$displayName"? '
          'This will remove the collection and all local NFT records.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(nftProvider.notifier).deleteCollection(tag.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "$displayName"')),
        );
      }
    }
  }
}

// =============================================================================
// Received Tab
// =============================================================================

class _ReceivedTab extends ConsumerStatefulWidget {
  const _ReceivedTab();

  @override
  ConsumerState<_ReceivedTab> createState() => _ReceivedTabState();
}

class _ReceivedTabState extends ConsumerState<_ReceivedTab> {
  String? _internalAddress;
  bool _loadedWallets = false;

  @override
  void initState() {
    super.initState();
    _loadWallets();
  }

  Future<void> _loadWallets() async {
    final address = await NftWalletService.instance.getAddress();
    if (!mounted) return;

    // Load linked wallets from billing if not already loaded
    final billingState = ref.read(billingProvider);
    if (billingState.wallets.isEmpty && !billingState.isLoading) {
      ref.read(billingProvider.notifier).loadBillingData();
    }

    setState(() {
      _internalAddress = address;
      _loadedWallets = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final receivedNfts = ref.watch(receivedNftsProvider);
    final billingState = ref.watch(billingProvider);
    final linkedWallets = billingState.wallets;

    return ListView(
      padding: const EdgeInsets.only(bottom: 80),
      children: [
        // Wallets section
        _buildWalletsSection(context, linkedWallets),
        const Divider(height: 1),

        // Received NFTs
        if (!_loadedWallets)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (receivedNfts.isEmpty)
          _buildReceivedEmpty(context)
        else
          ...receivedNfts.map((nft) => _ReceivedNftTile(
                nft: nft,
                onTap: () => context.push(
                  '/nft-claim?chain=${nft.chainId}&contract=${nft.contractAddress}&token=${nft.tokenId}&receivedId=${nft.id}',
                ),
              )),
      ],
    );
  }

  Widget _buildWalletsSection(BuildContext context, List<WalletInfo> linkedWallets) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Wallets',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),

          // Internal wallet
          if (_internalAddress != null)
            _WalletChip(
              label: 'Internal',
              address: _internalAddress!,
              icon: LucideIcons.key,
            ),

          // Linked wallets
          ...linkedWallets.map((w) {
            final chain = SupportedChain.byChainId(w.chainId);
            return _WalletChip(
              label: chain?.chainName ?? 'Chain ${w.chainId}',
              address: w.address,
              icon: LucideIcons.wallet,
            );
          }),

          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () => _linkWallet(context),
            icon: const Icon(LucideIcons.plus, size: 16),
            label: const Text('Link Wallet'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceivedEmpty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          children: [
            Icon(LucideIcons.inbox, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              'No received NFTs yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'NFTs you claim will appear here',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _linkWallet(BuildContext context) async {
    final success = await ref.read(billingProvider.notifier).linkWallet(context);
    if (!mounted) return;
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wallet linked successfully!')),
      );
    } else {
      final error = ref.read(billingProvider).error;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
      }
    }
  }
}

// =============================================================================
// Tiles & Chips
// =============================================================================

class _WalletChip extends StatelessWidget {
  final String label;
  final String address;
  final IconData icon;

  const _WalletChip({
    required this.label,
    required this.address,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final short = address.length > 14
        ? '${address.substring(0, 8)}...${address.substring(address.length - 6)}'
        : address;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey[600]),
          const SizedBox(width: 6),
          Text(
            '$label:',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            short,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[500],
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _NftCollectionTile extends StatelessWidget {
  final FileTag tag;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _NftCollectionTile({
    required this.tag,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(tag.colorValue);
    final displayName = tag.name.replaceFirst('nft-', '');

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Icon(LucideIcons.gem, size: 20),
        ),
      ),
      title: Text(displayName),
      subtitle: Text(
        '${tag.fileCount} asset${tag.fileCount == 1 ? '' : 's'}',
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'delete') onDelete();
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(LucideIcons.trash2, size: 18, color: Colors.red),
                SizedBox(width: 8),
                Text('Delete', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _ReceivedNftTile extends StatelessWidget {
  final ReceivedNft nft;
  final VoidCallback onTap;

  const _ReceivedNftTile({
    required this.nft,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chain = SupportedChain.byChainId(nft.chainId);
    final chainName = chain?.chainName ?? 'Chain ${nft.chainId}';
    final displayName = nft.eventName.isNotEmpty ? nft.eventName : 'Token #${nft.tokenId}';

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.purple.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Icon(LucideIcons.download, size: 20, color: Colors.purple),
        ),
      ),
      title: Text(displayName),
      subtitle: Text(
        '$chainName \u2022 Token #${nft.tokenId}',
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      ),
      trailing: const Icon(LucideIcons.chevronRight, size: 18),
      onTap: onTap,
    );
  }
}
