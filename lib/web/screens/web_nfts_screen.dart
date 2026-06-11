import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/web/services/web_nft_service.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

/// Mirror of lib/features/nft/screens/nfts_browser_screen.dart:
/// Created (collections, `nft-` tags) and Received tabs, the New NFT
/// Collection flow, and the internal-wallet chip. Web v1 notes: the
/// internal wallet is the same address as in the app (same
/// derivation); received NFTs claimed on web are session-listed (the
/// app keeps them device-local too).
class WebNftsScreen extends StatefulWidget {
  const WebNftsScreen({super.key});

  @override
  State<WebNftsScreen> createState() => _WebNftsScreenState();
}

class _WebNftsScreenState extends State<WebNftsScreen> {
  bool _loading = true;
  String? _error;
  StreamSubscription<WalletConnectionEvent>? _walletSub;

  @override
  void initState() {
    super.initState();
    WebNftService.instance.addListener(_onTick);
    _walletSub =
        WalletService.instance.onConnectionChange.listen((_) => _onTick());
    // AppKit needs a context once; idempotent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        WalletService.instance.initialize(context).catchError((e) {
          debugPrint('Wallet init note: $e');
        });
      }
    });
    _load();
  }

  @override
  void dispose() {
    WebNftService.instance.removeListener(_onTick);
    _walletSub?.cancel();
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await WebTagService.instance.load(force: true);
      await WebNftService.instance.load(force: true);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _connectWallet() async {
    try {
      if (!WalletService.instance.isInitialized) {
        await WalletService.instance.initialize(context);
      }
      if (!mounted) return;
      await WalletService.instance.connectWallet(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Wallet connection failed: $e')));
      }
    }
  }

  Future<void> _createCollection() async {
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
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
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
    if (result == null || result.trim().isEmpty || !mounted) return;
    try {
      final collection =
          await WebNftService.instance.createCollection(result.trim());
      if (mounted) context.go('/nfts/${collection.tagId}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not create collection: $e')));
      }
    }
  }

  /// Collection rows: manifest collections + nft- tags not yet in the
  /// manifest (created in the app before its first mint).
  List<({String tagId, String name, int? colorValue, int mintCount})>
      get _rows {
    final out =
        <String, ({String tagId, String name, int? colorValue, int mintCount})>{};
    for (final c in WebNftService.instance.collections) {
      final tag = WebTagService.instance.tagById(c.tagId);
      out[c.tagId] = (
        tagId: c.tagId,
        name: c.name,
        colorValue: tag?.colorValue,
        mintCount: c.mints.length,
      );
    }
    for (final t in WebTagService.instance.tags
        .where((t) => t.name.startsWith('nft-'))) {
      out.putIfAbsent(
          t.id,
          () => (
                tagId: t.id,
                name: t.name.substring('nft-'.length),
                colorValue: t.colorValue,
                mintCount: 0,
              ));
    }
    return out.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/'),
          ),
          title: const Text('NFTs'),
          actions: [
            // Creator transactions (mint, claim offers) run through the
            // CONNECTED wallet — same AppKit modal as the app.
            if (WalletService.instance.isConnected &&
                WalletService.instance.connectedAddress != null)
              Tooltip(
                message: 'Connected wallet — tap to copy address',
                child: TextButton.icon(
                  onPressed: () {
                    final address =
                        WalletService.instance.connectedAddress!;
                    Clipboard.setData(ClipboardData(text: address));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Wallet address copied')));
                  },
                  icon: const Icon(LucideIcons.wallet,
                      size: 16, color: AppColors.primary),
                  label: Builder(builder: (context) {
                    final address =
                        WalletService.instance.connectedAddress!;
                    return Text(
                      '${address.substring(0, 6)}…${address.substring(address.length - 4)}',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    );
                  }),
                ),
              )
            else
              TextButton.icon(
                onPressed: _connectWallet,
                icon: const Icon(LucideIcons.wallet, size: 16),
                label: const Text('Connect Wallet',
                    style: TextStyle(fontSize: 12)),
              ),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _load,
            ),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: 'Created'), Tab(text: 'Received')],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _createCollection,
          child: const Icon(LucideIcons.plus),
        ),
        body: _error != null
            ? Center(child: Text('Could not load NFTs.\n$_error'))
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    children: [
                      _createdTab(theme),
                      _receivedTab(theme),
                    ],
                  ),
      ),
    );
  }

  Widget _createdTab(ThemeData theme) {
    final rows = _rows;
    if (rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.gem, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('No NFT collections yet',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Create a collection and mint images as NFTs',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _createCollection,
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.primary),
              icon: const Icon(LucideIcons.plus),
              label: const Text('New NFT Collection'),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: rows.length,
      itemBuilder: (ctx, i) {
        final row = rows[i];
        final color = row.colorValue != null
            ? Color(row.colorValue!)
            : theme.colorScheme.primary;
        return ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(child: Icon(LucideIcons.gem, size: 20)),
          ),
          title: Text(row.name, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${row.mintCount} mint${row.mintCount == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 12),
          ),
          onTap: () => context.go('/nfts/${row.tagId}'),
        );
      },
    );
  }

  Widget _receivedTab(ThemeData theme) {
    final received = WebNftService.instance.receivedNfts;
    if (received.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.inbox, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text('No received NFTs', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'NFTs you claim in this browser session appear here. '
                'Open a claim link to get started.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: received.length,
      itemBuilder: (ctx, i) {
        final nft = received[i];
        return ListTile(
          leading: nft.gatewayUrl != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    nft.gatewayUrl!,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(LucideIcons.gem, size: 24),
                  ),
                )
              : const Icon(LucideIcons.gem, size: 24),
          title: Text(
              nft.eventName.isNotEmpty ? nft.eventName : 'Token #${nft.tokenId}',
              overflow: TextOverflow.ellipsis),
          subtitle: Text(
            'Token #${nft.tokenId}  ·  ${nft.fulaPerNft} FULA locked',
            style: const TextStyle(fontSize: 12),
          ),
        );
      },
    );
  }
}
