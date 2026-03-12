import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/features/nft/providers/nft_provider.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/nft_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';
import 'package:fula_files/features/nft/widgets/claim_link_share_sheet.dart';
import 'package:fula_files/features/nft/widgets/mint_config_dialog.dart';
import 'package:fula_files/features/nft/widgets/address_qr_scanner_dialog.dart';
import 'package:fula_files/features/nft/widgets/nft_card.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';

/// Detail screen for a single NFT collection: shows assets + minted NFTs
class NftDetailScreen extends ConsumerStatefulWidget {
  final String tagId;
  final FileTag? tag;

  const NftDetailScreen({
    super.key,
    required this.tagId,
    this.tag,
  });

  @override
  ConsumerState<NftDetailScreen> createState() => _NftDetailScreenState();
}

class _NftDetailScreenState extends ConsumerState<NftDetailScreen> {
  @override
  void initState() {
    super.initState();
    // Eagerly derive internal wallet so hasWallet is true for UI checks
    // Must ensure auth is restored first so encryption key is available
    AuthService.instance.ensureAuthRestored().then((_) {
      NftWalletService.instance.getAddress();
    });
    // Reconcile burn counts from on-chain balance for completed mints
    _reconcileBurnCounts();
  }

  Future<void> _reconcileBurnCounts() async {
    final mints = NftService.instance.getMintsForTag(widget.tagId);
    for (final mint in mints) {
      if (mint.status == NftMintStatus.completed && mint.tokenId != null) {
        await NftService.instance.reconcileBurnCount(
          tagId: widget.tagId,
          mint: mint,
        );
      }
    }
  }

  int _heldCount(NftMintRecord mint) {
    int pendingLinks = 0;
    int claimed = 0;
    int claimBurned = 0;
    for (final claim in mint.claims) {
      final isExpired = claim.status == NftClaimStatus.expired ||
          (claim.status == NftClaimStatus.pending &&
              claim.expiresAt.isBefore(DateTime.now()));
      if (claim.status == NftClaimStatus.claimed) {
        claimed++;
      } else if (claim.status == NftClaimStatus.burned) {
        claimBurned++;
      } else if (claim.status == NftClaimStatus.pending && !isExpired) {
        pendingLinks++;
      }
    }
    return mint.count - pendingLinks - claimed - claimBurned - mint.creatorBurned;
  }

  /// Run [operation] while showing a modal progress dialog with a Cancel button.
  /// The dialog reactively shows the provider's statusMessage.
  /// Returns the result, or null if the user cancelled.
  Future<T?> _withProgressDialog<T>({
    required String title,
    required Future<T?> Function() operation,
  }) async {
    var cancelled = false;

    // Show a non-dismissible dialog with cancel button
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: Consumer(
          builder: (ctx, dialogRef, _) {
            final nftState = dialogRef.watch(nftProvider);
            final statusMessage = nftState.statusMessage;
            final isWalletStep = statusMessage != null &&
                statusMessage.toLowerCase().contains('in your wallet');
            final showOpenWallet = isWalletStep &&
                WalletService.instance.isConnected;
            final walletName =
                WalletService.instance.connectedWalletName ?? 'Wallet';
            return AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(statusMessage ?? title),
                  if (showOpenWallet) ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => WalletService.instance.tryOpenWallet(),
                      icon: const Icon(LucideIcons.externalLink, size: 16),
                      label: Text('Open $walletName'),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    ref.read(nftProvider.notifier).cancelOperation();
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        ),
      ),
    );

    final result = await operation();

    // Dismiss the progress dialog if still showing
    if (mounted && !cancelled) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    if (cancelled) return null;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final tagState = ref.watch(tagProvider);
    final currentTag = widget.tag ??
        tagState.tags.where((t) => t.id == widget.tagId).firstOrNull;
    final displayName =
        (currentTag?.name ?? 'NFT Collection').replaceFirst('nft-', '');
    final tagColor =
        currentTag != null ? Color(currentTag.colorValue) : Colors.pink;

    final taggedFilesAsync = ref.watch(taggedFilesProvider(widget.tagId));
    final mintsAsync = ref.watch(nftMintsProvider(widget.tagId));

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: tagColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(displayName),
          ],
        ),
        actions: [
          taggedFilesAsync.when(
            data: (files) => IconButton(
              icon: const Icon(LucideIcons.plus),
              tooltip: files.isEmpty ? 'Import image' : 'Replace image',
              onPressed: files.isEmpty ? () => _pickImages() : null,
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: ListView(
        children: [
          // Section A: Asset (single image per collection)
          _buildAssetsSection(context, taggedFilesAsync),

          // Section B: Mint button + status
          taggedFilesAsync.when(
            data: (files) {
              if (files.isEmpty) return const SizedBox.shrink();
              final nftState = ref.watch(nftProvider);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  children: [
                    FilledButton.icon(
                      onPressed: nftState.isMinting
                          ? null
                          : () => _startMintFlow(files),
                      icon: nftState.isMinting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(LucideIcons.sparkles),
                      label: Text(nftState.isMinting ? 'Minting...' : 'Mint NFT'),
                    ),
                    if (nftState.statusMessage != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Colors.grey[500],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            nftState.statusMessage!,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),

          // Section C: Minted NFTs
          _buildMintsSection(context, mintsAsync),
        ],
      ),
    );
  }

  // ============================================================================
  // ASSETS SECTION
  // ============================================================================

  Widget _buildAssetsSection(
      BuildContext context, AsyncValue<List<TaggedFile>> taggedFilesAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                'Assets',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _pickImages(),
                icon: const Icon(LucideIcons.imagePlus, size: 16),
                label: const Text('Import'),
              ),
            ],
          ),
        ),
        taggedFilesAsync.when(
          data: (files) {
            if (files.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Column(
                    children: [
                      Icon(LucideIcons.imageOff, size: 48, color: Colors.grey[400]),
                      const SizedBox(height: 12),
                      Text(
                        'No assets yet',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Import images to mint as NFTs',
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                    ],
                  ),
                ),
              );
            }

            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                return _NftAssetTile(
                  taggedFile: file,
                  onRemove: () => _removeAsset(file),
                );
              },
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Error: $error'),
          ),
        ),
        const Divider(),
      ],
    );
  }

  // ============================================================================
  // MINTED NFTS SECTION
  // ============================================================================

  Widget _buildMintsSection(
      BuildContext context, AsyncValue<List<NftMintRecord>> mintsAsync) {
    return mintsAsync.when(
      data: (mints) {
        if (mints.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Text(
                    'Minted NFTs',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _refreshAllOnChainData(mints),
                    child: Icon(LucideIcons.refreshCw, size: 16, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            ...mints.map((mint) {
              final hasHeldCopies = mint.status == NftMintStatus.completed &&
                  mint.tokenId != null &&
                  _heldCount(mint) > 0;
              return NftCard(
                record: mint,
                onShareClaim: hasHeldCopies
                    ? () => _showClaimSheet(mint)
                    : null,
                onRetry: mint.status == NftMintStatus.error
                    ? () => _retryMint(mint)
                    : null,
                onBurn: hasHeldCopies
                    ? () => _burnMint(mint)
                    : null,
                onCancelClaim: (claim) => _cancelClaim(mint, claim),
              );
            }),
            const SizedBox(height: 80),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  // ============================================================================
  // MINT FLOW
  // ============================================================================

  Future<void> _startMintFlow(List<TaggedFile> files) async {
    // Show mint config dialog
    final config = await showMintConfigDialog(context);
    if (config == null || !mounted) return;

    // Pick wallet source
    final walletSource = await _showWalletPicker();
    if (walletSource == null || !mounted) return;

    // Resolve the first tagged file to use as the NFT asset
    final firstFile = files.first;
    final localPath = firstFile.localPath;
    if (localPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No local file to mint')),
      );
      return;
    }

    final result = await _withProgressDialog<NftMintRecord>(
      title: 'Preparing...',
      operation: () async {
        final resolvedPath = await _resolveFilePath(localPath);

        final tagState = ref.read(tagProvider);
        final currentTag = widget.tag ??
            tagState.tags.where((t) => t.id == widget.tagId).firstOrNull;
        final collectionName =
            (currentTag?.name ?? 'NFT Collection').replaceFirst('nft-', '');

        return ref.read(nftProvider.notifier).startMint(
          tagId: widget.tagId,
          localPath: resolvedPath,
          fileName: firstFile.fileName,
          collectionName: collectionName,
          chain: config.chain,
          count: config.count,
          fulaPerNft: config.fulaPerNft,
          eventName: config.eventName,
          royaltyBps: config.royaltyBps,
          walletSource: walletSource,
        );
      },
    );

    if (!mounted) return;
    if (result != null && result.status == NftMintStatus.completed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Minted Token #${result.tokenId ?? "?"}')),
      );
    } else {
      final nftState = ref.read(nftProvider);
      if (nftState.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Mint failed: ${nftState.error}')),
        );
      }
    }
  }

  Future<void> _retryMint(NftMintRecord mint) async {
    final chain = SupportedChain.byChainId(mint.chainId);
    if (chain == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unknown chain')),
      );
      return;
    }

    final result = await _withProgressDialog<NftMintRecord>(
      title: 'Retrying mint...',
      operation: () => ref.read(nftProvider.notifier).retryMint(
        tagId: widget.tagId,
        record: mint,
        chain: chain,
      ),
    );

    if (!mounted) return;
    if (result != null && result.status == NftMintStatus.completed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Retry successful! Token #${result.tokenId ?? "?"}')),
      );
    } else {
      final nftState = ref.read(nftProvider);
      if (nftState.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Retry failed: ${nftState.error}')),
        );
      }
    }
  }

  Future<void> _showClaimSheet(NftMintRecord mint) async {
    // Prompt for claimer address + expiry, with "Anyone can claim" toggle
    final claimerController = TextEditingController();
    final result = await showDialog<({String? address, Duration expiry})?>(
      context: context,
      builder: (ctx) {
        var expiryDays = 7;
        var openClaim = true;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Create Claim Offer'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Anyone can claim'),
                    subtitle: Text(
                      openClaim
                          ? 'First person to open the link claims it'
                          : 'Only the specified wallet can claim',
                      style: const TextStyle(fontSize: 12),
                    ),
                    value: openClaim,
                    onChanged: (v) => setDialogState(() => openClaim = v),
                  ),
                  if (!openClaim) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: claimerController,
                      decoration: InputDecoration(
                        labelText: 'Claimer Wallet Address',
                        hintText: '0x...',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(LucideIcons.wallet),
                        suffixIcon: IconButton(
                          icon: const Icon(LucideIcons.scanLine, size: 20),
                          tooltip: 'Scan QR code',
                          onPressed: () async {
                            final address = await showAddressQrScannerDialog(ctx);
                            if (address != null) {
                              claimerController.text = address;
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    value: expiryDays,
                    decoration: const InputDecoration(
                      labelText: 'Expires in',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(LucideIcons.clock),
                    ),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1 day')),
                      DropdownMenuItem(value: 7, child: Text('7 days')),
                      DropdownMenuItem(value: 30, child: Text('30 days')),
                      DropdownMenuItem(value: 90, child: Text('90 days')),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => expiryDays = v);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (openClaim) {
                      Navigator.of(ctx).pop((address: null, expiry: Duration(days: expiryDays)));
                    } else {
                      final addr = claimerController.text.trim();
                      if (RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(addr)) {
                        Navigator.of(ctx).pop((address: addr, expiry: Duration(days: expiryDays)));
                      } else {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Enter a valid 0x address (42 characters)')),
                        );
                      }
                    }
                  },
                  child: const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );

    // Dispose after dialog animation completes
    Future.delayed(const Duration(milliseconds: 300), () => claimerController.dispose());

    if (result == null || !mounted) return;

    final walletSource = await _showWalletPicker();
    if (walletSource == null || !mounted) return;

    final offerResult = await _withProgressDialog<({String linkHash, String claimLink})>(
      title: 'Creating claim offer...',
      operation: () => ref.read(nftProvider.notifier).createClaimOffer(
        tagId: widget.tagId,
        mint: mint,
        claimerAddress: result.address,
        expiry: result.expiry,
        walletSource: walletSource,
      ),
    );

    if (!mounted) return;
    if (offerResult != null) {
      final chain = SupportedChain.byChainId(mint.chainId);
      await showClaimLinkShareSheet(
        context,
        claimLink: offerResult.claimLink,
        tokenId: mint.tokenId!,
        chainName: chain?.chainName ?? 'Unknown',
      );
    } else {
      final nftState = ref.read(nftProvider);
      if (nftState.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${nftState.error}')),
        );
      }
    }
  }

  // ============================================================================
  // REFRESH CLAIM STATUSES
  // ============================================================================

  Future<void> _refreshAllOnChainData(List<NftMintRecord> mints) async {
    for (final mint in mints) {
      if (mint.status != NftMintStatus.completed || mint.tokenId == null) continue;

      // Reconcile burn counts from on-chain balance
      await NftService.instance.reconcileBurnCount(
        tagId: widget.tagId,
        mint: mint,
      );

      // Refresh pending claim statuses
      if (mint.claims.any((c) => c.status == NftClaimStatus.pending)) {
        await ref.read(nftProvider.notifier).refreshClaimStatuses(
          tagId: widget.tagId,
          mint: mint,
        );
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('On-chain data refreshed')),
      );
    }
  }

  // ============================================================================
  // BURN FLOW
  // ============================================================================

  Future<void> _burnMint(NftMintRecord mint) async {
    final chain = SupportedChain.byChainId(mint.chainId);
    final fulaAmount = mint.fulaPerNft;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Burn NFT'),
        content: Text(
          'This will burn 1 NFT (Token #${mint.tokenId}) and release $fulaAmount FULA to the NFT creator.\n\nThis action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Burn'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final walletSource = await _showWalletPicker();
    if (walletSource == null || !mounted) return;

    final txHash = await _withProgressDialog<String>(
      title: 'Burning NFT...',
      operation: () => ref.read(nftProvider.notifier).burnNft(
        chainId: mint.chainId,
        tokenId: mint.tokenId!,
        amount: 1,
        walletSource: walletSource,
      ),
    );

    if (!mounted) return;
    if (txHash != null) {
      await NftService.instance.markCreatorBurned(
        tagId: widget.tagId,
        mint: mint,
        amount: 1,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NFT burned successfully')),
      );
    } else {
      final nftState = ref.read(nftProvider);
      if (nftState.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Burn failed: ${nftState.error}')),
        );
      }
    }
  }

  // ============================================================================
  // CANCEL CLAIM
  // ============================================================================

  Future<void> _cancelClaim(NftMintRecord mint, NftClaimRecord claim) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Claim Offer'),
        content: const Text(
          'This will cancel the claim link and return the escrowed NFT to your wallet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel Offer'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final walletSource = await _showWalletPicker();
    if (walletSource == null || !mounted) return;

    final success = await _withProgressDialog<bool>(
      title: 'Cancelling claim offer...',
      operation: () => ref.read(nftProvider.notifier).cancelClaimOffer(
        tagId: widget.tagId,
        mint: mint,
        claim: claim,
        walletSource: walletSource,
      ),
    );

    if (!mounted) return;
    if (success == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Claim offer cancelled')),
      );
    } else {
      final nftState = ref.read(nftProvider);
      if (nftState.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cancel failed: ${nftState.error}')),
        );
      }
    }
  }

  // ============================================================================
  // WALLET PICKER
  // ============================================================================

  Future<WalletSource?> _showWalletPicker() async {
    String? internalAddress;
    bool externalConnected = false;

    // Show a loading dialog while wallets are being resolved
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading wallets...'),
            ],
          ),
        ),
      ),
    );

    // Try up to 3 times with increasing waits for auth to restore
    for (var attempt = 0; attempt < 3; attempt++) {
      await AuthService.instance.ensureAuthRestored();
      internalAddress = await NftWalletService.instance.getAddress();

      if (!WalletService.instance.isInitialized && mounted) {
        try {
          await WalletService.instance.initialize(context);
        } catch (_) {}
      }

      externalConnected = WalletService.instance.isConnected;

      if (internalAddress != null || externalConnected) break;
      if (attempt < 2) {
        // Wait briefly for auth session to finish restoring
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    // Dismiss loading dialog
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    if (!mounted) return null;

    final externalAddress = WalletService.instance.connectedAddress;

    // No wallet at all after retries
    if (internalAddress == null && !externalConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No wallet available. Sign in or connect a wallet.')),
      );
      return null;
    }

    // Use a special sentinel to indicate "connect external wallet" was chosen
    const connectSentinel = WalletSource.external;

    // Always show the picker so the user can choose or connect
    final choice = await showDialog<WalletSource?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose Wallet'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (internalAddress != null)
              ListTile(
                leading: const Icon(LucideIcons.keyRound),
                title: const Text('Internal Wallet'),
                subtitle: Text(
                  _truncateAddress(internalAddress),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                onTap: () => Navigator.of(ctx).pop(WalletSource.internal),
              ),
            if (internalAddress != null && (externalConnected || WalletService.instance.isInitialized))
              const SizedBox(height: 4),
            if (externalConnected)
              ListTile(
                leading: const Icon(LucideIcons.wallet),
                title: const Text('Connected Wallet'),
                subtitle: Text(
                  _truncateAddress(externalAddress!),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                onTap: () => Navigator.of(ctx).pop(WalletSource.external),
              ),
            if (!externalConnected && WalletService.instance.isInitialized)
              ListTile(
                leading: const Icon(LucideIcons.link2),
                title: const Text('Connect External Wallet'),
                subtitle: const Text('MetaMask, Trust Wallet, etc.'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                // Pop with external as a signal to trigger connect flow
                onTap: () => Navigator.of(ctx).pop(connectSentinel),
              ),
          ],
        ),
      ),
    );

    if (choice == null) return null;

    // If external was chosen but no wallet was connected, trigger connect flow
    if (choice == WalletSource.external && !WalletService.instance.isConnected) {
      if (!mounted) return null;
      final address = await WalletService.instance.connectWallet(context);
      if (address == null || !mounted) return null;
      return WalletSource.external;
    }

    return choice;
  }

  static String _truncateAddress(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 8)}...${address.substring(address.length - 6)}';
  }

  // ============================================================================
  // IMPORT FLOW (images only for NFTs)
  // ============================================================================

  Future<void> _pickImages() async {
    // Prevent importing if collection already has an asset
    final existing = await TagStorageService.instance.getFilesWithTag(widget.tagId);
    if (existing.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Collection already has an image. Remove it first to replace.')),
        );
      }
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      await _importPickedFiles(result.files);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick images: $e')),
        );
      }
    }
  }

  Future<void> _importPickedFiles(List<PlatformFile> files) async {
    final appDir = await getApplicationDocumentsDirectory();
    final importedDir = Directory(p.join(appDir.path, 'Imported'));
    if (!await importedDir.exists()) {
      await importedDir.create(recursive: true);
    }

    int imported = 0;
    for (final file in files) {
      if (file.path == null) continue;

      try {
        var destName = file.name;
        var destPath = p.join(importedDir.path, destName);
        var counter = 1;
        while (await File(destPath).exists()) {
          final baseName = p.basenameWithoutExtension(file.name);
          final ext = p.extension(file.name);
          destName = '$baseName ($counter)$ext';
          destPath = p.join(importedDir.path, destName);
          counter++;
        }

        await File(file.path!).copy(destPath);

        final storedPath = Platform.isIOS ? 'Imported/$destName' : destPath;
        await ref.tagFile(
          tagId: widget.tagId,
          localPath: storedPath,
          fileName: destName,
        );
        imported++;
      } catch (e) {
        debugPrint('Failed to import ${file.name}: $e');
      }
    }

    if (mounted && imported > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image imported')),
      );
    }
  }

  Future<void> _removeAsset(TaggedFile file) async {
    await ref.untagFile(
      tagId: widget.tagId,
      localPath: file.localPath,
      remoteKey: file.remoteKey,
      iosAssetId: file.iosAssetId,
    );
  }
}

// ============================================================================
// ASSET TILE
// ============================================================================

Future<String> _resolveFilePath(String path) async {
  if (path.startsWith('/')) {
    if (File(path).existsSync()) return path;
    final docsMarker = 'Documents/';
    final idx = path.indexOf(docsMarker);
    if (idx != -1) {
      final relativePart = path.substring(idx + docsMarker.length);
      final appDir = await getApplicationDocumentsDirectory();
      final resolved = p.join(appDir.path, relativePart);
      if (File(resolved).existsSync()) return resolved;
    }
    return path;
  }
  final appDir = await getApplicationDocumentsDirectory();
  return p.join(appDir.path, path);
}

class _NftAssetTile extends StatelessWidget {
  final TaggedFile taggedFile;
  final VoidCallback onRemove;

  const _NftAssetTile({
    required this.taggedFile,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _buildThumbnail(),
      title: Text(
        taggedFile.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        'Image',
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
      ),
      trailing: IconButton(
        icon: const Icon(LucideIcons.x, size: 18),
        tooltip: 'Remove',
        onPressed: onRemove,
      ),
    );
  }

  Widget _buildThumbnail() {
    final path = taggedFile.localPath;
    if (path == null) return _placeholder();

    return FutureBuilder<String>(
      future: _resolveFilePath(path),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return _placeholder();
        final resolvedPath = snapshot.data!;
        final file = File(resolvedPath);
        if (!file.existsSync()) return _placeholder();
        try {
          final stat = file.statSync();
          final localFile = LocalFile.fromFileSystemEntity(file, stat);
          return FileThumbnail(file: localFile, size: 48);
        } catch (_) {
          return _placeholder();
        }
      },
    );
  }

  Widget _placeholder() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(LucideIcons.image, color: Colors.grey),
    );
  }
}
