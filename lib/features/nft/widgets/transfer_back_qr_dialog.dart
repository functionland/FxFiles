import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Dialog showing a QR code for the claimer to present to the sender
/// for the transfer-back flow.
/// Full implementation in Phase 4 (requires qr_flutter package).
Future<void> showTransferBackQrDialog(
  BuildContext context, {
  required int chainId,
  required int tokenId,
  required int amount,
  required String claimerAddress,
}) async {
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Transfer Back'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.qrCode, size: 48, color: Colors.grey[400]),
                  const SizedBox(height: 8),
                  Text(
                    'QR Code',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                  Text(
                    '(Phase 4)',
                    style: TextStyle(color: Colors.grey[400], fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Show this QR code to the sender.\n'
            'They will scan it to return the NFT\n'
            'and release your locked FULA.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600], fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
