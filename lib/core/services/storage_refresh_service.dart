import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Service to trigger storage info refresh from non-widget code.
/// This allows services like SyncService to request storage updates
/// after uploads/deletes without direct provider access.
class StorageRefreshService {
  static final StorageRefreshService instance = StorageRefreshService._();
  StorageRefreshService._();

  ProviderContainer? _container;

  // Callback that will be set by StorageProvider
  void Function()? _refreshCallback;

  // Debounce timer to prevent too frequent refreshes
  Timer? _debounceTimer;
  static const Duration _debounceDelay = Duration(seconds: 10);

  /// Initialize with provider container (called from main.dart)
  void initialize(ProviderContainer container) {
    _container = container;
    debugPrint('StorageRefreshService initialized');
  }

  /// Set the refresh callback (called by StorageProvider)
  void setRefreshCallback(void Function() callback) {
    _refreshCallback = callback;
  }

  /// Request a storage info refresh with debouncing.
  /// Multiple calls within 10 seconds will be coalesced into one refresh.
  void requestRefresh() {
    debugPrint('StorageRefreshService: refresh requested');

    // Cancel any pending refresh
    _debounceTimer?.cancel();

    // Schedule refresh after delay
    _debounceTimer = Timer(_debounceDelay, () {
      _performRefresh();
    });
  }

  /// Request immediate refresh without debouncing
  void refreshNow() {
    debugPrint('StorageRefreshService: immediate refresh requested');
    _debounceTimer?.cancel();
    _performRefresh();
  }

  void _performRefresh() {
    if (_refreshCallback != null) {
      debugPrint('StorageRefreshService: triggering refresh callback');
      _refreshCallback!();
    } else {
      debugPrint('StorageRefreshService: no refresh callback set');
    }
  }

  /// Cancel any pending refresh
  void cancelPendingRefresh() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  void dispose() {
    _debounceTimer?.cancel();
    _refreshCallback = null;
    _container = null;
  }
}
