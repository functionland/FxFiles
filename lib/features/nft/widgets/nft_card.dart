import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/services/nft_service.dart';

/// Card displaying a minted NFT with its status, thumbnail, and token info
class NftCard extends StatelessWidget {
  final NftMintRecord record;
  final VoidCallback? onShareClaim;
  final VoidCallback? onRetry;

  const NftCard({
    super.key,
    required this.record,
    this.onShareClaim,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
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
                      // Explorer link for completed mints
                      if (record.status == NftMintStatus.completed &&
                          record.txHash != null &&
                          chain != null)
                        GestureDetector(
                          onTap: () => _openExplorer(chain, record.txHash!),
                          child: Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(LucideIcons.externalLink, size: 11, color: Colors.blue[400]),
                                const SizedBox(width: 4),
                                Text(
                                  'View on Explorer',
                                  style: TextStyle(
                                    color: Colors.blue[400],
                                    fontSize: 11,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Actions
                if (record.status == NftMintStatus.error && onRetry != null)
                  IconButton(
                    icon: const Icon(LucideIcons.refreshCw, size: 20),
                    tooltip: 'Retry mint',
                    onPressed: onRetry,
                  ),
                if (record.status == NftMintStatus.completed && onShareClaim != null)
                  IconButton(
                    icon: const Icon(LucideIcons.share2, size: 20),
                    tooltip: 'New claim link',
                    onPressed: onShareClaim,
                  ),
              ],
            ),

            // Claim history
            if (record.claims.isNotEmpty) ...[
              const Divider(height: 16),
              Text(
                'Claim Links (${record.claims.length})',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 4),
              ...record.claims.map((claim) => _ClaimRow(claim: claim, chain: chain)),
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

class _ClaimRow extends StatelessWidget {
  final NftClaimRecord claim;
  final SupportedChain? chain;

  const _ClaimRow({required this.claim, required this.chain});

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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          // Status dot
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          // Status label
          Text(
            statusLabel,
            style: TextStyle(
              color: statusColor,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          // Expiry
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
          if (claim.status != NftClaimStatus.claimed)
            const Spacer(),
          // Copy link button (only for pending, non-expired claims)
          if (claim.status == NftClaimStatus.pending &&
              !isExpired &&
              claim.linkHash != null)
            GestureDetector(
              onTap: () => _copyClaimLink(context),
              child: Icon(
                LucideIcons.copy,
                size: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
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
      linkHash: claim.linkHash!,
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
