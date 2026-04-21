import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/shared/widgets/stepper_input.dart';

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

/// Opens the two-step mint configuration bottom sheet.
Future<MintConfig?> showMintConfigDialog(
  BuildContext context, {
  String? previewPath,
  String defaultEventName = 'default',
}) {
  return showModalBottomSheet<MintConfig>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _MintConfigSheet(
      previewPath: previewPath,
      defaultEventName: defaultEventName,
    ),
  );
}

class _MintConfigSheet extends StatefulWidget {
  final String? previewPath;
  final String defaultEventName;

  const _MintConfigSheet({
    this.previewPath,
    required this.defaultEventName,
  });

  @override
  State<_MintConfigSheet> createState() => _MintConfigSheetState();
}

class _MintConfigSheetState extends State<_MintConfigSheet> {
  int _step = 0;
  int _count = 1;
  int _fulaPerNft = 10;
  double _royaltyPct = 0;
  bool _advancedOpen = false;
  late TextEditingController _eventController;
  late List<SupportedChain> _validChains;
  late SupportedChain _selectedChain;

  @override
  void initState() {
    super.initState();
    _eventController = TextEditingController(text: widget.defaultEventName);
    _validChains = SupportedChain.all
        .where((c) =>
            c.nftContractAddress != null &&
            c.nftContractAddress !=
                '0x0000000000000000000000000000000000000000')
        .toList();
    _selectedChain =
        _validChains.isNotEmpty ? _validChains.first : SupportedChain.base;
  }

  @override
  void dispose() {
    _eventController.dispose();
    super.dispose();
  }

  int get _totalLocked => _count * _fulaPerNft;

  void _submit() {
    final event = _eventController.text.trim();
    if (event.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Event name is required')),
      );
      return;
    }
    if (_count <= 0 || _count > 10000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Count must be between 1 and 10,000')),
      );
      return;
    }
    if (_fulaPerNft < 0) return;
    final royaltyBps = (_royaltyPct * 100).round();
    Navigator.of(context).pop(MintConfig(
      count: _count,
      fulaPerNft: _fulaPerNft.toString(),
      chain: _selectedChain,
      eventName: event,
      royaltyBps: royaltyBps,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noChains = _validChains.isEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            _header(context),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: _step == 0 ? _buildStep1() : _buildStep2(),
              ),
            ),
            _stickyBar(context, noChains),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          if (_step == 1)
            IconButton(
              icon: const Icon(LucideIcons.chevronLeft),
              onPressed: () => setState(() => _step = 0),
              tooltip: 'Back',
            ),
          Expanded(
            child: Text(
              _step == 0 ? 'Mint NFTs' : 'Review & mint',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.x, size: 18),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  List<Widget> _buildStep1() {
    return [
      if (widget.previewPath != null) _preview(context),
      const SizedBox(height: 16),
      TextField(
        controller: _eventController,
        decoration: const InputDecoration(
          labelText: 'Event / Category',
          border: OutlineInputBorder(),
          prefixIcon: Icon(LucideIcons.tag),
        ),
        maxLength: 128,
      ),
      const SizedBox(height: 12),
      _stepperTile(
        icon: LucideIcons.hash,
        title: 'NFTs to mint',
        subtitle: 'How many copies of this NFT.',
        control: StepperInput(
          value: _count,
          min: 1,
          max: 10000,
          onChanged: (v) => setState(() => _count = v),
        ),
      ),
      const SizedBox(height: 8),
      _stepperTile(
        icon: LucideIcons.coins,
        title: 'Lock FULA per NFT',
        subtitle:
            'FULA stays inside the NFT. The only way to get it back is to burn the NFT.',
        control: StepperInput(
          value: _fulaPerNft,
          min: 0,
          wide: true,
          suffix: 'FULA',
          onChanged: (v) => setState(() => _fulaPerNft = v),
        ),
      ),
      const SizedBox(height: 8),
      _advancedCollapsible(),
      if (_validChains.isEmpty) ...[
        const SizedBox(height: 12),
        Text(
          'NFT contract not yet deployed. Minting will be available soon.',
          style: TextStyle(color: Colors.orange[700], fontSize: 12),
        ),
      ],
    ];
  }

  List<Widget> _buildStep2() {
    final theme = Theme.of(context);
    return [
      if (widget.previewPath != null) _preview(context),
      const SizedBox(height: 16),
      _summaryRow(context, 'Event', _eventController.text.trim()),
      _summaryRow(context, 'NFTs', '$_count'),
      _summaryRow(context, 'Locked FULA each', '$_fulaPerNft FULA'),
      _summaryRow(context, 'Total locked', '$_totalLocked FULA',
          emphasize: true),
      _summaryRow(
          context, 'Royalty', '${_royaltyPct.toStringAsFixed(_royaltyPct == _royaltyPct.roundToDouble() ? 0 : 2)}%'),
      _summaryRow(context, 'Chain', _selectedChain.chainName),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.primaryFaint,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(LucideIcons.info,
                size: 16, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'You\'ll be asked to approve the transaction in your wallet.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _preview(BuildContext context) {
    final path = widget.previewPath!;
    final file = File(path);
    final isImage = RegExp(r'\.(jpe?g|png|gif|webp|bmp)$', caseSensitive: false)
        .hasMatch(path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isImage && file.existsSync())
              Image.file(file, fit: BoxFit.cover)
            else
              Container(
                color: Theme.of(context).cardColor,
                alignment: Alignment.center,
                child: const Icon(LucideIcons.gem, size: 48),
              ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                margin: const EdgeInsets.all(8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _shortName(path),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _shortName(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    return name.length > 32 ? '${name.substring(0, 29)}…' : name;
  }

  Widget _stepperTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget control,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          control,
        ],
      ),
    );
  }

  Widget _advancedCollapsible() {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _advancedOpen = !_advancedOpen),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(LucideIcons.settings2,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Royalty ${_royaltyPct.toStringAsFixed(_royaltyPct == _royaltyPct.roundToDouble() ? 0 : 2)}% · ${_selectedChain.chainName}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  Text(
                    _advancedOpen ? 'Hide' : 'Edit',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: _advancedOpen
                ? Padding(
                    padding:
                        const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Icon(LucideIcons.percent, size: 16),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text('Creator royalty',
                                  style: TextStyle(fontSize: 12)),
                            ),
                            StepperInput(
                              value: _royaltyPct.round(),
                              min: 0,
                              max: 100,
                              suffix: '%',
                              onChanged: (v) =>
                                  setState(() => _royaltyPct = v.toDouble()),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<SupportedChain>(
                          value: _selectedChain,
                          decoration: const InputDecoration(
                            labelText: 'Chain',
                            border: OutlineInputBorder(),
                            isDense: true,
                            prefixIcon: Icon(LucideIcons.link),
                          ),
                          items: _validChains
                              .map((c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(c.chainName),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) {
                              setState(() => _selectedChain = v);
                            }
                          },
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(BuildContext context, String label, String value,
      {bool emphasize = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
              color: emphasize
                  ? AppColors.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stickyBar(BuildContext context, bool noChains) {
    final theme = Theme.of(context);
    final ctaLabel = _step == 0 ? 'Continue' : 'Mint';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'You\'ll lock',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '$_totalLocked FULA',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: noChains
                ? null
                : () {
                    if (_step == 0) {
                      setState(() => _step = 1);
                    } else {
                      _submit();
                    }
                  },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
            child: Text(
              ctaLabel,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
