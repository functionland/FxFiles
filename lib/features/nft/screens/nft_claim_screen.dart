import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/meta_tx_relay_service.dart';
import 'package:fula_files/core/services/nft_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/features/nft/providers/nft_provider.dart';
import 'package:fula_files/features/nft/widgets/address_qr_scanner_dialog.dart';
import 'package:fula_files/features/nft/widgets/receive_nft_dialog.dart';

/// Screen reached via fxfiles://nft-claim deep link or from received NFTs list.
/// Fetches token info from the contract, displays NFT details, and allows claiming.
/// When [receivedNftId] is set, opens in post-claim mode for burn/transfer.
class NftClaimScreen extends ConsumerStatefulWidget {
  final String? chainId;
  final String? contractAddress;
  final String? tokenId;
  final String? linkHash;
  final String? receivedNftId;

  const NftClaimScreen({
    super.key,
    this.chainId,
    this.contractAddress,
    this.tokenId,
    this.linkHash,
    this.receivedNftId,
  });

  @override
  ConsumerState<NftClaimScreen> createState() => _NftClaimScreenState();
}

class _NftClaimScreenState extends ConsumerState<NftClaimScreen> {
  bool _isLoading = true;
  bool _isClaiming = false;
  bool _isBurning = false;
  bool _isTransferring = false;
  String? _error;
  String? _claimTxHash;
  String? _burnTxHash;
  String? _transferTxHash;

  // Token info from contract
  String? _creator;
  String? _eventName;
  BigInt? _fulaPerNft;
  int? _initialMintCount;
  String? _gatewayUrl;
  String? _receivedNftId; // tracks the persisted ReceivedNft.id for burn/transfer updates
  bool _hasGasDeposit = false; // true if creator sponsored gas for this claim

  @override
  void initState() {
    super.initState();
    _receivedNftId = widget.receivedNftId;
    if (widget.receivedNftId != null) {
      // Opened from received NFTs list — skip straight to post-claim state
      _claimTxHash = 'already-claimed';
      // Pre-load burn/transfer state so the screen shows correct status
      final received = NftService.instance.getReceivedNft(widget.receivedNftId!);
      if (received != null) {
        if (received.status == ReceivedNftStatus.burned) {
          _burnTxHash = received.burnTxHash;
        } else if (received.status == ReceivedNftStatus.transferred) {
          _transferTxHash = received.transferTxHash;
        }
      }
    }
    _fetchTokenInfo();
  }

  Future<void> _fetchTokenInfo() async {
    // Eagerly derive internal wallet so hasWallet is true by the time UI renders
    await NftWalletService.instance.getAddress();

    final chainIdInt = int.tryParse(widget.chainId ?? '');
    final tokenIdInt = int.tryParse(widget.tokenId ?? '');

    if (chainIdInt == null || tokenIdInt == null) {
      setState(() {
        _isLoading = false;
        _error = 'Invalid chain or token ID';
      });
      return;
    }

    try {
      final info = await NftService.instance.fetchTokenInfo(
        chainId: chainIdInt,
        tokenId: tokenIdInt,
      );

      if (!mounted) return;

      if (info != null) {
        // Resolve actual image URL from metadata JSON
        final gatewayUrl = info.metadataCid.isNotEmpty
            ? await NftService.instance.resolveImageUrl(info.metadataCid)
            : null;

        // Check if gas deposit exists (gasless claim available)
        // linkHash from URL is the secret; derive claimKey for on-chain lookups
        final chain = SupportedChain.byChainId(chainIdInt);
        bool hasGas = chain?.freeGas == true;
        if (!hasGas && widget.linkHash != null && chain?.supportsGaslessRelay == true) {
          try {
            final claimKey = NftService.secretToClaimKey(widget.linkHash!);
            final deposit = await MetaTxRelayService.instance.getGasDeposit(
              chainId: chainIdInt,
              linkHash: claimKey,
            );
            hasGas = deposit > BigInt.zero;
          } catch (_) {}
        }

        // If opened from received NFTs list, check for stored linkHash
        if (widget.receivedNftId != null && !hasGas) {
          try {
            final received = NftService.instance.getReceivedNft(widget.receivedNftId!);
            if (received?.claimLinkHash != null) {
              final receivedChain = SupportedChain.byChainId(received!.chainId);
              if (receivedChain?.freeGas == true) {
                hasGas = true;
              } else if (receivedChain?.supportsGaslessRelay == true) {
                final claimKey = NftService.secretToClaimKey(received.claimLinkHash!);
                final deposit = await MetaTxRelayService.instance.getGasDeposit(
                  chainId: received.chainId,
                  linkHash: claimKey,
                );
                hasGas = deposit > BigInt.zero;
              }
            }
          } catch (_) {}
        }

        // Update stored ReceivedNft if gateway URL changed
        if (_receivedNftId != null && gatewayUrl != null) {
          final received = NftService.instance.getReceivedNft(_receivedNftId!);
          if (received != null && received.gatewayUrl != gatewayUrl) {
            received.gatewayUrl = gatewayUrl;
            await NftService.instance.saveReceivedNft(received);
          }
        }

        setState(() {
          _creator = info.creator;
          _eventName = info.eventName;
          _hasGasDeposit = hasGas;
          _fulaPerNft = info.fulaPerNft;
          _initialMintCount = info.initialMintCount;
          _gatewayUrl = gatewayUrl;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
          _error = 'Could not fetch token info';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

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

    // Initialize auth and wallet once before retrying address resolution
    try {
      await AuthService.instance.ensureAuthRestored();
    } catch (e) {
      debugPrint('NftClaimScreen: ensureAuthRestored error: $e');
    }

    if (!WalletService.instance.isInitialized && mounted) {
      try {
        await WalletService.instance.initialize(context);
      } catch (e) {
        debugPrint('NftClaimScreen: WalletService.initialize error: $e');
      }
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      internalAddress = await NftWalletService.instance.getAddress();
      externalConnected = WalletService.instance.isConnected;

      if (internalAddress != null || externalConnected) break;
      if (attempt < 2) {
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
                onTap: () => Navigator.of(ctx).pop(WalletSource.external),
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

  Future<void> _claimNft() async {
    final chainIdInt = int.tryParse(widget.chainId ?? '');
    if (chainIdInt == null || widget.linkHash == null) return;

    final walletSource = await _showWalletPicker();
    if (walletSource == null || !mounted) return;

    setState(() {
      _isClaiming = true;
      _error = null;
    });

    final txHash = await ref.read(nftProvider.notifier).claimNft(
      chainId: chainIdInt,
      linkHash: widget.linkHash!,
      walletSource: walletSource,
    );

    if (!mounted) return;

    if (txHash != null) {
      // Persist the received NFT locally
      final receivedId = const Uuid().v4();
      final chain = SupportedChain.byChainId(chainIdInt);
      await NftService.instance.saveReceivedNft(ReceivedNft(
        id: receivedId,
        tokenId: int.tryParse(widget.tokenId ?? '') ?? 0,
        chainId: chainIdInt,
        contractAddress: widget.contractAddress ?? chain?.nftContractAddress ?? '',
        eventName: _eventName ?? '',
        fulaPerNft: _fulaPerNft?.toString() ?? '0',
        creator: _creator ?? '',
        claimTxHash: txHash,
        claimedAt: DateTime.now(),
        gatewayUrl: _gatewayUrl,
        claimLinkHash: widget.linkHash,
      ));
      _receivedNftId = receivedId;
      // Trigger provider refresh
      ref.invalidate(receivedNftsProvider);

      setState(() {
        _isClaiming = false;
        _claimTxHash = txHash;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('NFT claimed successfully!')),
        );
      }
    } else {
      final nftState = ref.read(nftProvider);
      setState(() {
        _isClaiming = false;
        _error = nftState.error;
      });
    }
  }

  Future<void> _burnNft() async {
    final chainIdInt = int.tryParse(widget.chainId ?? '');
    final tokenIdInt = int.tryParse(widget.tokenId ?? '');
    if (chainIdInt == null || tokenIdInt == null) return;

    final walletSource = await _showWalletPicker();
    if (walletSource == null || !mounted) return;

    // Show confirmation dialog
    final fulaAmount = _fulaPerNft != null
        ? (_fulaPerNft! ~/ BigInt.from(10).pow(18)).toString()
        : '?';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.local_fire_department, color: Colors.orange[700]),
            const SizedBox(width: 8),
            const Text('Burn NFT'),
          ],
        ),
        content: Text(
          'This will permanently destroy the NFT and release $fulaAmount FULA to the NFT creator.\n\n'
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange[700],
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Burn'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isBurning = true;
      _error = null;
    });

    // Resolve linkHash for gasless burn
    String? burnLinkHash = widget.linkHash;
    if (burnLinkHash == null && _receivedNftId != null) {
      burnLinkHash = NftService.instance.getReceivedNft(_receivedNftId!)?.claimLinkHash;
    }

    final txHash = await ref.read(nftProvider.notifier).burnNft(
      chainId: chainIdInt,
      tokenId: tokenIdInt,
      amount: 1,
      walletSource: walletSource,
      linkHash: burnLinkHash,
    );

    if (!mounted) return;

    if (txHash != null) {
      // Update received NFT status
      if (_receivedNftId != null) {
        await NftService.instance.markReceivedBurned(_receivedNftId!, txHash);
        ref.invalidate(receivedNftsProvider);
      }
      setState(() {
        _isBurning = false;
        _burnTxHash = txHash;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('NFT burned! $fulaAmount FULA released to the NFT creator.')),
        );
      }
    } else {
      final nftState = ref.read(nftProvider);
      setState(() {
        _isBurning = false;
        _error = nftState.error;
      });
    }
  }

  Future<void> _transferNft() async {
    final chainIdInt = int.tryParse(widget.chainId ?? '');
    final tokenIdInt = int.tryParse(widget.tokenId ?? '');
    if (chainIdInt == null || tokenIdInt == null) return;

    final walletSource = await _showWalletPicker();
    if (walletSource == null || !mounted) return;

    // Show address input dialog with QR scan option
    final controller = TextEditingController();
    final toAddress = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Transfer NFT'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Recipient Address',
                hintText: '0x...',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(LucideIcons.wallet),
                suffixIcon: IconButton(
                  icon: const Icon(LucideIcons.scanLine),
                  tooltip: 'Scan QR code',
                  onPressed: () async {
                    final scanned = await showAddressQrScannerDialog(ctx);
                    if (scanned != null) {
                      controller.text = scanned;
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'FULA tokens stay locked in the NFT. Only burning releases FULA.',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
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
              final addr = controller.text.trim();
              if (RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(addr)) {
                Navigator.of(ctx).pop(addr);
              } else {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Enter a valid 0x address (42 characters)')),
                );
              }
            },
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (toAddress == null || !mounted) return;

    setState(() {
      _isTransferring = true;
      _error = null;
    });

    // Resolve linkHash for gasless transfer
    String? transferLinkHash = widget.linkHash;
    if (transferLinkHash == null && _receivedNftId != null) {
      transferLinkHash = NftService.instance.getReceivedNft(_receivedNftId!)?.claimLinkHash;
    }

    final txHash = await ref.read(nftProvider.notifier).transferNft(
      chainId: chainIdInt,
      tokenId: tokenIdInt,
      toAddress: toAddress,
      amount: 1,
      walletSource: walletSource,
      linkHash: transferLinkHash,
    );

    if (!mounted) return;

    if (txHash != null) {
      // Update received NFT status
      if (_receivedNftId != null) {
        await NftService.instance.markReceivedTransferred(_receivedNftId!, txHash);
        ref.invalidate(receivedNftsProvider);
      }
      setState(() {
        _isTransferring = false;
        _transferTxHash = txHash;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('NFT transferred successfully!')),
        );
      }
    } else {
      final nftState = ref.read(nftProvider);
      setState(() {
        _isTransferring = false;
        _error = nftState.error;
      });
    }
  }

  void _openExplorer(String txHash) {
    final chainIdInt = int.tryParse(widget.chainId ?? '');
    if (chainIdInt == null) return;
    final chain = SupportedChain.byChainId(chainIdInt);
    if (chain == null) return;
    final url = chain.getTxExplorerUrl(txHash);
    if (url != null) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chain = SupportedChain.byChainId(int.tryParse(widget.chainId ?? '') ?? 0);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.receivedNftId != null ? 'My NFT' : 'Claim NFT'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // NFT Image
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: _gatewayUrl != null
                    ? Image.network(
                        _gatewayUrl!,
                        width: 160,
                        height: 160,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholderImage(),
                      )
                    : _placeholderImage(),
              ),
              const SizedBox(height: 24),
              Text(
                'NFT Claim',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Token #${widget.tokenId ?? 'Unknown'}',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 24),

              if (_isLoading)
                _buildLoadingShimmer()
              else if (_error != null && _creator == null)
                Text(_error!, style: TextStyle(color: Colors.red[400]))
              else ...[
                // Token info card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _InfoRow(label: 'Chain', value: chain?.chainName ?? widget.chainId ?? 'Unknown'),
                        const SizedBox(height: 8),
                        _InfoRow(label: 'Token ID', value: widget.tokenId ?? 'Unknown'),
                        if (_creator != null) ...[
                          const SizedBox(height: 8),
                          _InfoRow(
                            label: 'Creator',
                            value: _creator!.length > 16
                                ? '${_creator!.substring(0, 8)}...${_creator!.substring(_creator!.length - 6)}'
                                : _creator!,
                          ),
                        ],
                        if (_eventName != null && _eventName!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          _InfoRow(label: 'Event', value: _eventName!),
                        ],
                        if (_fulaPerNft != null) ...[
                          const SizedBox(height: 8),
                          _InfoRow(
                            label: 'FULA/NFT',
                            value: '${(_fulaPerNft! ~/ BigInt.from(10).pow(18)).toString()} FULA',
                          ),
                        ],
                        if (_initialMintCount != null) ...[
                          const SizedBox(height: 8),
                          _InfoRow(label: 'Mint Count', value: _initialMintCount.toString()),
                        ],
                        if (widget.linkHash != null) ...[
                          const SizedBox(height: 8),
                          _InfoRow(
                            label: 'Link Hash',
                            value: widget.linkHash!.length > 16
                                ? '${widget.linkHash!.substring(0, 8)}...${widget.linkHash!.substring(widget.linkHash!.length - 8)}'
                                : widget.linkHash!,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Claim button
                if (_claimTxHash != null) ...[
                  Icon(LucideIcons.checkCircle, size: 48, color: Colors.green[400]),
                  const SizedBox(height: 8),
                  const Text('NFT Claimed!', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: () => _openExplorer(_claimTxHash!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Tx: ${_claimTxHash!.length > 10 ? '${_claimTxHash!.substring(0, 10)}...' : _claimTxHash!}',
                          style: TextStyle(color: Colors.blue[400], fontSize: 12, fontFamily: 'monospace'),
                        ),
                        const SizedBox(width: 4),
                        Icon(LucideIcons.externalLink, size: 12, color: Colors.blue[400]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Post-claim actions: Transfer and Burn
                  if (_burnTxHash != null) ...[
                    Icon(Icons.local_fire_department, size: 32, color: Colors.orange[400]),
                    const SizedBox(height: 8),
                    const Text('NFT Burned!', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => _openExplorer(_burnTxHash!),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Tx: ${_burnTxHash!.length > 10 ? '${_burnTxHash!.substring(0, 10)}...' : _burnTxHash!}',
                            style: TextStyle(color: Colors.blue[400], fontSize: 12, fontFamily: 'monospace'),
                          ),
                          const SizedBox(width: 4),
                          Icon(LucideIcons.externalLink, size: 12, color: Colors.blue[400]),
                        ],
                      ),
                    ),
                  ] else if (_transferTxHash != null) ...[
                    Icon(LucideIcons.send, size: 32, color: Colors.blue[400]),
                    const SizedBox(height: 8),
                    const Text('NFT Transferred!', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => _openExplorer(_transferTxHash!),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Tx: ${_transferTxHash!.length > 10 ? '${_transferTxHash!.substring(0, 10)}...' : _transferTxHash!}',
                            style: TextStyle(color: Colors.blue[400], fontSize: 12, fontFamily: 'monospace'),
                          ),
                          const SizedBox(width: 4),
                          Icon(LucideIcons.externalLink, size: 12, color: Colors.blue[400]),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Sell on OpenSea (Base chain only)
                    Builder(builder: (context) {
                      final tokenIdInt = int.tryParse(widget.tokenId ?? '');
                      final openSeaChain = chain;
                      final contract = widget.contractAddress ?? openSeaChain?.nftContractAddress;
                      final openSeaUrl = (openSeaChain != null && contract != null && tokenIdInt != null)
                          ? openSeaChain.getOpenSeaUrl(contract, tokenIdInt)
                          : null;
                      if (openSeaUrl == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: OutlinedButton.icon(
                          onPressed: () => launchUrl(Uri.parse(openSeaUrl), mode: LaunchMode.externalApplication),
                          icon: const Icon(LucideIcons.shoppingBag),
                          label: const Text('Sell on OpenSea'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.blue[600],
                            side: BorderSide(color: Colors.blue[300]!),
                          ),
                        ),
                      );
                    }),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _isTransferring ? null : _transferNft,
                          icon: _isTransferring
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(LucideIcons.send),
                          label: Text(_isTransferring ? 'Sending...' : 'Transfer'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _isBurning ? null : _burnNft,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.orange[700],
                          ),
                          icon: _isBurning
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.local_fire_department),
                          label: Text(_isBurning
                              ? 'Burning...'
                              : 'Burn NFT${_fulaPerNft != null ? ' — ${(_fulaPerNft! ~/ BigInt.from(10).pow(18))} FULA' : ''}'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Transfer keeps FULA locked. Only burning releases FULA.',
                      style: TextStyle(color: Colors.grey[500], fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => showReceiveNftDialog(context),
                      icon: const Icon(LucideIcons.qrCode, size: 16),
                      label: const Text('My Address'),
                    ),
                  ],
                ] else if (widget.linkHash != null) ...[
                  FilledButton.icon(
                    onPressed: _isClaiming ? null : _claimNft,
                    icon: _isClaiming
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.download),
                    label: Text(_isClaiming
                        ? 'Claiming...'
                        : _hasGasDeposit ? 'Claim NFT (gas-free)' : 'Claim NFT'),
                  ),
                  if (_hasGasDeposit) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Gas sponsored by creator',
                      style: TextStyle(color: Colors.green[400], fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (!NftWalletService.instance.hasWallet && !WalletService.instance.isConnected) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Sign in or connect a wallet to claim this NFT',
                      style: TextStyle(color: Colors.orange[600], fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(color: Colors.red[400], fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _isClaiming ? null : _claimNft,
                      icon: const Icon(LucideIcons.refreshCw, size: 14),
                      label: const Text('Retry'),
                    ),
                  ],
                ] else ...[
                  Text(
                    'Invalid claim link. Missing link hash.',
                    style: TextStyle(color: Colors.red[400]),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingShimmer() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              for (int i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 70,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 100,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholderImage() {
    return Container(
      width: 160,
      height: 160,
      decoration: BoxDecoration(
        color: Colors.pink.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Icon(LucideIcons.gem, size: 48, color: Colors.pink),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 13,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
            ),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}
