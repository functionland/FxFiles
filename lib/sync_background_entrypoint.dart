/// Dart entrypoint for the Android `SyncForegroundService`.
///
/// Runs in its own isolate, separate from `MainActivity`'s isolate.
/// When the user swipes the app away mid-upload, `MainActivity` is
/// destroyed and its isolate dies — but `SyncForegroundService` keeps
/// running (via `startForeground` + `stopWithTask=false`) and its
/// isolate, hosted here, continues draining the upload queue.
///
/// Bootstrap mirrors `BackgroundSyncService.callbackDispatcher`
/// (`background_sync_service.dart:32`) but is triggered by the
/// app-owned foreground service instead of WorkManager. The two share
/// `LocalStorageService` (the persistent SyncTask queue on Hive) and
/// `SecureStorageService` (auth tokens). Mutual exclusion against the
/// main isolate is enforced via `UploadQueueLock`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:fula_client/fula_client.dart' show RustLib;

import 'package:fula_files/core/models/upload_progress.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/upload_progress_manager.dart';
import 'package:fula_files/core/services/upload_queue_lock.dart';
import 'package:fula_files/core/services/upload_speed_tracker.dart';

/// Method channel name (must match `SyncForegroundService.METHOD_CHANNEL`
/// on the Kotlin side).
const String _bridgeChannelName = 'land.fx.files/sync_foreground_bridge';

/// How long this isolate waits for the main isolate to release the
/// queue lock before giving up. Once the foreground service is up the
/// main process is protected from kill, so we expect the lock to come
/// free within seconds (main isolate finishes the current task) or
/// stay contended (main is actively processing in foreground). 30
/// minutes is generous; if the main isolate is still going past then,
/// we quietly exit.
const Duration _lockAcquireTimeout = Duration(minutes: 30);

/// How often we re-check the queue when a pass returned with tasks
/// still pending (network blip, consecutive-failure pause, etc.).
const Duration _passRetryInterval = Duration(seconds: 5);

/// Grace period after the queue drains before tearing down — gives
/// any final notification update a moment to land on the OS side.
const Duration _idleShutdownAfter = Duration(seconds: 5);

@pragma('vm:entry-point')
void syncBackgroundEntrypoint() {
  // Required before any method-channel use in a fresh isolate.
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_run());
}

Future<void> _run() async {
  const bridge = MethodChannel(_bridgeChannelName);
  debugPrint('[sync-bg] Entrypoint starting');

  try {
    await _bootstrap();
  } catch (e, st) {
    debugPrint('[sync-bg] Bootstrap failed: $e\n$st');
    await _requestStop(bridge);
    return;
  }

  final lock = UploadQueueLock();
  final acquired = await lock.acquireWithTimeout(_lockAcquireTimeout);
  if (!acquired) {
    debugPrint('[sync-bg] Could not acquire queue lock within '
        '${_lockAcquireTimeout.inMinutes}m — main isolate still owns it. '
        'Exiting service.');
    await _requestStop(bridge);
    return;
  }
  debugPrint('[sync-bg] Acquired queue lock');

  try {
    await _drainQueueUntilEmpty(bridge);
  } catch (e, st) {
    debugPrint('[sync-bg] Drain failed: $e\n$st');
  } finally {
    await lock.release();
    debugPrint('[sync-bg] Released queue lock');
  }

  await _requestStop(bridge);
}

Future<void> _bootstrap() async {
  // FFI library init — same pattern as `callbackDispatcher` in
  // `background_sync_service.dart`. On iOS the bridge uses a process-
  // linked dylib; on Android we let RustLib.init pick up the shared
  // library from the standard search path.
  if (Platform.isIOS) {
    await RustLib.init(
      externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
    );
  } else {
    await RustLib.init();
  }

  await SecureStorageService.instance.init();
  await LocalStorageService.instance.init();
  UploadSpeedTracker.instance.initialize();

  // Skip heavy operations (relinkMappings, restoreFromCloud) — those
  // belong to the main isolate's cold-start path.
  final hasSession = await AuthService.instance
      .checkExistingSession(skipHeavyOperations: true);
  if (!hasSession || !FulaApiService.instance.isConfigured) {
    throw StateError(
      'sync_background_entrypoint: no session or FulaApiService not '
      'configured (hasSession=$hasSession, '
      'configured=${FulaApiService.instance.isConfigured})',
    );
  }
}

Future<void> _drainQueueUntilEmpty(MethodChannel bridge) async {
  // Pull whatever's persisted into the in-memory queue.
  await SyncService.instance.restoreQueue();

  if (SyncService.instance.pendingTaskCount == 0) {
    debugPrint('[sync-bg] Queue empty after restore — nothing to do');
    return;
  }

  // Forward UploadProgressManager batch progress to the service so the
  // foreground notification updates as bytes climb. Tear down on exit.
  void onProgress(BatchUploadProgress? progress) {
    _forwardProgress(bridge, progress);
  }

  UploadProgressManager.instance.addListener(onProgress);
  try {
    // 30-minute drain window per pass — well under the 6-hour FG-service
    // type limit. If a single file is larger than this allows, the
    // pass returns with the task still queued; the outer loop picks it
    // up on the next iteration.
    while (SyncService.instance.pendingTaskCount > 0) {
      await SyncService.instance
          .processQueueWithTimeout(const Duration(minutes: 30));

      if (SyncService.instance.pendingTaskCount == 0) break;

      debugPrint(
        '[sync-bg] Pass returned with '
        '${SyncService.instance.pendingTaskCount} tasks remaining; '
        'pausing before retry',
      );
      await Future<void>.delayed(_passRetryInterval);
    }
  } finally {
    UploadProgressManager.instance.removeListener(onProgress);
  }

  await Future<void>.delayed(_idleShutdownAfter);
}

void _forwardProgress(MethodChannel bridge, BatchUploadProgress? progress) {
  if (progress == null) return;
  try {
    final title = 'Syncing ${progress.fileProgressString}';
    final pct = progress.percentage.round();
    final eta = progress.formattedETA;
    final body = '${progress.formattedPercentage} — $eta remaining';
    unawaited(
      bridge.invokeMethod<void>('updateProgress', <String, dynamic>{
        'title': title,
        'body': body,
        'progress': pct,
        'maxProgress': 100,
        'eta': eta,
      }).catchError((Object e) {
        debugPrint('[sync-bg] Progress forward failed: $e');
      }),
    );
  } catch (e) {
    debugPrint('[sync-bg] Progress build failed: $e');
  }
}

Future<void> _requestStop(MethodChannel bridge) async {
  try {
    await bridge.invokeMethod<void>('stopService');
  } catch (e) {
    debugPrint('[sync-bg] stopService bridge call failed: $e');
  }
}
