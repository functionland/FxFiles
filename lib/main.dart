import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_client/fula_client.dart' show RustLib;
import 'package:fula_files/app/app.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/background_sync_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/face_storage_service.dart';
import 'package:fula_files/core/services/face_detection_service.dart';
import 'package:fula_files/core/services/playlist_service.dart';
import 'package:fula_files/core/services/video_thumbnail_service.dart';
import 'package:fula_files/core/services/pip_service.dart';
import 'package:fula_files/core/services/deep_link_service.dart';
import 'package:fula_files/core/services/storage_refresh_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/features/billing/providers/storage_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize fula_client Rust bridge (required before any fula_client operations)
  await RustLib.init();

  // Initialize services
  await SecureStorageService.instance.init();
  await LocalStorageService.instance.init();

  // Initialize deep link service (must be early to catch initial links)
  await DeepLinkService.instance.init();

  // Check for existing auth session (restores sign-in state)
  await AuthService.instance.checkExistingSession();

  // Initialize face detection services (non-blocking)
  FaceStorageService.instance.init().then((_) {
    FaceDetectionService.instance.init();
  });

  // Initialize video services (non-blocking)
  VideoThumbnailService.instance.init();
  PipService.instance.init();

  // Initialize playlist service (audio player service is initialized on-demand)
  await PlaylistService.instance.init();

  // Initialize background sync
  await BackgroundSyncService.instance.initialize();

  // Check if Fula API is configured and schedule sync
  final jwtToken = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

  if (FulaApiService.instance.isConfigured && jwtToken != null) {
    // Schedule periodic background sync
    await BackgroundSyncService.instance.schedulePeriodicSync();

    // Restore any pending sync tasks from previous session
    await SyncService.instance.restoreQueue();
  }

  // Create provider container for service initialization
  final container = ProviderContainer();

  // Initialize storage refresh service with container
  StorageRefreshService.instance.initialize(container);

  // If JWT is available, trigger initial storage load (non-blocking)
  if (jwtToken != null && jwtToken.isNotEmpty) {
    Future.microtask(() {
      container.read(storageProvider.notifier).loadStorageInfo();
    });
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const FulaFilesApp(),
    ),
  );
}
