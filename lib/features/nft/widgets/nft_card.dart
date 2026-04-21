import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/services/nft_service.dart';
import 'package:fula_files/shared/widgets/destructive_list_tile.dart';

/// Card displaying a minted NFT with its status, thumbnail, and token info
class NftCard extends StatefulWidget {
  final NftMintRecord record;
  final VoidCallback? onShareClaim;
  final VoidCallback? onRetry;
  final VoidCallback? onBurn;
  final void Function(NftClaimRecord claim)? onCancelClaim;

  const NftCard({
    super.key,
    required this.record,
    this.onShareClaim,
    this.onRetry,
    this.onBurn,
    this.onCancelClaim,
  });

  @override
  State<NftCard> createState() => _NftCardState();
}

class _NftCardState extends State<NftCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final chain = SupportedChain.byChainId(record.chainId);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: record.gatewayUrl != null
                      ? Image.network(
                          record.gatewayUrl!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholder(),
                        )
                      : _placeholder(),
                ),
                const SizedBox(width: 12),

                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _StatusBadge(status: record.status),
                          const SizedBox(width: 8),
                          if (record.tokenId != null)
                            Text(
                              'Token #${record.tokenId}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                    color: Colors.grey[600],
                                  ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${record.count} NFT${record.count > 1 ? 's' : ''} | ${record.fulaPerNft} FULA each',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (chain != null)
                        Text(
                          chain.chainName,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey[500],
                                fontSize: 11,
                              ),
                        ),
                      if (record.errorMessage != null)
                        Text(
                          record.errorMessage!,
                          style: TextStyle(color: Colors.red[400], fontSize: 11),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      // Explorer + IPFS links for completed mints
                      if (record.status == NftMintStatus.completed) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Wrap(
                            spacing: 12,
                            children: [
                              if (record.txHash != null && chain != null)
                                GestureDetector(
                                  onTap: () => _openExplorer(chain, record.txHash!),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(LucideIcons.externalLink, size: 11, color: Colors.blue[400]),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Explorer',
                                        style: TextStyle(
                                          color: Colors.blue[400],
                                          fontSize: 11,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (record.gatewayUrl != null)
                                GestureDetector(
                                  onTap: () => _openIpfs(record.gatewayUrl!),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(LucideIcons.globe, size: 11, color: Colors.blue[400]),
                                      const SizedBox(width: 4),
                                      Text(
                                        'View on IPFS',
                                        style: TextStyle(
                                          color: Colors.blue[400],
                                          fontSize: 11,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (record.tokenId != null && chain != null &&
                                  chain.getOpenSeaUrl(chain.nftContractAddress ?? '', record.tokenId!) != null)
                                GestureDetector(
                                  onTap: () => launchUrl(
                                    Uri.parse(chain.getOpenSeaUrl(chain.nftContractAddress!, record.tokenId!)!),
                                    mode: LaunchMode.externalApplication,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(LucideIcons.shoppingBag, size: 11, color: Colors.blue[400]),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Sell on OpenSea',
                                        style: TextStyle(
                                          color: Colors.blue[400],
                                          fontSize: 11,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // Actions
                if (record.status == NftMintStatus.error && widget.onRetry != null)
                  IconButton(
                    icon: const Icon(LucideIcons.refreshCw, size: 20),
                    tooltip: 'Retry mint',
                    onPressed: widget.onRetry,
                  ),
                if (record.status == NftMintStatus.completed && widget.onShareClaim != null)
                  IconButton(
                    icon: const Icon(LucideIcons.share2, size: 20),
                    tooltip: 'New claim link',
                    onPressed: widget.onShareClaim,
                  ),
                // Detail expand/collapse
                if (record.status == NftMintStatus.completed)
                  IconButton(
                    icon: Icon(
                      _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                      size: 20,
                    ),
                    tooltip: _expanded ? 'Hide details' : 'Show details',
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
              ],
            ),

            // Expanded detail section
            if (_expanded && record.status == NftMintStatus.completed) ...[
              const Divider(height: 16),
              _CopyBreakdown(record: record),
              // Claim history
              if (record.claims.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Claim Links (${record.claims.length})',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 4),
                ...record.claims.map((claim) => _ClaimRow(
                  claim: claim,
                  chain: chain,
                  onCancel: widget.onCancelClaim != null && claim.status == NftClaimStatus.pending
                      ? () => widget.onCancelClaim!(claim)
                      : null,
                )),
              ],
              if (widget.onBurn != null) ...[
                const SizedBox(height: 12),
                DestructiveListTile(
                  icon: LucideIcons.flame,
                  title: 'Burn to release FULA',
                  subtitle:
                      'Permanent. Destroys the NFT to unlock ${record.fulaPerNft} FULA.',
                  margin: EdgeInsets.zero,
                  onTap: widget.onBurn,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  void _openExplorer(SupportedChain chain, String txHash) {
    final url = chain.getTxExplorerUrl(txHash);
    if (url != null) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  void _openIpfs(String gatewayUrl) {
    launchUrl(Uri.parse(gatewayUrl), mode: LaunchMode.externalApplication);
  }

  Widget _placeholder() {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(LucideIcons.gem, color: Colors.grey),
    );
  }
}

/// Shows a per-copy status breakdown of the minted NFTs
class _CopyBreakdown extends StatelessWidget {
  final NftMintRecord record;

  const _CopyBreakdown({required this.record});

  @override
  Widget build(BuildContext context) {
    // Compute per-copy counts from claims
    int pendingLinks = 0;
    int claimed = 0;
    int burned = 0;

    for (final claim in record.claims) {
      final isExpired = claim.status == NftClaimStatus.expired ||
          (claim.status == NftClaimStatus.pending &&
              claim.expiresAt.isBefore(DateTime.now()));

      if (claim.status == NftClaimStatus.claimed) {
        claimed++;
      } else if (claim.status == NftClaimStatus.burned) {
        burned++;
      } else if (claim.status == NftClaimStatus.pending && !isExpired) {
        pendingLinks++;
      }
      // expired claims return to creator, so they don't consume a copy
    }

    final totalBurned = burned + record.creatorBurned;
    final held = record.count - pendingLinks - claimed - totalBurned;

    final entries = <({String label, int count, Color color, IconData icon})>[
      if (held > 0)
        (label: 'Held by you', count: held, color: Colors.blue, icon: LucideIcons.wallet),
      if (pendingLinks > 0)
        (label: 'Link generated', count: pendingLinks, color: Colors.orange, icon: LucideIcons.link),
      if (claimed > 0)
        (label: 'Claimed', count: claimed, color: Colors.green, icon: LucideIcons.userCheck),
      if (totalBurned > 0)
        (label: 'Burned', count: totalBurned, color: Colors.red, icon: LucideIcons.flame),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Copy Breakdown',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 6),
        ...entries.map((e) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(e.icon, size: 14, color: e.color),
              const SizedBox(width: 8),
              Text(
                '${e.count}x ${e.label}',
                style: TextStyle(fontSize: 12, color: e.color),
              ),
            ],
          ),
        )),
      ],
    );
  }
}

class _ClaimRow extends StatelessWidget {
  final NftClaimRecord claim;
  final SupportedChain? chain;
  final VoidCallback? onCancel;

  const _ClaimRow({required this.claim, required this.chain, this.onCancel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isExpired = claim.status == NftClaimStatus.expired ||
        (claim.status == NftClaimStatus.pending &&
            claim.expiresAt.isBefore(DateTime.now()));

    final (statusColor, statusLabel) = switch (claim.status) {
      NftClaimStatus.pending when isExpired => (Colors.grey, 'Expired'),
      NftClaimStatus.pending => (Colors.orange, 'Pending'),
      NftClaimStatus.claimed => (Colors.green, 'Claimed'),
      NftClaimStatus.expired => (Colors.grey, 'Expired'),
      NftClaimStatus.burned => (Colors.red, 'Burned'),
    };

    final showActions = claim.status == NftClaimStatus.pending &&
        !isExpired &&
        claim.linkHash != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status row
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              if (claim.status == NftClaimStatus.pending && !isExpired)
                Text(
                  'expires ${_formatDate(claim.expiresAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              if (claim.status == NftClaimStatus.claimed && claim.claimerAddress != null)
                Expanded(
                  child: Text(
                    '→ ${_truncateAddress(claim.claimerAddress!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
          // Action buttons
          if (showActions) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copyClaimLink(context),
                    icon: const Icon(LucideIcons.copy, size: 16),
                    label: const Text('Copy Link'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                if (onCancel != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onCancel,
                      icon: Icon(LucideIcons.xCircle, size: 16, color: Colors.red[400]),
                      label: Text('Cancel', style: TextStyle(color: Colors.red[400])),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        textStyle: const TextStyle(fontSize: 12),
                        side: BorderSide(color: Colors.red[300]!),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _copyClaimLink(BuildContext context) {
    final nftContractAddress = chain?.nftContractAddress ?? '';
    final claimLink = NftService.buildClaimLink(
      chainId: claim.chainId,
      contractAddress: nftContractAddress,
      tokenId: claim.tokenId,
      secret: claim.linkHash!,
    );
    Clipboard.setData(ClipboardData(text: claimLink));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Claim link copied')),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = dt.difference(now);
    if (diff.inDays > 0) return '${diff.inDays}d';
    if (diff.inHours > 0) return '${diff.inHours}h';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m';
    return 'soon';
  }

  String _truncateAddress(String addr) {
    if (addr.length <= 10) return addr;
    return '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}';
  }
}

class _StatusBadge extends StatefulWidget {
  final NftMintStatus status;

  const _StatusBadge({required this.status});

  @override
  State<_StatusBadge> createState() => _StatusBadgeState();
}

class _StatusBadgeState extends State<_StatusBadge>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  bool get _isInProgress =>
      widget.status == NftMintStatus.approving ||
      widget.status == NftMintStatus.minting ||
      widget.status == NftMintStatus.confirming;

  @override
  void initState() {
    super.initState();
    if (_isInProgress) {
      _controller = AnimationController(
        duration: const Duration(milliseconds: 1200),
        vsync: this,
      )..repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _StatusBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isInProgress && _controller == null) {
      _controller = AnimationController(
        duration: const Duration(milliseconds: 1200),
        vsync: this,
      )..repeat(reverse: true);
    } else if (!_isInProgress && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (widget.status) {
      NftMintStatus.approving => (Colors.orange, 'Approving'),
      NftMintStatus.minting => (Colors.blue, 'Minting'),
      NftMintStatus.confirming => (Colors.amber, 'Confirming'),
      NftMintStatus.completed => (Colors.green, 'Minted'),
      NftMintStatus.error => (Colors.red, 'Error'),
    };

    Widget badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isInProgress) ...[
            SizedBox(
              width: 8,
              height: 8,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: color,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    if (_controller != null) {
      return FadeTransition(
        opacity: Tween<double>(begin: 0.5, end: 1.0).animate(_controller!),
        child: badge,
      );
    }

    return badge;
  }
}
