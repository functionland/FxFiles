import 'package:flutter/material.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';

class ChainSelector extends StatelessWidget {
  final SupportedChain selectedChain;
  final ValueChanged<SupportedChain> onChainSelected;

  const ChainSelector({
    super.key,
    required this.selectedChain,
    required this.onChainSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: SupportedChain.all.map((chain) {
        final isSelected = chain.chainId == selectedChain.chainId;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(chain.chainName),
            selected: isSelected,
            onSelected: (_) => onChainSelected(chain),
            selectedColor: Theme.of(context).colorScheme.primaryContainer,
            labelStyle: TextStyle(
              color: isSelected
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : Theme.of(context).colorScheme.onSurface,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        );
      }).toList(),
    );
  }
}
