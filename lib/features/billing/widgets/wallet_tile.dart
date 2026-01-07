import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';

class WalletTile extends StatelessWidget {
  final WalletInfo wallet;
  final VoidCallback? onTap;

  const WalletTile({
    super.key,
    required this.wallet,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chain = SupportedChain.byChainId(wallet.chainId);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Icon(
          LucideIcons.wallet,
          color: Theme.of(context).colorScheme.primary,
          size: 20,
        ),
      ),
      title: Text(
        wallet.shortAddress,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Row(
        children: [
          if (chain != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                chain.chainName,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (wallet.isVerified)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.checkCircle2,
                  size: 12,
                  color: const Color(0xFF06B597),
                ),
                const SizedBox(width: 2),
                Text(
                  'Verified',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: const Color(0xFF06B597),
                      ),
                ),
              ],
            ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(LucideIcons.copy, size: 18),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: wallet.address));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Address copied to clipboard'),
              duration: Duration(seconds: 2),
            ),
          );
        },
        tooltip: 'Copy address',
      ),
      onTap: onTap,
    );
  }
}
