import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/web/services/web_nft_service.dart';

/// Mirror of lib/features/nft/screens/nft_claim_screen.dart (web,
/// internal wallet): shows the NFT (image, event name, creator, FULA
/// locked) and claims it — gasless via the relay when available,
/// otherwise a direct transaction. Reached via
/// /app/#/nft-claim?chain=…&contract=…&token=…&hash=… (the same
/// parameter set the native deep link consumes; `hash` is the claim
/// secret).
class WebNftClaimScreen extends StatefulWidget {
  final int? chainId;
  final String? contractAddress;
  final int? tokenId;
  final String? secret;

  const WebNftClaimScreen({
    super.key,
    required this.chainId,
    required this.contractAddress,
    required this.tokenId,
    required this.secret,
  });

  @override
  State<WebNftClaimScreen> createState() => _WebNftClaimScreenState();
}

class _WebNftClaimScreenState extends State<WebNftClaimScreen> {
  bool _loading = true;
  bool _claiming = false;
  bool _claimed = false;
  String? _error;
  String? _imageUrl;
  ({String creator, String metadataCid, String eventName, BigInt fulaPerNft, int initialMintCount})?
      _info;

  bool get _paramsValid =>
      widget.chainId != null &&
      widget.tokenId != null &&
      widget.secret != null &&
      widget.secret!.isNotEmpty &&
      SupportedChain.byChainId(widget.chainId!) != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_paramsValid) {
      setState(() {
        _error = 'Invalid chain or token ID';
        _loading = false;
      });
      return;
    }
    try {
      final info = await WebNftService.instance
          .fetchTokenInfo(widget.chainId!, widget.tokenId!);
      String? imageUrl;
      if (info != null && info.metadataCid.isNotEmpty) {
        imageUrl =
            await WebNftService.instance.resolveImageUrl(info.metadataCid);
      }
      if (mounted) {
        setState(() {
          _info = info;
          _imageUrl = imageUrl;
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

  Future<void> _claim() async {
    setState(() {
      _claiming = true;
      _error = null;
    });
    try {
      final txHash = await WebNftService.instance.claimNft(
        chainId: widget.chainId!,
        secret: widget.secret!,
      );
      await WebNftService.instance.recordClaimed(
        chainId: widget.chainId!,
        contractAddress: widget.contractAddress ??
            SupportedChain.byChainId(widget.chainId!)!.nftContractAddress!,
        tokenId: widget.tokenId!,
        claimTxHash: txHash,
        secret: widget.secret!,
      );
      if (mounted) {
        setState(() {
          _claimed = true;
          _claiming = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _claiming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fula = _info != null
        ? (_info!.fulaPerNft / BigInt.from(10).pow(18)).toString()
        : null;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/nfts'),
        ),
        title: const Text('Claim NFT'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (_imageUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.network(
                          _imageUrl!,
                          height: 260,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            height: 260,
                            color:
                                theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(LucideIcons.gem, size: 64),
                          ),
                        ),
                      )
                    else
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(LucideIcons.gem, size: 64),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      _info?.eventName.isNotEmpty == true
                          ? _info!.eventName
                          : 'Token #${widget.tokenId ?? '—'}',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    if (_info != null) ...[
                      Text(
                        'Creator: ${_info!.creator.substring(0, 10)}…',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (fula != null)
                        Text(
                          '$fula FULA locked inside',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                    ],
                    const SizedBox(height: 20),
                    if (_claimed)
                      Column(
                        children: [
                          const Icon(LucideIcons.checkCircle,
                              color: Colors.green, size: 44),
                          const SizedBox(height: 8),
                          Text('NFT claimed!',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: 6),
                          Text(
                            'It is held by your internal wallet — see the '
                            'Received tab.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: () => context.go('/nfts'),
                            child: const Text('View my NFTs'),
                          ),
                        ],
                      )
                    else ...[
                      if (_error != null) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.errorFaint,
                            borderRadius: BorderRadius.circular(8),
                            border:
                                Border.all(color: AppColors.errorBorder),
                          ),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 13, color: AppColors.error),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_paramsValid)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 14)),
                          onPressed: _claiming ? null : _claim,
                          icon: _claiming
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white),
                                )
                              : const Icon(LucideIcons.gem, size: 18),
                          label: Text(
                              _claiming ? 'Claiming…' : 'Claim NFT'),
                        ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
