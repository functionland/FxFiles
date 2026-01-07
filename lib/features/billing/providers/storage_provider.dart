import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/core/services/storage_refresh_service.dart';

/// Global state for storage and wallet information.
/// This provider is accessed throughout the app for:
/// - Low storage warnings on home screen
/// - Wallet linking status for onboarding
/// - Storage usage display
class StorageState {
  final StorageInfo? info;
  final List<WalletInfo> wallets;
  final bool isLoading;
  final String? error;
  final DateTime? lastUpdated;

  const StorageState({
    this.info,
    this.wallets = const [],
    this.isLoading = false,
    this.error,
    this.lastUpdated,
  });

  StorageState copyWith({
    StorageInfo? info,
    List<WalletInfo>? wallets,
    bool? isLoading,
    String? error,
    DateTime? lastUpdated,
  }) {
    return StorageState(
      info: info ?? this.info,
      wallets: wallets ?? this.wallets,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  /// Whether user has at least one linked wallet
  bool get hasLinkedWallet => wallets.isNotEmpty;

  /// Whether storage is low (less than 100MB remaining)
  bool get isLowStorage => info?.isLowStorage ?? false;

  /// Total available storage in bytes
  int get totalAvailableBytes => info?.totalAvailableBytes ?? 0;

  /// Current used storage in bytes
  int get currentStorageBytes => info?.currentStorageBytes ?? 0;

  /// Remaining storage in bytes
  int get remainingBytes => info?.remainingBytes ?? 0;

  /// Usage percentage (0.0 to 1.0)
  double get usagePercentage => info?.usagePercentage ?? 0.0;
}

class StorageNotifier extends Notifier<StorageState> {
  @override
  StorageState build() {
    // Register refresh callback with StorageRefreshService
    StorageRefreshService.instance.setRefreshCallback(() {
      loadStorageInfo();
    });

    return const StorageState();
  }

  /// Load storage info and wallets from API
  Future<void> loadStorageInfo() async {
    // Don't reload if already loading
    if (state.isLoading) return;

    state = state.copyWith(isLoading: true, error: null);

    try {
      // Fetch both storage and wallets in parallel
      final results = await Future.wait([
        BillingApiService.instance.getStorageAndCredits(),
        BillingApiService.instance.getWallets(),
      ]);

      final storageInfo = results[0] as StorageInfo;
      final walletsResponse = results[1] as WalletsResponse;

      state = StorageState(
        info: storageInfo,
        wallets: walletsResponse.wallets,
        isLoading: false,
        lastUpdated: DateTime.now(),
      );

      debugPrint('StorageProvider: loaded storage info - '
          '${storageInfo.formattedCurrentStorage} / ${storageInfo.formattedTotalStorage}, '
          '${walletsResponse.wallets.length} wallets');
    } on BillingApiException catch (e) {
      debugPrint('StorageProvider: API error - ${e.message}');
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      debugPrint('StorageProvider: error - $e');
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load storage info: $e',
      );
    }
  }

  /// Refresh storage info (called after uploads/deletes)
  void requestRefresh() {
    StorageRefreshService.instance.requestRefresh();
  }

  /// Clear storage state (e.g., on logout)
  void clear() {
    state = const StorageState();
  }
}

/// Global storage provider
final storageProvider = NotifierProvider<StorageNotifier, StorageState>(() {
  return StorageNotifier();
});
