import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/features/billing/providers/billing_provider.dart';
import 'package:fula_files/features/billing/widgets/credit_stats_card.dart';
import 'package:fula_files/features/billing/widgets/wallet_tile.dart';
import 'package:fula_files/features/billing/widgets/chain_selector.dart';
import 'package:fula_files/features/billing/widgets/history_tile.dart';
import 'package:fula_files/features/billing/widgets/purchase_dialog.dart';

class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen> {
  @override
  void initState() {
    super.initState();
    // Load billing data on screen open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(billingProvider.notifier).loadBillingData();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(billingProvider);

    // Listen for error/success messages
    ref.listen<BillingState>(billingProvider, (previous, next) {
      if (next.error != null && next.error != previous?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.error!),
            backgroundColor: Colors.red,
          ),
        );
        ref.read(billingProvider.notifier).clearMessages();
      }
      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.successMessage!),
            backgroundColor: const Color(0xFF06B597),
          ),
        );
        ref.read(billingProvider.notifier).clearMessages();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Billing'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(billingProvider.notifier).loadBillingData();
        },
        child: state.isLoading && state.storageInfo == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  // Credits & Storage Card
                  CreditStatsCard(storageInfo: state.storageInfo),

                  // Linked Wallets Section
                  _buildSection(
                    context,
                    title: 'Linked Wallets',
                    trailing: state.isLinkingWallet
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : TextButton.icon(
                            onPressed: () => _linkWallet(),
                            icon: const Icon(LucideIcons.plus, size: 18),
                            label: const Text('Link Wallet'),
                          ),
                    child: state.wallets.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                Icon(
                                  LucideIcons.wallet,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'No wallets linked',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Link a wallet to purchase credits',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          )
                        : Column(
                            children: state.wallets
                                .map((wallet) => WalletTile(wallet: wallet))
                                .toList(),
                          ),
                  ),

                  // Get Storage Section
                  _buildSection(
                    context,
                    title: 'Get Storage',
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Select Network',
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 8),
                          ChainSelector(
                            selectedChain: state.selectedChain,
                            onChainSelected: (chain) {
                              ref.read(billingProvider.notifier).selectChain(chain);
                            },
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () => _showPurchaseDialog(),
                              icon: const Icon(LucideIcons.hardDrive),
                              label: const Text('Get Storage'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Connect wallet, select amount, and confirm transfer',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Credit History Section
                  _buildSection(
                    context,
                    title: 'Credit History',
                    child: state.historyPage == null || state.historyPage!.entries.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(
                                    LucideIcons.history,
                                    size: 48,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'No transaction history',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Column(
                            children: [
                              ...state.historyPage!.entries.map(
                                (entry) => HistoryTile(entry: entry),
                              ),
                              if (state.historyPage!.hasMore)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: state.isLoadingHistory
                                      ? const CircularProgressIndicator()
                                      : TextButton(
                                          onPressed: () {
                                            ref.read(billingProvider.notifier).loadMoreHistory();
                                          },
                                          child: const Text('Load More'),
                                        ),
                                ),
                            ],
                          ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    Widget? trailing,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
        ),
        child,
      ],
    );
  }

  Future<void> _linkWallet() async {
    await ref.read(billingProvider.notifier).linkWallet(context);
  }

  Future<void> _showPurchaseDialog() async {
    final state = ref.read(billingProvider);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PurchaseDialog(
        selectedChain: state.selectedChain,
        linkedWallets: state.wallets,
      ),
    );

    // Refresh data if purchase was successful
    if (result == true && mounted) {
      await ref.read(billingProvider.notifier).loadBillingData();
    }
  }
}
