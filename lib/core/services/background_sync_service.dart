import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
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
      await SecureStorageService.instance.init();
      await LocalStorageService.instance.init();
      
      final apiUrl = await SecureStorageService.instance.read(SecureStorageKeys.apiGatewayUrl);
      final jwtToken = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
      final ipfsServer = await SecureStorageService.instance.read(SecureStorageKeys.ipfsServerUrl);
      
      if (apiUrl == null || jwtToken == null) {
        debugPrint('Background task: API not configured');
        return true;
      }

      FulaApiService.instance.configure(
        endpoint: apiUrl,
        accessKey: 'JWT:$jwtToken',
        secretKey: 'not-used',
        pinningService: ipfsServer,
        pinningToken: jwtToken,
      );

      await AuthService.instance.checkExistingSession();

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

  await SyncService.instance.processUploadQueue();
  await SyncService.instance.processDownloadQueue();
}

Future<void> _executeUploadTask(Map<String, dynamic>? inputData) async {
  if (inputData == null) return;

  final localPath = inputData['localPath'] as String?;
  final bucket = inputData['bucket'] as String?;
  final key = inputData['key'] as String?;
  final encrypt = inputData['encrypt'] as bool? ?? true;

  if (localPath == null || bucket == null || key == null) return;

  await SyncService.instance.queueUpload(
    localPath: localPath,
    remoteBucket: bucket,
    remoteKey: key,
    encrypt: encrypt,
  );

  await SyncService.instance.processUploadQueue();
}

Future<void> _executeDownloadTask(Map<String, dynamic>? inputData) async {
  if (inputData == null) return;

  final bucket = inputData['bucket'] as String?;
  final key = inputData['key'] as String?;
  final localPath = inputData['localPath'] as String?;
  final decrypt = inputData['decrypt'] as bool? ?? true;

  if (bucket == null || key == null || localPath == null) return;

  await SyncService.instance.queueDownload(
    remoteBucket: bucket,
    remoteKey: key,
    localPath: localPath,
    decrypt: decrypt,
  );

  await SyncService.instance.processDownloadQueue();
}

Future<void> _executeRetryFailed() async {
  await SyncService.instance.retryFailed();
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

  Future<void> initialize() async {
    if (_isInitialized) return;

    await Workmanager().initialize(
      callbackDispatcher,
    );

    _isInitialized = true;
  }

  Future<void> schedulePeriodicSync({
    Duration frequency = const Duration(minutes: 15),
    bool requiresWifi = false,
  }) async {
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
    await Workmanager().cancelAll();
  }

  Future<void> cancelByUniqueName(String uniqueName) async {
    await Workmanager().cancelByUniqueName(uniqueName);
  }
}
