import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/web/services/web_nft_service.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

/// Mirror of lib/features/nft/screens/nft_detail_screen.dart for the
/// web shell: minted-NFT cards with Share Claim, and the Mint NFT
/// flow (pick an image → the native mint-config sheet fields →
/// progress) — internal wallet only on web.
class WebNftDetailScreen extends StatefulWidget {
  final String tagId;
  const WebNftDetailScreen({super.key, required this.tagId});

  @override
  State<WebNftDetailScreen> createState() => _WebNftDetailScreenState();
}

class _WebNftDetailScreenState extends State<WebNftDetailScreen> {
  bool _loading = true;
  bool _minting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WebNftService.instance.addListener(_onTick);
    _load();
  }

  @override
  void dispose() {
    WebNftService.instance.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await WebTagService.instance.load();
      // SWR: cached manifest; mint/claim flows mutate through the
      // service, whose write-through keeps the cache current.
      await WebNftService.instance.load();
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

  String get _displayName {
    final collection = WebNftService.instance.collectionByTagId(widget.tagId);
    if (collection != null) return collection.name;
    final tag = WebTagService.instance.tagById(widget.tagId);
    final name = tag?.name ?? 'collection';
    return name.startsWith('nft-') ? name.substring('nft-'.length) : name;
  }

  List<NftMintRecord> get _mints {
    final collection = WebNftService.instance.collectionByTagId(widget.tagId);
    if (collection == null) return const [];
    final mints = List<NftMintRecord>.from(collection.mints)
      ..sort((a, b) => b.mintedAt.compareTo(a.mintedAt));
    return mints;
  }

  /// Creator transactions go through the connected wallet; open the
  /// AppKit modal when none is connected yet. Returns false when the
  /// user closed it without connecting.
  Future<bool> _ensureWalletConnected() async {
    if (WalletService.instance.isConnected) return true;
    try {
      if (!WalletService.instance.isInitialized) {
        await WalletService.instance.initialize(context);
      }
      if (!mounted) return false;
      await WalletService.instance.connectWallet(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Wallet connection failed: $e')));
      }
      return false;
    }
    if (!WalletService.instance.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Connect a wallet to continue')));
      }
      return false;
    }
    return true;
  }

  Future<void> _startMintFlow() async {
    if (!await _ensureWalletConnected() || !mounted) return;
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.image,
    );
    final file = picked?.files.firstOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null || !mounted) return;

    final config = await _showMintConfigDialog(file.name);
    if (config == null || !mounted) return;

    setState(() => _minting = true);
    var status = 'Starting...';
    var dialogOpen = true;
    void Function(void Function())? setDialog;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          setDialog = setLocal;
          return AlertDialog(
            title: const Text('Minting NFT'),
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text(status)),
              ],
            ),
          );
        },
      ),
    ).then((_) => dialogOpen = false);

    try {
      await WebNftService.instance.startMint(
        tagId: widget.tagId,
        bytes: bytes,
        fileName: file.name,
        collectionName: _displayName,
        chain: config.chain,
        count: config.count,
        fulaPerNft: config.fulaPerNft,
        eventName: config.eventName,
        royaltyBps: config.royaltyBps,
        onStatus: (s) {
          status = s;
          setDialog?.call(() {});
        },
      );
      if (mounted && dialogOpen) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('NFT minted successfully')));
      }
    } catch (e) {
      if (mounted && dialogOpen) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Mint failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _minting = false);
    }
  }

  /// Mint config — same fields as the native mint-config sheet (event
  /// name, count, FULA per NFT, chain, royalty).
  Future<
      ({
        String eventName,
        int count,
        String fulaPerNft,
        SupportedChain chain,
        int royaltyBps,
      })?> _showMintConfigDialog(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final eventController = TextEditingController(
        text: dot > 0 ? fileName.substring(0, dot) : fileName);
    final countController = TextEditingController(text: '1');
    final fulaController = TextEditingController(text: '10');
    final royaltyController = TextEditingController(text: '0');
    final deployedChains = SupportedChain.all
        .where((c) =>
            c.nftContractAddress != null &&
            c.nftContractAddress !=
                '0x0000000000000000000000000000000000000000')
        .toList();
    var chain = deployedChains.firstOrNull;
    String? error;

    return showDialog<
        ({
          String eventName,
          int count,
          String fulaPerNft,
          SupportedChain chain,
          int royaltyBps,
        })>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Mint NFTs'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: eventController,
                    maxLength: 128,
                    decoration: const InputDecoration(
                      labelText: 'Event / Category',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: countController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'NFTs to mint',
                      helperText: 'How many copies of this NFT.',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: fulaController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Lock FULA per NFT',
                      helperText:
                          'FULA stays inside the NFT. The only way to get '
                          'it back is to burn the NFT.',
                      helperMaxLines: 3,
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<SupportedChain>(
                    initialValue: chain,
                    decoration: const InputDecoration(
                      labelText: 'Chain',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final c in deployedChains)
                        DropdownMenuItem(
                            value: c, child: Text(c.chainName)),
                    ],
                    onChanged: (v) => setLocal(() => chain = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: royaltyController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Royalty % (advanced)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error!,
                        style: const TextStyle(
                            color: AppColors.error, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () {
                final eventName = eventController.text.trim();
                final count = int.tryParse(countController.text.trim());
                final royalty =
                    int.tryParse(royaltyController.text.trim()) ?? 0;
                if (eventName.isEmpty) {
                  setLocal(() => error = 'Event name is required');
                  return;
                }
                if (count == null || count < 1 || count > 10000) {
                  setLocal(
                      () => error = 'Count must be between 1 and 10,000');
                  return;
                }
                final c = chain;
                if (c == null) {
                  setLocal(() => error =
                      'NFT contract not yet deployed. Minting will be available soon.');
                  return;
                }
                Navigator.pop(ctx, (
                  eventName: eventName,
                  count: count,
                  fulaPerNft: fulaController.text.trim().isEmpty
                      ? '0'
                      : fulaController.text.trim(),
                  chain: c,
                  royaltyBps: (royalty.clamp(0, 100)) * 100,
                ));
              },
              child: const Text('Mint NFT'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareClaim(NftMintRecord mint) async {
    if (!await _ensureWalletConnected() || !mounted) return;
    final expiryDays = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
                title: Text('Claim link expires in',
                    style: TextStyle(fontWeight: FontWeight.w600))),
            for (final d in [1, 7, 30])
              ListTile(
                leading: const Icon(LucideIcons.clock, size: 18),
                title: Text(d == 1 ? '1 day' : '$d days'),
                onTap: () => Navigator.of(ctx).pop(d),
              ),
          ],
        ),
      ),
    );
    if (expiryDays == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Creating claim offer…')));
    try {
      final result = await WebNftService.instance.createClaimOffer(
        tagId: widget.tagId,
        mint: mint,
        expiry: Duration(days: expiryDays),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(LucideIcons.checkCircle, color: Colors.green),
              SizedBox(width: 8),
              Expanded(child: Text('Claim Link Created!')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Send this link to the recipient — opening it claims '
                  'one copy of the NFT.'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  result.claimLink,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result.claimLink));
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('Link copied to clipboard')));
                Navigator.pop(ctx);
              },
              icon: const Icon(LucideIcons.copy),
              label: const Text('Copy Link'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not create claim link: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mints = _mints;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/nfts'),
        ),
        title: Text(_displayName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load collection.\n$_error'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _minting ? null : _startMintFlow,
                            style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary),
                            icon: const Icon(LucideIcons.sparkles, size: 18),
                            label:
                                Text(_minting ? 'Minting...' : 'Mint NFT'),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text('Minted NFTs',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        if (mints.isEmpty)
                          Container(
                            width: double.infinity,
                            padding:
                                const EdgeInsets.symmetric(vertical: 28),
                            decoration: BoxDecoration(
                              color: theme
                                  .colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                const Icon(LucideIcons.gem, size: 36),
                                const SizedBox(height: 8),
                                Text('No NFTs minted yet',
                                    style: theme.textTheme.titleSmall),
                                const SizedBox(height: 4),
                                Text('Mint an image to get started',
                                    style: theme.textTheme.bodySmall),
                              ],
                            ),
                          )
                        else
                          for (final m in mints) _mintCard(theme, m),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _mintCard(ThemeData theme, NftMintRecord m) {
    final chain = SupportedChain.byChainId(m.chainId);
    final (statusColor, statusLabel) = switch (m.status) {
      NftMintStatus.approving => (Colors.orange, 'Approving'),
      NftMintStatus.minting => (Colors.blue, 'Minting'),
      NftMintStatus.confirming => (Colors.blue, 'Confirming'),
      NftMintStatus.completed => (Colors.green, 'Completed'),
      NftMintStatus.error => (Colors.red, 'Error'),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (m.gatewayUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      m.gatewayUrl!,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 64,
                        height: 64,
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(LucideIcons.gem),
                      ),
                    ),
                  )
                else
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(LucideIcons.gem),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.eventName.isNotEmpty ? m.eventName : 'NFT',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (m.tokenId != null) 'Token #${m.tokenId}',
                          '${m.count} cop${m.count == 1 ? 'y' : 'ies'}',
                          '${m.fulaPerNft} FULA/NFT',
                          if (chain != null) chain.chainName,
                        ].join('  ·  '),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: statusColor),
                            ),
                          ),
                          if (m.claims.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Text(
                              '${m.claims.length} claim link${m.claims.length == 1 ? '' : 's'}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (m.status == NftMintStatus.error &&
                m.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(m.errorMessage!,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.error)),
            ],
            if (m.status == NftMintStatus.completed) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(LucideIcons.share2, size: 14),
                    label: const Text('Share Claim'),
                    onPressed: () => _shareClaim(m),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
