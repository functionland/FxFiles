import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fula_files/core/models/upload_progress.dart';
import 'package:fula_files/core/services/upload_progress_manager.dart';

/// Service to show/hide sync progress notifications
/// Required by Google Play for foreground service with FOREGROUND_SERVICE_DATA_SYNC
class SyncNotificationService {
  SyncNotificationService._();
  static final SyncNotificationService instance = SyncNotificationService._();

  /// Set to `'background'` by `sync_background_entrypoint.dart` when
  /// running inside the SyncForegroundService's isolate. In that
  /// isolate the `land.fx.files/sync_notification` channel is NOT
  /// registered (it's a `MainActivity`-only handler) — every call
  /// would surface as `MissingPluginException`. The BG isolate
  /// instead routes notification updates through the
  /// `sync_foreground_bridge` channel, which IS registered on the
  /// service's FlutterEngine and updates the foreground notification
  /// the service is already showing.
  static String isolateRole = 'main';

  static const MethodChannel _androidChannel = MethodChannel('land.fx.files/sync_notification');
  static const MethodChannel _bridgeChannel = MethodChannel('land.fx.files/sync_foreground_bridge');
  static const MethodChannel _iosChannel = MethodChannel('land.fx.files/ios_notification');

  bool get _isBackgroundIsolate => isolateRole == 'background';

  bool _isShowing = false;
  bool _isListeningToProgress = false;
  bool _hasNotificationPermission = false;
  bool _permissionChecked = false;

  /// Start listening to upload progress and updating notifications
  void startListeningToProgress() {
    if (_isListeningToProgress) return;
    _isListeningToProgress = true;

    UploadProgressManager.instance.addListener(_onProgressUpdate);
  }

  /// Stop listening to progress updates
  void stopListeningToProgress() {
    if (!_isListeningToProgress) return;
    _isListeningToProgress = false;

    UploadProgressManager.instance.removeListener(_onProgressUpdate);
  }

  void _onProgressUpdate(BatchUploadProgress? progress) {
    if (progress == null) return;
    // Update notification even during gaps between file uploads
    _updateNotificationWithProgress(progress);
  }

  Future<void> _updateNotificationWithProgress(BatchUploadProgress progress) async {
    // Desktop uses TrayService — skip native notification channels
    if (!Platform.isAndroid && !Platform.isIOS) return;

    // Use file-count based percentage when time-based is 0
    var percentage = progress.percentage.round();
    if (percentage == 0 && progress.totalFiles > 0) {
      percentage = ((progress.completedFiles / progress.totalFiles) * 100).round();
    }
    final title = 'Syncing ${progress.fileProgressString}';
    final body = '${progress.formattedPercentage} - ${progress.formattedETA} remaining';

    if (Platform.isAndroid) {
      await _showAndroidNotification(
        title: title,
        body: body,
        progress: percentage,
        maxProgress: 100,
        eta: progress.formattedETA,
      );
    } else if (Platform.isIOS) {
      await _updateiOSBadge(percentage);
    }
  }

  /// Request notification permission for Android 13+ (API 33+)
  /// Returns true if permission is granted or not required
  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) {
      _hasNotificationPermission = true;
      _permissionChecked = true;
      return true;
    }

    if (_permissionChecked && _hasNotificationPermission) {
      return true;
    }

    try {
      // Check if Android 13+ (API 33+)
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt < 33) {
        debugPrint('Android < 13, notification permission not required');
        _hasNotificationPermission = true;
        _permissionChecked = true;
        return true;
      }

      // Check current permission status
      final status = await Permission.notification.status;
      debugPrint('Sync notification permission status: $status');

      if (status.isGranted) {
        _hasNotificationPermission = true;
        _permissionChecked = true;
        return true;
      }

      if (status.isPermanentlyDenied) {
        debugPrint('Notification permission permanently denied');
        _hasNotificationPermission = false;
        _permissionChecked = true;
        return false;
      }

      // Request the permission
      final result = await Permission.notification.request();
      debugPrint('Sync notification permission request result: $result');

      _hasNotificationPermission = result.isGranted;
      _permissionChecked = true;
      return result.isGranted;
    } catch (e) {
      debugPrint('Error requesting notification permission: $e');
      _permissionChecked = true;
      return false;
    }
  }

  /// Show sync in progress notification
  Future<void> showSyncNotification({
    String title = 'Syncing files',
    String body = 'Uploading files to cloud...',
    int progress = -1, // -1 for indeterminate
    int maxProgress = 100,
  }) async {
    // Start listening to progress updates
    startListeningToProgress();

    if (Platform.isAndroid) {
      // Request notification permission first (Android 13+)
      final hasPermission = await requestNotificationPermission();
      if (!hasPermission) {
        debugPrint('Sync notification skipped - no permission');
        return;
      }

      await _showAndroidNotification(
        title: title,
        body: body,
        progress: progress,
        maxProgress: maxProgress,
      );
    } else if (Platform.isIOS) {
      // iOS: Set initial badge
      await _updateiOSBadge(0);
    }
  }

  Future<void> _showAndroidNotification({
    required String title,
    required String body,
    int progress = -1,
    int maxProgress = 100,
    String? eta,
  }) async {
    try {
      if (_isBackgroundIsolate) {
        // BG isolate: the `sync_notification` channel handler lives on
        // MainActivity's engine, not ours — calling it here just
        // throws MissingPluginException. Route through the bridge
        // that SyncForegroundService DOES have registered.
        await _bridgeChannel.invokeMethod('updateProgress', {
          'title': title,
          'body': body,
          'progress': progress,
          'maxProgress': maxProgress,
          'eta': eta,
        });
      } else {
        await _androidChannel.invokeMethod('showSyncNotification', {
          'title': title,
          'body': body,
          'progress': progress,
          'maxProgress': maxProgress,
          'eta': eta,
        });
      }
      _isShowing = true;
    } catch (e) {
      debugPrint('Failed to show sync notification: $e');
    }
  }

  Future<void> _updateiOSBadge(int percentage) async {
    try {
      await _iosChannel.invokeMethod('updateBadge', {
        'badge': percentage,
      });
    } catch (e) {
      debugPrint('Failed to update iOS badge: $e');
    }
  }

  /// Update sync notification progress
  Future<void> updateSyncProgress({
    required int current,
    required int total,
    String? currentFile,
    String? eta,
  }) async {
    if (!_isShowing && Platform.isAndroid) return;

    // Calculate percentage
    final percentage = total > 0 ? ((current / total) * 100).round() : 0;

    if (Platform.isAndroid) {
      try {
        String body;
        if (eta != null) {
          body = currentFile != null
              ? 'Syncing $current of $total: $currentFile - $eta remaining'
              : 'Syncing $current of $total files - $eta remaining';
        } else {
          body = currentFile != null
              ? 'Syncing $current of $total: $currentFile'
              : 'Syncing $current of $total files...';
        }

        if (_isBackgroundIsolate) {
          await _bridgeChannel.invokeMethod('updateProgress', {
            'title': 'Syncing files ($percentage%)',
            'body': body,
            'progress': percentage,
            'maxProgress': 100,
            'eta': eta,
          });
        } else {
          await _androidChannel.invokeMethod('showSyncNotification', {
            'title': 'Syncing files ($percentage%)',
            'body': body,
            'progress': percentage,
            'maxProgress': 100,
            'eta': eta,
          });
        }
      } catch (e) {
        debugPrint('Failed to update sync notification: $e');
      }
    } else if (Platform.isIOS) {
      await _updateiOSBadge(percentage);
    }
  }

  /// Hide sync notification
  Future<void> hideSyncNotification() async {
    stopListeningToProgress();

    if (Platform.isAndroid) {
      if (_isBackgroundIsolate) {
        // BG isolate doesn't own the FG service's notification — the
        // service does, and it tears it down when the queue drains
        // via the `stopService` bridge call. Calling hideSync here
        // would only target MainActivity's separate notification ID,
        // which doesn't exist in this isolate anyway. No-op.
        _isShowing = false;
        return;
      }
      try {
        await _androidChannel.invokeMethod('hideSyncNotification');
        _isShowing = false;
      } catch (e) {
        debugPrint('Failed to hide sync notification: $e');
      }
    } else if (Platform.isIOS) {
      // Clear iOS badge
      try {
        await _iosChannel.invokeMethod('updateBadge', {
          'badge': 0,
        });
      } catch (e) {
        debugPrint('Failed to clear iOS badge: $e');
      }
    }
  }

  /// Show sync complete notification
  Future<void> showSyncCompleteNotification({
    required int fileCount,
    bool hasErrors = false,
  }) async {
    stopListeningToProgress();

    if (Platform.isAndroid) {
      if (_isBackgroundIsolate) {
        // BG isolate: don't post a separate "complete" notification
        // here. The FG service's own ongoing notification gets torn
        // down by the bridge's `stopService` call when the entrypoint
        // finishes draining. Posting via `sync_notification` here
        // would just throw MissingPluginException (the channel only
        // exists on MainActivity's engine).
        _isShowing = false;
        return;
      }
      try {
        final title = hasErrors ? 'Sync completed with errors' : 'Sync complete';
        final body = hasErrors
            ? 'Synced $fileCount files. Some files failed to sync.'
            : 'Successfully synced $fileCount files';

        await _androidChannel.invokeMethod('showSyncCompleteNotification', {
          'title': title,
          'body': body,
        });
        _isShowing = false;
      } catch (e) {
        debugPrint('Failed to show sync complete notification: $e');
      }
    } else if (Platform.isIOS) {
      // Clear badge and optionally show local notification
      try {
        await _iosChannel.invokeMethod('showSyncComplete', {
          'fileCount': fileCount,
          'hasErrors': hasErrors,
        });
      } catch (e) {
        debugPrint('Failed to show iOS sync complete: $e');
      }
    }
  }

  bool get isShowing => _isShowing;
}
