import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';
import 'package:fula_files/core/services/wallet_service.dart' show WalletService, WalletServiceException, walletNavigatorKey;
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

enum PurchaseStep {
  initializing,
  connectWallet,
  enterAmount,
  processing,
  success,
  error,
}

class PurchaseDialog extends StatefulWidget {
  final SupportedChain selectedChain;
  final List<WalletInfo> linkedWallets;

  const PurchaseDialog({
    super.key,
    required this.selectedChain,
    required this.linkedWallets,
  });

  @override
  State<PurchaseDialog> createState() => _PurchaseDialogState();
}

class _PurchaseDialogState extends State<PurchaseDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  PurchaseStep _step = PurchaseStep.initializing;
  BigInt _balance = BigInt.zero;
  double _balanceDouble = 0.0;
  double? _amount;
  String? _errorMessage;
  String? _txHash;
  bool _isCancelled = false;
  String _statusMessage = 'Initializing...';
  String? _successMessage;

  // Track the current linked wallets (may be updated after linking)
  late List<WalletInfo> _linkedWallets;

  @override
  void initState() {
    super.initState();
    _linkedWallets = List.from(widget.linkedWallets);
    _initializeWallet();
  }

  Future<void> _initializeWallet() async {
    if (!mounted) return;

    setState(() {
      _step = PurchaseStep.initializing;
      _statusMessage = 'Initializing wallet...';
    });

    try {
      // Initialize wallet service with the root navigator context (from walletNavigatorKey)
      // This ensures the modal uses a stable context
      if (!WalletService.instance.isInitialized) {
        debugPrint('PurchaseDialog: Initializing wallet service...');
        // Use the navigator key context if available, otherwise use current context
        final navContext = walletNavigatorKey.currentContext ?? context;
        await WalletService.instance.initialize(navContext);
      }

      if (_isCancelled || !mounted) return;

      // Check if already connected
      if (WalletService.instance.isConnected) {
        final address = WalletService.instance.connectedAddress;
        debugPrint('PurchaseDialog: Wallet already connected: $address');

        // Check if this wallet needs to be linked
        await _ensureWalletLinked(address!);

        if (_isCancelled || !mounted) return;

        // Fetch balance
        setState(() => _statusMessage = 'Fetching balance...');
        await _fetchBalance();

        if (_isCancelled || !mounted) return;

        setState(() => _step = PurchaseStep.enterAmount);
      } else {
        // Need to connect wallet
        debugPrint('PurchaseDialog: No wallet connected, showing connect screen');
        if (mounted) {
          setState(() {
            _step = PurchaseStep.connectWallet;
            _statusMessage = '';
          });
        }
      }
    } catch (e) {
      debugPrint('PurchaseDialog: Init error: $e');
      // Don't show error for init failures, just show connect wallet screen
      if (mounted && !_isCancelled) {
        setState(() {
          _step = PurchaseStep.connectWallet;
          _statusMessage = '';
        });
      }
    }
  }

  Future<void> _ensureWalletLinked(String address) async {
    // Check if this wallet is already linked
    final isLinked = _linkedWallets.any(
      (w) => w.address.toLowerCase() == address.toLowerCase(),
    );

    if (!isLinked) {
      debugPrint('PurchaseDialog: Wallet not linked, linking now...');
      setState(() => _statusMessage = 'Linking wallet...');

      try {
        final message = WalletService.instance.generateLinkMessage(address);
        final signature = await WalletService.instance.signLinkMessage(message);

        if (_isCancelled) return;

        final chainId = WalletService.instance.connectedChainId ?? widget.selectedChain.chainId;
        await BillingApiService.instance.linkWallet(
          address: address,
          chainId: chainId,
          signature: signature,
          message: message,
        );

        debugPrint('PurchaseDialog: Wallet linked successfully');

        // Add to local list
        _linkedWallets.add(WalletInfo(
          address: address,
          chainId: chainId,
          isVerified: true,
          connectedAt: DateTime.now(),
        ));
      } catch (e) {
        debugPrint('PurchaseDialog: Failed to link wallet: $e');
        throw Exception('Failed to link wallet. Please try again.');
      }
    } else {
      debugPrint('PurchaseDialog: Wallet already linked');
    }
  }

  Future<void> _connectWallet() async {
    if (_isCancelled) return;

    setState(() {
      _step = PurchaseStep.processing;
      _statusMessage = 'Opening wallet...';
    });

    try {
      // Use the root navigator context for wallet operations
      final navContext = walletNavigatorKey.currentContext ?? context;
      debugPrint('PurchaseDialog: Opening wallet connect modal...');
      final address = await WalletService.instance.connectWallet(navContext);

      if (_isCancelled || !mounted) return;

      if (address == null) {
        debugPrint('PurchaseDialog: Wallet connection cancelled or failed');
        setState(() {
          _step = PurchaseStep.connectWallet;
          _statusMessage = '';
        });
        return;
      }

      debugPrint('PurchaseDialog: Wallet connected: $address');

      // Ensure wallet is linked
      await _ensureWalletLinked(address);

      if (_isCancelled || !mounted) return;

      // Fetch balance
      setState(() => _statusMessage = 'Fetching balance...');
      await _fetchBalance();

      if (_isCancelled || !mounted) return;

      setState(() => _step = PurchaseStep.enterAmount);
    } catch (e) {
      debugPrint('PurchaseDialog: Connect wallet error: $e');
      if (_isCancelled || !mounted) return;
      setState(() {
        _step = PurchaseStep.error;
        _errorMessage = ErrorMessages.forBilling(e);
      });
    }
  }

  Future<void> _fetchBalance() async {
    try {
      _balance = await WalletService.instance.getFulaBalance(widget.selectedChain);
      // Convert from wei to FULA (18 decimals)
      // Use string conversion for precision
      final balanceStr = _balance.toString();
      if (balanceStr.length <= 18) {
        _balanceDouble = double.parse('0.${'0' * (18 - balanceStr.length)}$balanceStr');
      } else {
        final integerPart = balanceStr.substring(0, balanceStr.length - 18);
        final decimalPart = balanceStr.substring(balanceStr.length - 18);
        _balanceDouble = double.parse('$integerPart.$decimalPart');
      }
      debugPrint('PurchaseDialog: Balance = $_balanceDouble FULA');
    } catch (e) {
      debugPrint('PurchaseDialog: Failed to fetch balance: $e');
      _balance = BigInt.zero;
      _balanceDouble = 0.0;
    }
  }

  void _setPercentage(double percentage) {
    final amount = _balanceDouble * percentage;
    // Round to 2 decimal places
    final roundedAmount = (amount * 100).floor() / 100;
    _controller.text = roundedAmount.toStringAsFixed(2);
    setState(() => _amount = roundedAmount);
  }

  Future<void> _purchase() async {
    if (_isCancelled) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _step = PurchaseStep.processing;
      _statusMessage = 'Preparing transaction...';
    });

    try {
      final chain = widget.selectedChain;
      final vaultAddress = chain.vaultAddress ?? SupportedChain.defaultVaultAddress;

      // Convert amount to wei (18 decimals)
      final amountWei = BigInt.from(_amount! * 1e18);

      setState(() => _statusMessage = 'Please confirm in your wallet...');

      debugPrint('PurchaseDialog: Sending transfer to $vaultAddress');

      // Send the transfer
      final txHash = await WalletService.instance.sendErc20Transfer(
        chain: chain,
        toAddress: vaultAddress,
        amount: amountWei,
      );

      if (_isCancelled || !mounted) return;

      debugPrint('PurchaseDialog: Transaction sent: $txHash');
      _txHash = txHash;

      // Wait for transaction to settle before claiming
      setState(() => _statusMessage = 'Waiting for confirmation...');
      await Future.delayed(const Duration(seconds: 5));

      if (_isCancelled || !mounted) return;

      // Try to claim credits
      setState(() => _statusMessage = 'Claiming storage credits...');

      try {
        await BillingApiService.instance.claimCredits(
          txHash: txHash,
          chainId: chain.chainId,
        );

        debugPrint('PurchaseDialog: Credits claimed successfully');

        if (_isCancelled || !mounted) return;

        setState(() {
          _step = PurchaseStep.success;
          _successMessage = 'Storage credits added immediately!';
        });
      } on BillingApiException catch (e) {
        debugPrint('PurchaseDialog: Claim failed: ${e.message}');
        // Transaction succeeded but claim failed - show success with info
        if (_isCancelled || !mounted) return;

        setState(() {
          _step = PurchaseStep.success;
          _successMessage = 'Transaction sent! Credits will be applied within 10 minutes.';
        });
      }
    } catch (e) {
      debugPrint('PurchaseDialog: Purchase error: $e');
      if (_isCancelled || !mounted) return;
      setState(() {
        _step = PurchaseStep.error;
        _errorMessage = ErrorMessages.forBilling(e);
      });
    }
  }

  void _cancel() {
    _isCancelled = true;
    Navigator.pop(context);
  }

  void _retry() {
    setState(() {
      _step = PurchaseStep.initializing;
      _errorMessage = null;
      _isCancelled = false;
      _txHash = null;
      _successMessage = null;
    });
    _initializeWallet();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            LucideIcons.hardDrive,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          const Text('Get Storage'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: _buildContent(),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildContent() {
    switch (_step) {
      case PurchaseStep.initializing:
        return _buildInitializingContent();
      case PurchaseStep.connectWallet:
        return _buildConnectWalletContent();
      case PurchaseStep.enterAmount:
        return _buildEnterAmountContent();
      case PurchaseStep.processing:
        return _buildProcessingContent();
      case PurchaseStep.success:
        return _buildSuccessContent();
      case PurchaseStep.error:
        return _buildErrorContent();
    }
  }

  Widget _buildInitializingContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          _statusMessage,
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildConnectWalletContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          LucideIcons.wallet,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Connect your wallet to get storage',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Send FULA tokens on ${widget.selectedChain.chainName} to add storage',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildEnterAmountContent() {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Balance display
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.wallet,
                  size: 20,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your FULA Balance',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                            ),
                      ),
                      Text(
                        '${_balanceDouble.toStringAsFixed(2)} FULA',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    await _fetchBalance();
                    setState(() {});
                  },
                  icon: Icon(
                    LucideIcons.refreshCw,
                    size: 18,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                  tooltip: 'Refresh balance',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Text(
            'Amount to send',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),

          // Percentage buttons
          Row(
            children: [
              _buildPercentageButton('25%', 0.25),
              const SizedBox(width: 8),
              _buildPercentageButton('50%', 0.50),
              const SizedBox(width: 8),
              _buildPercentageButton('75%', 0.75),
              const SizedBox(width: 8),
              _buildPercentageButton('100%', 1.0),
            ],
          ),
          const SizedBox(height: 12),

          // Custom amount input
          TextFormField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
            ],
            decoration: const InputDecoration(
              labelText: 'Amount',
              suffixText: 'FULA',
              border: OutlineInputBorder(),
              prefixIcon: Icon(LucideIcons.coins),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter an amount';
              }
              final amount = double.tryParse(value);
              if (amount == null || amount <= 0) {
                return 'Please enter a valid amount';
              }
              if (amount < 1) {
                return 'Minimum amount is 1 FULA';
              }
              if (amount > _balanceDouble) {
                return 'Insufficient balance';
              }
              return null;
            },
            onChanged: (value) {
              setState(() => _amount = double.tryParse(value));
            },
          ),
          const SizedBox(height: 16),

          // Chain info
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      LucideIcons.link,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Network: ${widget.selectedChain.chainName}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      LucideIcons.building2,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Vault: ${_shortenAddress(widget.selectedChain.vaultAddress ?? SupportedChain.defaultVaultAddress)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPercentageButton(String label, double percentage) {
    return Expanded(
      child: OutlinedButton(
        onPressed: _balanceDouble > 0 ? () => _setPercentage(percentage) : null,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildProcessingContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          _statusMessage,
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Please wait...',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Widget _buildSuccessContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          LucideIcons.checkCircle,
          size: 48,
          color: Colors.green,
        ),
        const SizedBox(height: 16),
        Text(
          'Storage Added!',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_amount?.toStringAsFixed(2)} FULA sent successfully',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (_txHash != null) ...[
          const SizedBox(height: 8),
          Text(
            'Tx: ${_shortenAddress(_txHash!)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
        if (_successMessage != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.info,
                  size: 16,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _successMessage!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildErrorContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          LucideIcons.alertCircle,
          size: 48,
          color: Colors.red,
        ),
        const SizedBox(height: 16),
        Text(
          'Failed',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          _errorMessage ?? 'Unknown error',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  List<Widget> _buildActions() {
    switch (_step) {
      case PurchaseStep.initializing:
        return [
          TextButton(
            onPressed: _cancel,
            child: const Text('Cancel'),
          ),
        ];
      case PurchaseStep.connectWallet:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: _connectWallet,
            icon: const Icon(LucideIcons.wallet),
            label: const Text('Connect Wallet'),
          ),
        ];
      case PurchaseStep.enterAmount:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _amount != null && _amount! >= 1 && _amount! <= _balanceDouble
                ? _purchase
                : null,
            child: const Text('Get Storage'),
          ),
        ];
      case PurchaseStep.processing:
        return [
          FilledButton.tonal(
            onPressed: _cancel,
            child: const Text('Cancel'),
          ),
        ];
      case PurchaseStep.success:
        return [
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Done'),
          ),
        ];
      case PurchaseStep.error:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: _retry,
            child: const Text('Try Again'),
          ),
        ];
    }
  }

  String _shortenAddress(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 8)}...${address.substring(address.length - 6)}';
  }
}
