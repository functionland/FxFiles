import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fula_client/fula_client.dart' show RustLib;
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

const String periodicSyncTask = 'periodicSync';
const String uploadTask = 'uploadTask';
const String downloadTask = 'downloadTask';
const String retryFailedTask = 'retryFailedTask';
const String cleanupTask = 'cleanupIncomplete';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // Initialize RustLib in background isolate (required for fula_client FFI)
      await RustLib.init();

      await SecureStorageService.instance.init();
      await LocalStorageService.instance.init();
      
      // Restore auth session which initializes FulaApiService
      final hasSession = await AuthService.instance.checkExistingSession();

      if (!hasSession || !FulaApiService.instance.isConfigured) {
        debugPrint('Background task: Not configured (session: $hasSession, fula: ${FulaApiService.instance.isConfigured})');
        return true;
      }

      switch (task) {
        case periodicSyncTask:
          await _executePeriodicSync();
          break;
        case uploadTask:
          await _executeUploadTask(inputData);
          break;
        case downloadTask:
          await _executeDownloadTask(inputData);
          break;
        case retryFailedTask:
          await _executeRetryFailed();
          break;
        case cleanupTask:
          await _executeCleanupIncomplete();
          break;
      }

      return true;
    } catch (e) {
      debugPrint('Background task failed: $e');
      return false;
    }
  });
}

Future<void> _executePeriodicSync() async {
  final connectivity = await Connectivity().checkConnectivity();
  if (connectivity.contains(ConnectivityResult.none)) {
    debugPrint('No network connection, skipping sync');
    return;
  }

  // Restore any pending tasks from persistent storage
  await SyncService.instance.restoreQueue();

  // Process with 9-minute timeout (WorkManager has 10-min limit)
  final timeout = const Duration(minutes: 9);
  await SyncService.instance.processQueueWithTimeout(timeout);
}

Future<void> _executeUploadTask(Map<String, dynamic>? inputData) async {
  // First restore any existing queue from storage
  await SyncService.instance.restoreQueue();

  if (inputData != null) {
    final localPath = inputData['localPath'] as String?;
    final bucket = inputData['bucket'] as String?;
    final key = inputData['key'] as String?;
    final encrypt = inputData['encrypt'] as bool? ?? true;

    if (localPath != null && bucket != null && key != null) {
      await SyncService.instance.queueUpload(
        localPath: localPath,
        remoteBucket: bucket,
        remoteKey: key,
        encrypt: encrypt,
      );
    }
  }

  // Process with timeout
  final timeout = const Duration(minutes: 9);
  await SyncService.instance.processQueueWithTimeout(timeout);
}

Future<void> _executeDownloadTask(Map<String, dynamic>? inputData) async {
  // First restore any existing queue from storage
  await SyncService.instance.restoreQueue();

  if (inputData != null) {
    final bucket = inputData['bucket'] as String?;
    final key = inputData['key'] as String?;
    final localPath = inputData['localPath'] as String?;
    final decrypt = inputData['decrypt'] as bool? ?? true;

    if (bucket != null && key != null && localPath != null) {
      await SyncService.instance.queueDownload(
        remoteBucket: bucket,
        remoteKey: key,
        localPath: localPath,
        decrypt: decrypt,
      );
    }
  }

  // Process with timeout
  final timeout = const Duration(minutes: 9);
  await SyncService.instance.processQueueWithTimeout(timeout);
}

Future<void> _executeRetryFailed() async {
  // Restore queue first
  await SyncService.instance.restoreQueue();
  await SyncService.instance.retryFailed();

  // Process with timeout
  final timeout = const Duration(minutes: 9);
  await SyncService.instance.processQueueWithTimeout(timeout);
}

Future<void> _executeCleanupIncomplete() async {
  try {
    final buckets = await FulaApiService.instance.listBuckets();
    
    for (final bucket in buckets) {
      final uploads = await FulaApiService.instance.listIncompleteUploads(bucket, '');
      
      for (final upload in uploads) {
        if (upload.initiated != null) {
          final age = DateTime.now().difference(upload.initiated!);
          if (age.inHours > 24 && upload.key != null && upload.uploadId != null) {
            await FulaApiService.instance.removeIncompleteUpload(
              bucket,
              upload.key!,
              upload.uploadId!,
            );
          }
        }
      }
    }
  } catch (e) {
    debugPrint('Cleanup incomplete uploads failed: $e');
  }
}

class BackgroundSyncService {
  BackgroundSyncService._();
  static final BackgroundSyncService instance = BackgroundSyncService._();

  bool _isInitialized = false;
  static const MethodChannel _iosChannel = MethodChannel('land.fx.files/background_sync');

  Future<void> initialize() async {
    if (_isInitialized) return;

    // Initialize WorkManager for Android with timeout to prevent startup hang
    if (Platform.isAndroid) {
      try {
        await Workmanager().initialize(callbackDispatcher).timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            debugPrint('WorkManager initialization timed out - continuing without background sync');
          },
        );
      } catch (e) {
        debugPrint('WorkManager initialization failed: $e');
        // Continue without background sync rather than blocking startup
      }
    }

    // Setup iOS method channel handler for background sync callbacks
    if (Platform.isIOS) {
      _iosChannel.setMethodCallHandler(_handleIOSMethodCall);
    }

    _isInitialized = true;
  }

  /// Handle method calls from iOS native code for background sync
  Future<dynamic> _handleIOSMethodCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'onBackgroundSync':
          // iOS triggered background sync - process queue with timeout
          await _initializeServicesForBackground();
          await SyncService.instance.restoreQueue();
          // iOS BGProcessingTask has longer time (up to 30 minutes)
          await SyncService.instance.processQueueWithTimeout(
            const Duration(minutes: 25),
          );
          return true;

        case 'onBackgroundRefresh':
          // iOS triggered background refresh - quick check only
          await _initializeServicesForBackground();
          await SyncService.instance.restoreQueue();
          // BGAppRefreshTask has ~30 seconds
          await SyncService.instance.processQueueWithTimeout(
            const Duration(seconds: 25),
          );
          return true;

        default:
          return false;
      }
    } catch (e) {
      debugPrint('iOS background sync failed: $e');
      return false;
    }
  }

  /// Initialize services needed for background operations
  Future<void> _initializeServicesForBackground() async {
    // Initialize RustLib in background isolate (required for fula_client FFI)
    await RustLib.init();

    await SecureStorageService.instance.init();
    await LocalStorageService.instance.init();

    // Restore auth session which initializes FulaApiService
    await AuthService.instance.checkExistingSession();
  }

  Future<void> schedulePeriodicSync({
    Duration frequency = const Duration(minutes: 15),
    bool requiresWifi = false,
  }) async {
    if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        'periodic-sync',
        periodicSyncTask,
        frequency: frequency,
        constraints: Constraints(
          networkType: requiresWifi ? NetworkType.unmetered : NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      );
    } else if (Platform.isIOS) {
      // Schedule iOS background tasks via native code
      try {
        await _iosChannel.invokeMethod('scheduleSync');
        debugPrint('Scheduled iOS background sync');
      } catch (e) {
        debugPrint('Failed to schedule iOS background sync: $e');
      }
    }
  }

  Future<void> scheduleUpload({
    required String localPath,
    required String bucket,
    required String key,
    bool encrypt = true,
    bool useMultipart = false,
  }) async {
    final uniqueId = 'upload-${DateTime.now().millisecondsSinceEpoch}';
    
    await Workmanager().registerOneOffTask(
      uniqueId,
      uploadTask,
      inputData: {
        'localPath': localPath,
        'bucket': bucket,
        'key': key,
        'encrypt': encrypt,
        'useMultipart': useMultipart,
      },
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  Future<void> scheduleDownload({
    required String bucket,
    required String key,
    required String localPath,
    bool decrypt = true,
  }) async {
    final uniqueId = 'download-${DateTime.now().millisecondsSinceEpoch}';
    
    await Workmanager().registerOneOffTask(
      uniqueId,
      downloadTask,
      inputData: {
        'bucket': bucket,
        'key': key,
        'localPath': localPath,
        'decrypt': decrypt,
      },
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  Future<void> scheduleRetryFailed() async {
    await Workmanager().registerOneOffTask(
      'retry-failed',
      retryFailedTask,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  Future<void> scheduleCleanupIncomplete() async {
    await Workmanager().registerOneOffTask(
      'cleanup-incomplete',
      cleanupTask,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  Future<void> cancelAll() async {
    if (Platform.isAndroid) {
      await Workmanager().cancelAll();
    } else if (Platform.isIOS) {
      try {
        await _iosChannel.invokeMethod('cancelSync');
      } catch (e) {
        debugPrint('Failed to cancel iOS background sync: $e');
      }
    }
  }

  Future<void> cancelByUniqueName(String uniqueName) async {
    await Workmanager().cancelByUniqueName(uniqueName);
  }
}
