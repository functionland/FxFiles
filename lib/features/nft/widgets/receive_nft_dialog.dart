import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/wallet_service.dart';

/// Shows a dialog where the user picks a wallet and sees its QR code
/// so a sender can scan it to transfer an NFT.
Future<void> showReceiveNftDialog(BuildContext context) async {
  final internalAddress = await NftWalletService.instance.getAddress();

  // Ensure WalletService is initialized so we can detect external wallets
  if (!WalletService.instance.isInitialized && context.mounted) {
    try {
      await WalletService.instance.initialize(context);
    } catch (_) {}
  }

  final externalConnected = WalletService.instance.isConnected;
  final externalAddress = WalletService.instance.connectedAddress;

  if (!context.mounted) return;

  // If no wallet available
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
  _showQrDialog(context, choice.address, choice.label);
}

void _showQrDialog(BuildContext context, String address, String label) {
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
