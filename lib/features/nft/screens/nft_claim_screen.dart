import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Screen reached via fxfiles://nft-claim deep link.
/// Shows NFT image, token info, and claim button.
/// Full implementation in Phase 3 (after contract deployment).
class NftClaimScreen extends ConsumerWidget {
  final String? chainId;
  final String? contractAddress;
  final String? tokenId;
  final String? linkHash;

  const NftClaimScreen({
    super.key,
    this.chainId,
    this.contractAddress,
    this.tokenId,
    this.linkHash,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Claim NFT'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.pink.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(LucideIcons.gem, size: 48, color: Colors.pink),
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
                'Token #${tokenId ?? 'Unknown'}',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 32),
              if (linkHash != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _InfoRow(label: 'Chain', value: chainId ?? 'Unknown'),
                        const SizedBox(height: 8),
                        _InfoRow(label: 'Token ID', value: tokenId ?? 'Unknown'),
                        const SizedBox(height: 8),
                        _InfoRow(
                          label: 'Link Hash',
                          value: linkHash != null && linkHash!.length > 16
                              ? '${linkHash!.substring(0, 8)}...${linkHash!.substring(linkHash!.length - 8)}'
                              : linkHash ?? 'Unknown',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: null, // Enabled in Phase 3
                  icon: const Icon(LucideIcons.download),
                  label: const Text('Claim NFT'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Claiming will be available after smart contract deployment',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[500],
                      ),
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                Text(
                  'Invalid claim link. Missing parameters.',
                  style: TextStyle(color: Colors.red[400]),
                ),
              ],
            ],
          ),
        ),
      ),
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
