import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';

/// Configuration result from the mint dialog
class MintConfig {
  final int count;
  final String fulaPerNft;
  final SupportedChain chain;
  final String eventName;
  final int royaltyBps;

  const MintConfig({
    required this.count,
    required this.fulaPerNft,
    required this.chain,
    required this.eventName,
    this.royaltyBps = 0,
  });
}

/// Dialog for configuring NFT minting parameters:
/// count, FULA per NFT, event name, and chain selection.
Future<MintConfig?> showMintConfigDialog(BuildContext context) async {
  final countController = TextEditingController(text: '1');
  final fulaController = TextEditingController(text: '10');
  final eventController = TextEditingController(text: 'default');
  final royaltyController = TextEditingController(text: '0');
  final validChains = SupportedChain.all
      .where((c) => c.nftContractAddress != null &&
          c.nftContractAddress != '0x0000000000000000000000000000000000000000')
      .toList();
  var selectedChain = validChains.isNotEmpty ? validChains.first : SupportedChain.base;

  final result = await showDialog<MintConfig>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('Mint NFTs'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: eventController,
                    decoration: const InputDecoration(
                      labelText: 'Event / Category',
                      hintText: 'default',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(LucideIcons.tag),
                    ),
                    maxLength: 128,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: countController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Number of NFTs',
                      hintText: '1',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(LucideIcons.hash),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: fulaController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'FULA per NFT',
                      hintText: '10',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(LucideIcons.coins),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: royaltyController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Royalty %',
                      hintText: '0',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(LucideIcons.percent),
                      helperText: 'Creator royalty on secondary sales (0-100%)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<SupportedChain>(
                    value: selectedChain,
                    decoration: const InputDecoration(
                      labelText: 'Chain',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(LucideIcons.link),
                    ),
                    items: validChains
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(c.chainName),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        setDialogState(() => selectedChain = v);
                      }
                    },
                  ),
                  if (validChains.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'NFT contract not yet deployed. Minting will be available soon.',
                        style: TextStyle(color: Colors.orange[700], fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: validChains.isEmpty
                    ? null
                    : () {
                        final count = int.tryParse(countController.text);
                        final fula = fulaController.text.trim();
                        final event = eventController.text.trim();

                        // Validate event name
                        if (event.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Event name is required')),
                          );
                          return;
                        }

                        // Validate count
                        if (count == null || count <= 0) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Count must be at least 1')),
                          );
                          return;
                        }
                        if (count > 10000) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Count must be 10,000 or less')),
                          );
                          return;
                        }

                        // Validate FULA amount (must be a valid non-negative decimal)
                        if (fula.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('FULA amount is required')),
                          );
                          return;
                        }
                        final fulaNum = double.tryParse(fula);
                        if (fulaNum == null || fulaNum < 0) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Invalid FULA amount')),
                          );
                          return;
                        }

                        // Validate royalty
                        final royaltyText = royaltyController.text.trim();
                        final royaltyPct = double.tryParse(royaltyText) ?? 0;
                        if (royaltyPct < 0 || royaltyPct > 100) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Royalty must be between 0% and 100%')),
                          );
                          return;
                        }
                        // Convert percentage to basis points (e.g. 2.5% → 250 bps)
                        final royaltyBps = (royaltyPct * 100).round();

                        Navigator.of(ctx).pop(MintConfig(
                          count: count,
                          fulaPerNft: fula,
                          chain: selectedChain,
                          eventName: event,
                          royaltyBps: royaltyBps,
                        ));
                      },
                child: const Text('Mint'),
              ),
            ],
          );
        },
      );
    },
  );

  // Dispose after dialog is fully closed (including animations)
  Future.delayed(const Duration(milliseconds: 300), () {
    countController.dispose();
    fulaController.dispose();
    eventController.dispose();
    royaltyController.dispose();
  });

  return result;
}
