import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

/// Bottom sheet for sharing an NFT claim link.
/// Full implementation in Phase 3 (after contract deployment).
Future<void> showClaimLinkShareSheet(
  BuildContext context, {
  required String claimLink,
  required int tokenId,
  required String chainName,
}) async {
  await showModalBottomSheet(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final colorScheme = theme.colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Share Claim Link',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        claimLink,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(LucideIcons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: claimLink));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link copied to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Token #$tokenId on $chainName',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  SharePlus.instance.share(
                    ShareParams(text: 'Claim your NFT: $claimLink'),
                  );
                },
                icon: const Icon(LucideIcons.share2),
                label: const Text('Share'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
