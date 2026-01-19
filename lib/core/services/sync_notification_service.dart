import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service to show/hide sync progress notifications
/// Required by Google Play for foreground service with FOREGROUND_SERVICE_DATA_SYNC
class SyncNotificationService {
  SyncNotificationService._();
  static final SyncNotificationService instance = SyncNotificationService._();

  static const MethodChannel _channel = MethodChannel('land.fx.files/sync_notification');

  bool _isShowing = false;

  /// Show sync in progress notification
  Future<void> showSyncNotification({
    String title = 'Syncing files',
    String body = 'Uploading files to cloud...',
    int progress = -1, // -1 for indeterminate
    int maxProgress = 100,
  }) async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('showSyncNotification', {
        'title': title,
        'body': body,
        'progress': progress,
        'maxProgress': maxProgress,
      });
      _isShowing = true;
    } catch (e) {
      debugPrint('Failed to show sync notification: $e');
    }
  }

  /// Update sync notification progress
  Future<void> updateSyncProgress({
    required int current,
    required int total,
    String? currentFile,
  }) async {
    if (!Platform.isAndroid || !_isShowing) return;

    try {
      final body = currentFile != null
          ? 'Syncing $current of $total: $currentFile'
          : 'Syncing $current of $total files...';

      await _channel.invokeMethod('showSyncNotification', {
        'title': 'Syncing files',
        'body': body,
        'progress': current,
        'maxProgress': total,
      });
    } catch (e) {
      debugPrint('Failed to update sync notification: $e');
    }
  }

  /// Hide sync notification
  Future<void> hideSyncNotification() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('hideSyncNotification');
      _isShowing = false;
    } catch (e) {
      debugPrint('Failed to hide sync notification: $e');
    }
  }

  /// Show sync complete notification
  Future<void> showSyncCompleteNotification({
    required int fileCount,
    bool hasErrors = false,
  }) async {
    if (!Platform.isAndroid) return;

    try {
      final title = hasErrors ? 'Sync completed with errors' : 'Sync complete';
      final body = hasErrors
          ? 'Synced $fileCount files. Some files failed to sync.'
          : 'Successfully synced $fileCount files';

      await _channel.invokeMethod('showSyncCompleteNotification', {
        'title': title,
        'body': body,
      });
      _isShowing = false;
    } catch (e) {
      debugPrint('Failed to show sync complete notification: $e');
    }
  }

  bool get isShowing => _isShowing;
}
