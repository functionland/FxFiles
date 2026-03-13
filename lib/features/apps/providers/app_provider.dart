import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/app_models.dart';
import 'package:fula_files/core/services/app_store_service.dart';
import 'package:fula_files/core/services/background_sync_service.dart';
import 'package:fula_files/core/services/whatsapp_backup_service.dart';

/// Stream of activated apps, auto-updates on changes.
final activatedAppsProvider = StreamProvider<List<ActivatedApp>>((ref) {
  final initial = AppStoreService.instance.getActivatedApps();
  final controller = StreamController<List<ActivatedApp>>();
  controller.add(initial);

  final subscription = AppStoreService.instance.onAppChanged.listen((apps) {
    controller.add(apps);
  });

  ref.onDispose(() {
    subscription.cancel();
    controller.close();
  });

  return controller.stream;
});

/// Backup history for a specific app.
final backupHistoryProvider = Provider.family<List<BackupRecord>, String>((ref, appId) {
  // Re-read when app state changes
  ref.watch(appProvider);
  return AppStoreService.instance.getBackupHistory(appId);
});

/// State for the app notifier.
class AppState {
  final bool isActivating;
  final bool isBackingUp;
  final bool isRestoring;
  final String? error;
  final String? statusMessage;
  final BackupProgress? progress;

  const AppState({
    this.isActivating = false,
    this.isBackingUp = false,
    this.isRestoring = false,
    this.error,
    this.statusMessage,
    this.progress,
  });

  bool get isBusy => isActivating || isBackingUp || isRestoring;

  AppState copyWith({
    bool? isActivating,
    bool? isBackingUp,
    bool? isRestoring,
    String? error,
    String? statusMessage,
    BackupProgress? progress,
  }) {
    return AppState(
      isActivating: isActivating ?? this.isActivating,
      isBackingUp: isBackingUp ?? this.isBackingUp,
      isRestoring: isRestoring ?? this.isRestoring,
      error: error,
      statusMessage: statusMessage,
      progress: progress,
    );
  }
}

/// Notifier for app operations.
class AppNotifier extends Notifier<AppState> {
  @override
  AppState build() => const AppState();

  Future<ActivatedApp?> activateApp(String appId, {String? iosFolderPath}) async {
    state = state.copyWith(isActivating: true, error: null);
    try {
      final app = await AppStoreService.instance.activateApp(appId, iosFolderPath: iosFolderPath);

      // Restore manifest from cloud (in case of reinstall)
      try {
        await WhatsAppBackupService.instance.restoreManifest(appId);
      } catch (e) {
        debugPrint('AppProvider: manifest restore failed: $e');
      }

      // Schedule automatic background backup (Android only, not iOS)
      if (Platform.isAndroid) {
        try {
          await BackgroundSyncService.instance.scheduleAppBackup(appId: appId);
        } catch (e) {
          debugPrint('AppProvider: schedule backup failed: $e');
        }
      }

      state = state.copyWith(isActivating: false);
      return app;
    } catch (e) {
      state = state.copyWith(isActivating: false, error: e.toString());
      return null;
    }
  }

  Future<void> deactivateApp(String appId) async {
    try {
      await AppStoreService.instance.deactivateApp(appId);
      await BackgroundSyncService.instance.cancelAppBackup(appId);
      ref.invalidateSelf();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> setPassword(String appId, String password) async {
    try {
      await AppStoreService.instance.setAppPassword(appId, password);
      ref.invalidateSelf();
    } catch (e) {
      state = state.copyWith(error: 'Failed to set password: ${e.toString()}');
    }
  }

  Future<BackupRecord?> startBackup(String appId, {String? password, Directory? overrideDir}) async {
    state = state.copyWith(
      isBackingUp: true,
      error: null,
      statusMessage: 'Scanning for changes...',
      progress: const BackupProgress(),
    );

    try {
      final record = await WhatsAppBackupService.instance.runBackup(
        appId: appId,
        password: password,
        overrideDir: overrideDir,
        onProgress: (p) {
          state = state.copyWith(
            progress: p,
            statusMessage: p.currentFile != null
                ? 'Uploading ${p.completedFiles}/${p.totalFiles}: ${p.currentFile}'
                : 'Uploading ${p.completedFiles}/${p.totalFiles}...',
          );
        },
      );
      state = state.copyWith(isBackingUp: false, statusMessage: null, progress: null);
      ref.invalidateSelf();
      return record;
    } catch (e) {
      state = state.copyWith(
        isBackingUp: false,
        error: e.toString(),
        statusMessage: null,
        progress: null,
      );
      return null;
    }
  }

  void cancelBackup() {
    WhatsAppBackupService.instance.cancelBackup();
    state = state.copyWith(isBackingUp: false, statusMessage: null, progress: null);
  }

  Future<void> startRestore({
    required String appId,
    String? password,
    BackupCategory? category,
    List<String>? specificPaths,
    Directory? restoreDir,
  }) async {
    state = state.copyWith(
      isRestoring: true,
      error: null,
      statusMessage: 'Preparing restore...',
      progress: const BackupProgress(),
    );

    try {
      await WhatsAppBackupService.instance.restoreFiles(
        appId: appId,
        password: password,
        category: category,
        specificPaths: specificPaths,
        restoreDir: restoreDir,
        onProgress: (p) {
          state = state.copyWith(
            progress: p,
            statusMessage: p.currentFile != null
                ? 'Restoring ${p.completedFiles}/${p.totalFiles}: ${p.currentFile}'
                : 'Restoring ${p.completedFiles}/${p.totalFiles}...',
          );
        },
      );
      state = state.copyWith(isRestoring: false, statusMessage: null, progress: null);
    } catch (e) {
      state = state.copyWith(
        isRestoring: false,
        error: e.toString(),
        statusMessage: null,
        progress: null,
      );
    }
  }

  void cancelRestore() {
    WhatsAppBackupService.instance.cancelRestore();
    state = state.copyWith(isRestoring: false, statusMessage: null, progress: null);
  }

  Future<void> deleteBackup(String appId, String backupId) async {
    try {
      await WhatsAppBackupService.instance.deleteBackup(appId, backupId);
      ref.invalidateSelf();
    } catch (e) {
      state = state.copyWith(error: 'Failed to delete backup: ${e.toString()}');
    }
  }
}

/// Provider for the app notifier.
final appProvider = NotifierProvider<AppNotifier, AppState>(() => AppNotifier());
