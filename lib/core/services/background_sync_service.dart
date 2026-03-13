import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart' show ExternalLibrary;
import 'package:fula_client/fula_client.dart' show RustLib;
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/upload_speed_tracker.dart';
import 'package:fula_files/core/services/app_store_service.dart';
import 'package:fula_files/core/services/whatsapp_backup_service.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

const String periodicSyncTask = 'periodicSync';
const String uploadTask = 'uploadTask';
const String downloadTask = 'downloadTask';
const String retryFailedTask = 'retryFailedTask';
const String cleanupTask = 'cleanupIncomplete';
const String appBackupTask = 'appBackup';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // Initialize RustLib in background isolate (required for fula_client FFI)
      if (Platform.isIOS) {
        await RustLib.init(
          externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
        );
      } else {
        await RustLib.init();
      }

      await SecureStorageService.instance.init();
      await LocalStorageService.instance.init();

      // Initialize upload speed tracker for progress estimation
      UploadSpeedTracker.instance.initialize();

      // Restore auth session which initializes FulaApiService
      // Skip heavy operations (relinkMappings, restoreFromCloud) — main app handles those
      final hasSession = await AuthService.instance.checkExistingSession(skipHeavyOperations: true);

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
        case appBackupTask:
          await _executeAppBackup(inputData);
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

Future<void> _executeAppBackup(Map<String, dynamic>? inputData) async {
  final appId = inputData?['appId'] as String? ?? 'whatsapp';
  await AppStoreService.instance.init();
  await WhatsAppBackupService.instance.init();
  if (!AppStoreService.instance.isAppActivated(appId)) return;
  // showNotifications: true → Android top-bar notification, iOS badge
  await WhatsAppBackupService.instance
      .runBackup(appId: appId, showNotifications: true)
      .timeout(const Duration(minutes: 9));
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
  Timer? _desktopSyncTimer;

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
    // On iOS, the Rust library is statically linked into the executable,
    // so we need to use DynamicLibrary.process() instead of loading a framework
    if (Platform.isIOS) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
      );
    } else {
      await RustLib.init();
    }

    await SecureStorageService.instance.init();
    await LocalStorageService.instance.init();

    // Initialize upload speed tracker for progress estimation
    UploadSpeedTracker.instance.initialize();

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
    } else if (PlatformCapabilities.isDesktop) {
      _startDesktopPeriodicSync(interval: frequency);
    }
  }

  /// Start a chained Timer fallback for desktop platforms (no Workmanager).
  /// Uses single-shot timers to prevent overlap when a sync cycle exceeds the interval.
  void _startDesktopPeriodicSync({Duration interval = const Duration(minutes: 15)}) {
    _desktopSyncTimer?.cancel();
    void scheduleNext() {
      _desktopSyncTimer = Timer(interval, () async {
        try {
          if (!FulaApiService.instance.isConfigured) return;
          final connectivity = await Connectivity().checkConnectivity();
          if (connectivity.contains(ConnectivityResult.none)) return;
          await SyncService.instance.restoreQueue();
          await SyncService.instance.processQueueWithTimeout(const Duration(minutes: 9));
        } finally {
          scheduleNext();
        }
      });
    }
    scheduleNext();
    debugPrint('Desktop periodic sync started (interval: ${interval.inMinutes}min)');
  }

  Future<void> scheduleUpload({
    required String localPath,
    required String bucket,
    required String key,
    bool encrypt = true,
    bool useMultipart = false,
  }) async {
    if (PlatformCapabilities.isDesktop) {
      await SyncService.instance.queueUpload(
        localPath: localPath,
        remoteBucket: bucket,
        remoteKey: key,
        encrypt: encrypt,
      );
      SyncService.instance.processQueueWithTimeout(const Duration(minutes: 9));
      return;
    }
    if (!PlatformCapabilities.isMobile) return;
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
    if (PlatformCapabilities.isDesktop) {
      await SyncService.instance.queueDownload(
        remoteBucket: bucket,
        remoteKey: key,
        localPath: localPath,
        decrypt: decrypt,
      );
      SyncService.instance.processQueueWithTimeout(const Duration(minutes: 9));
      return;
    }
    if (!PlatformCapabilities.isMobile) return;
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
    if (PlatformCapabilities.isDesktop) {
      await SyncService.instance.restoreQueue();
      await SyncService.instance.retryFailed();
      SyncService.instance.processQueueWithTimeout(const Duration(minutes: 9));
      return;
    }
    if (!PlatformCapabilities.isMobile) return;
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
    if (PlatformCapabilities.isDesktop) {
      _executeCleanupIncomplete();
      return;
    }
    if (!PlatformCapabilities.isMobile) return;
    await Workmanager().registerOneOffTask(
      'cleanup-incomplete',
      cleanupTask,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  Future<void> scheduleAppBackup({
    required String appId,
    Duration frequency = const Duration(hours: 24),
  }) async {
    if (PlatformCapabilities.isDesktop) return; // Apps not supported on desktop
    if (Platform.isIOS) return; // No automatic backup on iOS
    if (!Platform.isAndroid) return;

    await Workmanager().registerPeriodicTask(
      'app-backup-$appId',
      appBackupTask,
      frequency: frequency,
      inputData: {'appId': appId},
      constraints: Constraints(
        networkType: NetworkType.unmetered,
        requiresBatteryNotLow: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
    debugPrint('Scheduled app backup for $appId every ${frequency.inHours}h');
  }

  /// Run app backup immediately as a one-off WorkManager task (Android only).
  /// This survives app close — WorkManager keeps the task alive even if the
  /// user swipes the app away. On iOS the backup runs inline (foreground only).
  Future<void> runAppBackupNow({required String appId}) async {
    if (!Platform.isAndroid) return;

    final uniqueId = 'app-backup-now-${DateTime.now().millisecondsSinceEpoch}';
    await Workmanager().registerOneOffTask(
      uniqueId,
      appBackupTask,
      inputData: {'appId': appId},
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
    debugPrint('Queued immediate app backup for $appId via WorkManager');
  }

  Future<void> cancelAppBackup(String appId) async {
    if (!Platform.isAndroid) return;
    await Workmanager().cancelByUniqueName('app-backup-$appId');
    debugPrint('Cancelled app backup for $appId');
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
    } else if (PlatformCapabilities.isDesktop) {
      _desktopSyncTimer?.cancel();
      _desktopSyncTimer = null;
    }
  }

  Future<void> cancelByUniqueName(String uniqueName) async {
    if (PlatformCapabilities.isDesktop) return;
    if (!PlatformCapabilities.isMobile) return;
    await Workmanager().cancelByUniqueName(uniqueName);
  }
}
