import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/core/services/wallet_service.dart' show WalletService, WalletServiceException, walletNavigatorKey;
import 'package:fula_files/features/billing/providers/storage_provider.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

/// State for the billing screen
class BillingState {
  final StorageInfo? storageInfo;
  final List<WalletInfo> wallets;
  final List<ChainVaultInfo> supportedChains;
  final CreditHistoryPage? historyPage;
  final SupportedChain selectedChain;
  final bool isLoading;
  final bool isLinkingWallet;
  final bool isPurchasing;
  final bool isLoadingHistory;
  final String? error;
  final String? successMessage;

  const BillingState({
    this.storageInfo,
    this.wallets = const [],
    this.supportedChains = const [],
    this.historyPage,
    this.selectedChain = SupportedChain.base,
    this.isLoading = false,
    this.isLinkingWallet = false,
    this.isPurchasing = false,
    this.isLoadingHistory = false,
    this.error,
    this.successMessage,
  });

  BillingState copyWith({
    StorageInfo? storageInfo,
    List<WalletInfo>? wallets,
    List<ChainVaultInfo>? supportedChains,
    CreditHistoryPage? historyPage,
    SupportedChain? selectedChain,
    bool? isLoading,
    bool? isLinkingWallet,
    bool? isPurchasing,
    bool? isLoadingHistory,
    String? error,
    String? successMessage,
  }) {
    return BillingState(
      storageInfo: storageInfo ?? this.storageInfo,
      wallets: wallets ?? this.wallets,
      supportedChains: supportedChains ?? this.supportedChains,
      historyPage: historyPage ?? this.historyPage,
      selectedChain: selectedChain ?? this.selectedChain,
      isLoading: isLoading ?? this.isLoading,
      isLinkingWallet: isLinkingWallet ?? this.isLinkingWallet,
      isPurchasing: isPurchasing ?? this.isPurchasing,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      error: error,
      successMessage: successMessage,
    );
  }

  bool get hasLinkedWallet => wallets.isNotEmpty;

  /// Get vault address for selected chain
  String? get selectedVaultAddress {
    for (final chain in supportedChains) {
      if (chain.chainId == selectedChain.chainId) {
        return chain.vaultAddress;
      }
    }
    return null;
  }

  /// Get SupportedChain with vault address populated
  SupportedChain? get selectedChainWithVault {
    final vault = selectedVaultAddress;
    if (vault == null) return null;
    return selectedChain.withVaultAddress(vault);
  }
}

class BillingNotifier extends Notifier<BillingState> {
  @override
  BillingState build() {
    return const BillingState();
  }

  /// Load all billing data
  Future<void> loadBillingData() async {
    debugPrint('BillingProvider: loadBillingData() called');
    state = state.copyWith(isLoading: true, error: null);

    try {
      debugPrint('BillingProvider: fetching storage, wallets, and history...');
      final results = await Future.wait([
        BillingApiService.instance.getStorageAndCredits(),
        BillingApiService.instance.getWallets(),
        BillingApiService.instance.getCreditHistory(page: 1, limit: 20),
      ]);

      final storageInfo = results[0] as StorageInfo;
      final walletsResponse = results[1] as WalletsResponse;
      final historyPage = results[2] as CreditHistoryPage;

      debugPrint('BillingProvider: loaded - storage: ${storageInfo.formattedCurrentStorage}, '
          'wallets: ${walletsResponse.wallets.length}, '
          'history entries: ${historyPage.entries.length}');

      state = state.copyWith(
        storageInfo: storageInfo,
        wallets: walletsResponse.wallets,
        supportedChains: walletsResponse.supportedChains,
        historyPage: historyPage,
        isLoading: false,
      );

      // Also update global storage provider
      ref.read(storageProvider.notifier).loadStorageInfo();
    } on BillingApiException catch (e) {
      debugPrint('BillingProvider: API error - ${e.message}');
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      debugPrint('BillingProvider: error - $e');
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forBilling(e, operation: 'load billing data'),
      );
    }
  }

  /// Select chain for purchasing
  void selectChain(SupportedChain chain) {
    state = state.copyWith(selectedChain: chain);
  }

  /// Link a wallet
  Future<bool> linkWallet(BuildContext context) async {
    state = state.copyWith(isLinkingWallet: true, error: null);

    try {
      // Use the root navigator context for wallet operations
      final navContext = walletNavigatorKey.currentContext ?? context;

      // Initialize wallet service if needed
      if (!WalletService.instance.isInitialized) {
        await WalletService.instance.initialize(navContext);
      }

      // Check if already connected, otherwise connect
      String? address = WalletService.instance.connectedAddress;
      if (address == null) {
        // Connect wallet
        address = await WalletService.instance.connectWallet(navContext);
        if (address == null) {
          state = state.copyWith(isLinkingWallet: false);
          return false;
        }
      }

      // Generate and sign message
      final message = WalletService.instance.generateLinkMessage(address);
      final signature = await WalletService.instance.signLinkMessage(message);

      // Link wallet on server
      final chainId = WalletService.instance.connectedChainId ?? 8453;
      await BillingApiService.instance.linkWallet(
        address: address,
        chainId: chainId,
        signature: signature,
        message: message,
      );

      // Refresh wallet list
      final walletsResponse = await BillingApiService.instance.getWallets();
      state = state.copyWith(
        wallets: walletsResponse.wallets,
        supportedChains: walletsResponse.supportedChains,
        isLinkingWallet: false,
        successMessage: 'Wallet linked successfully!',
      );

      // Update global storage provider
      ref.read(storageProvider.notifier).loadStorageInfo();

      return true;
    } on WalletServiceException catch (e) {
      state = state.copyWith(
        isLinkingWallet: false,
        error: e.message,
      );
      return false;
    } on BillingApiException catch (e) {
      state = state.copyWith(
        isLinkingWallet: false,
        error: e.message,
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        isLinkingWallet: false,
        error: ErrorMessages.forBilling(e, operation: 'link wallet'),
      );
      return false;
    }
  }

  /// Cancel wallet linking in progress
  void cancelLinkWallet() {
    if (state.isLinkingWallet) {
      // Disconnect wallet to cancel any pending operations
      WalletService.instance.disconnect();
      state = state.copyWith(isLinkingWallet: false, error: null);
    }
  }

  /// Purchase credits by sending FULA tokens
  Future<bool> purchaseCredits({
    required BuildContext context,
    required double fulaAmount,
  }) async {
    final chainWithVault = state.selectedChainWithVault;
    if (chainWithVault == null || chainWithVault.vaultAddress == null) {
      state = state.copyWith(error: 'Vault address not available');
      return false;
    }

    state = state.copyWith(isPurchasing: true, error: null);

    try {
      // Use the root navigator context for wallet operations
      final navContext = walletNavigatorKey.currentContext ?? context;

      // Initialize wallet service if needed
      if (!WalletService.instance.isInitialized) {
        await WalletService.instance.initialize(navContext);
      }

      // Ensure wallet is connected
      if (!WalletService.instance.isConnected) {
        final address = await WalletService.instance.connectWallet(navContext);
        if (address == null) {
          state = state.copyWith(isPurchasing: false);
          return false;
        }
      }

      // Convert FULA amount to wei (18 decimals)
      final amountWei = BigInt.from(fulaAmount * 1e18);

      // Send ERC20 transfer
      final txHash = await WalletService.instance.sendErc20Transfer(
        chain: chainWithVault,
        toAddress: chainWithVault.vaultAddress!,
        amount: amountWei,
      );

      // Claim credits from transaction
      final claimResponse = await BillingApiService.instance.claimCredits(
        txHash: txHash,
        chainId: chainWithVault.chainId,
      );

      // Refresh storage info
      final storageInfo = await BillingApiService.instance.getStorageAndCredits();
      state = state.copyWith(
        storageInfo: storageInfo,
        isPurchasing: false,
        successMessage: 'Credits purchased! Added ${claimResponse.creditsAdded.toStringAsFixed(2)} FULA',
      );

      // Update global storage provider
      ref.read(storageProvider.notifier).loadStorageInfo();

      // Reload history
      loadMoreHistory(refresh: true);

      return true;
    } on WalletServiceException catch (e) {
      state = state.copyWith(
        isPurchasing: false,
        error: e.message,
      );
      return false;
    } on BillingApiException catch (e) {
      state = state.copyWith(
        isPurchasing: false,
        error: e.message,
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        isPurchasing: false,
        error: ErrorMessages.forBilling(e, operation: 'purchase credits'),
      );
      return false;
    }
  }

  /// Load more credit history (pagination)
  Future<void> loadMoreHistory({bool refresh = false}) async {
    final currentPage = state.historyPage;
    if (!refresh && currentPage != null && !currentPage.hasMore) return;

    final nextPage = refresh ? 1 : (currentPage?.page ?? 0) + 1;

    state = state.copyWith(isLoadingHistory: true);

    try {
      final historyPage = await BillingApiService.instance.getCreditHistory(
        page: nextPage,
        limit: 20,
      );

      if (refresh || currentPage == null) {
        state = state.copyWith(
          historyPage: historyPage,
          isLoadingHistory: false,
        );
      } else {
        // Append to existing entries
        state = state.copyWith(
          historyPage: CreditHistoryPage(
            entries: [...currentPage.entries, ...historyPage.entries],
            page: historyPage.page,
            limit: historyPage.limit,
            totalCount: historyPage.totalCount,
            hasMore: historyPage.hasMore,
          ),
          isLoadingHistory: false,
        );
      }
    } catch (e) {
      state = state.copyWith(
        isLoadingHistory: false,
        error: ErrorMessages.forBilling(e, operation: 'load history'),
      );
    }
  }

  /// Clear error/success messages
  void clearMessages() {
    state = state.copyWith(error: null, successMessage: null);
  }
}

final billingProvider = NotifierProvider<BillingNotifier, BillingState>(() {
  return BillingNotifier();
});
