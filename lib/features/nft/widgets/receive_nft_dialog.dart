import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/wallet_service.dart';

/// Shows a dialog where the user picks a wallet and sees its QR code
/// so a sender can scan it to transfer an NFT.
Future<void> showReceiveNftDialog(BuildContext context) async {
  String? internalAddress;
  bool externalConnected = false;

  for (var attempt = 0; attempt < 3; attempt++) {
    await AuthService.instance.ensureAuthRestored();
    internalAddress = await NftWalletService.instance.getAddress();

    if (!WalletService.instance.isInitialized && context.mounted) {
      try {
        await WalletService.instance.initialize(context);
      } catch (_) {}
    }

    externalConnected = WalletService.instance.isConnected;

    if (internalAddress != null || externalConnected) break;
    if (attempt < 2) {
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  final externalAddress = WalletService.instance.connectedAddress;

  if (!context.mounted) return;

  // If no wallet available after retries
  if (internalAddress == null && !externalConnected) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('No wallet available. Sign in or connect a wallet.')),
    );
    return;
  }

  // Always show picker so the user can choose
  final choice = await showDialog<({String address, String label})?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Show Address For'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (internalAddress != null)
            ListTile(
              leading: const Icon(LucideIcons.keyRound),
              title: const Text('Internal Wallet'),
              subtitle: Text(
                _truncate(internalAddress),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onTap: () => Navigator.of(ctx)
                  .pop((address: internalAddress, label: 'Internal Wallet')),
            ),
          if (internalAddress != null && externalConnected)
            const SizedBox(height: 4),
          if (externalConnected)
            ListTile(
              leading: const Icon(LucideIcons.wallet),
              title: const Text('Connected Wallet'),
              subtitle: Text(
                _truncate(externalAddress!),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onTap: () => Navigator.of(ctx)
                  .pop((address: externalAddress, label: 'Connected Wallet')),
            ),
        ],
      ),
    ),
  );

  if (choice == null || !context.mounted) return;
  _showQrDialog(context, choice.address, choice.label,
      isInternal: choice.label == 'Internal Wallet');
}

void _showQrDialog(BuildContext context, String address, String label,
    {bool isInternal = false}) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(LucideIcons.qrCode, size: 20),
          const SizedBox(width: 8),
          const Text('Receive NFT'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: address,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            address,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: address));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Address copied')),
              );
            },
            icon: const Icon(LucideIcons.copy, size: 14),
            label: const Text('Copy Address'),
          ),
          if (isInternal) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.alertTriangle, size: 14, color: Colors.orange[700]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This wallet must not be used for token transfers and is only for internal app NFTs.',
                    style: TextStyle(fontSize: 11, color: Colors.orange[700]),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

String _truncate(String address) {
  if (address.length <= 14) return address;
  return '${address.substring(0, 8)}...${address.substring(address.length - 6)}';
}
