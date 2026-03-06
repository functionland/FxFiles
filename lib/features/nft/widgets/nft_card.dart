import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';

/// Card displaying a minted NFT with its status, thumbnail, and token info
class NftCard extends StatelessWidget {
  final NftMintRecord record;
  final VoidCallback? onShareClaim;

  const NftCard({
    super.key,
    required this.record,
    this.onShareClaim,
  });

  @override
  Widget build(BuildContext context) {
    final chain = SupportedChain.byChainId(record.chainId);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
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
                ],
              ),
            ),

            // Actions
            if (record.status == NftMintStatus.completed && onShareClaim != null)
              IconButton(
                icon: const Icon(LucideIcons.share2, size: 20),
                tooltip: 'Share claim link',
                onPressed: onShareClaim,
              ),
          ],
        ),
      ),
    );
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

class _StatusBadge extends StatelessWidget {
  final NftMintStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      NftMintStatus.approving => (Colors.orange, 'Approving'),
      NftMintStatus.minting => (Colors.blue, 'Minting'),
      NftMintStatus.confirming => (Colors.amber, 'Confirming'),
      NftMintStatus.completed => (Colors.green, 'Minted'),
      NftMintStatus.error => (Colors.red, 'Error'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
