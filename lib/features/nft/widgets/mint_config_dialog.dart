import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';

/// Configuration result from the mint dialog
class MintConfig {
  final int count;
  final String fulaPerNft;
  final SupportedChain chain;

  const MintConfig({
    required this.count,
    required this.fulaPerNft,
    required this.chain,
  });
}

/// Dialog for configuring NFT minting parameters:
/// count, FULA per NFT, and chain selection.
/// Full implementation in Phase 2.
Future<MintConfig?> showMintConfigDialog(BuildContext context) async {
  final countController = TextEditingController(text: '1');
  final fulaController = TextEditingController(text: '10');
  var selectedChain = SupportedChain.base;

  return showDialog<MintConfig>(
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
                  DropdownButtonFormField<SupportedChain>(
                    value: selectedChain,
                    decoration: const InputDecoration(
                      labelText: 'Chain',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(LucideIcons.link),
                    ),
                    items: SupportedChain.all
                        .where((c) => c.nftContractAddress != null)
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
                  if (SupportedChain.all.every((c) => c.nftContractAddress == null))
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
                onPressed: SupportedChain.all.every((c) => c.nftContractAddress == null)
                    ? null
                    : () {
                        final count = int.tryParse(countController.text) ?? 1;
                        final fula = fulaController.text.trim();
                        if (count > 0 && fula.isNotEmpty) {
                          Navigator.of(ctx).pop(MintConfig(
                            count: count,
                            fulaPerNft: fula,
                            chain: selectedChain,
                          ));
                        }
                      },
                child: const Text('Mint'),
              ),
            ],
          );
        },
      );
    },
  );
}
