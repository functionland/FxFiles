import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Shows a full-screen dialog with a camera QR scanner.
/// Returns the scanned wallet address (0x...) or null if cancelled.
Future<String?> showAddressQrScannerDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _AddressQrScannerDialog(),
  );
}

class _AddressQrScannerDialog extends StatefulWidget {
  const _AddressQrScannerDialog();

  @override
  State<_AddressQrScannerDialog> createState() =>
      _AddressQrScannerDialogState();
}

class _AddressQrScannerDialogState extends State<_AddressQrScannerDialog> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;

      // Accept plain EVM address or EIP-681 ethereum: URI
      final address = _extractAddress(value);
      if (address != null) {
        _scanned = true;
        Navigator.of(context).pop(address);
        return;
      }
    }
  }

  /// Extract a valid EVM address from raw QR data.
  /// Handles plain "0x..." addresses and "ethereum:0x..." URIs.
  String? _extractAddress(String raw) {
    var candidate = raw.trim();

    // Handle ethereum: URI scheme (EIP-681)
    if (candidate.toLowerCase().startsWith('ethereum:')) {
      candidate = candidate.substring('ethereum:'.length);
      // Strip any path/query after the address
      final atIdx = candidate.indexOf('/');
      if (atIdx != -1) candidate = candidate.substring(0, atIdx);
      final qIdx = candidate.indexOf('?');
      if (qIdx != -1) candidate = candidate.substring(0, qIdx);
    }

    if (RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(candidate)) {
      return candidate;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Scan Wallet Address'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            IconButton(
              icon: const Icon(LucideIcons.zap),
              tooltip: 'Toggle flash',
              onPressed: () => _controller.toggleTorch(),
            ),
            IconButton(
              icon: const Icon(LucideIcons.switchCamera),
              tooltip: 'Switch camera',
              onPressed: () => _controller.switchCamera(),
            ),
          ],
        ),
        body: Stack(
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
            // Overlay with scan hint
            Positioned(
              left: 0,
              right: 0,
              bottom: 48,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Point camera at a wallet QR code',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
