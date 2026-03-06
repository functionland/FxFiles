import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// QR scanner screen for the sender to scan the claimer's transfer-back QR code.
/// Uses mobile_scanner package (added in Phase 4).
/// Full implementation in Phase 4.
class NftQrScannerScreen extends StatelessWidget {
  const NftQrScannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[400]!, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(LucideIcons.scanLine, size: 64, color: Colors.grey[400]),
              ),
              const SizedBox(height: 24),
              Text(
                'QR Scanner',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Camera scanner will be available after mobile_scanner is integrated (Phase 4)',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[500],
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
