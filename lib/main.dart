import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart' show ExternalLibrary;
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
import 'package:fula_files/core/services/sync_notification_service.dart';
import 'package:fula_files/core/services/upload_speed_tracker.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';
import 'package:fula_files/core/services/website_service.dart';
import 'package:fula_files/core/services/nft_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/blox_discovery_service.dart';
import 'package:fula_files/features/billing/providers/storage_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Global startup timeout to prevent app from hanging indefinitely
  const startupTimeout = Duration(seconds: 15);
  ProviderContainer? container;

  try {
    container = await _initializeApp().timeout(
      startupTimeout,
      onTimeout: () {
        debugPrint('App initialization timed out after ${startupTimeout.inSeconds}s');
        throw TimeoutException('Startup timeout', startupTimeout);
      },
    );
  } catch (e) {
    debugPrint('Startup error: $e');
    // Show error recovery UI
    runApp(StartupErrorApp(error: e.toString()));
    return;
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const FulaFilesApp(),
    ),
  );
}

/// Initialize all app services with proper error handling
Future<ProviderContainer> _initializeApp() async {
  // Initialize fula_client Rust bridge (required before any fula_client operations)
  // On iOS, the Rust library is statically linked into the executable,
  // so we need to use DynamicLibrary.process() instead of loading a framework
  try {
    if (Platform.isIOS) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
      ).timeout(const Duration(seconds: 5));
    } else {
      await RustLib.init().timeout(const Duration(seconds: 5));
    }
  } catch (e) {
    debugPrint('RustLib initialization failed: $e');
    // Continue - some features won't work but app can still run
  }

  // Initialize services with timeout protection (iOS 26+ can hang on storage init)
  try {
    await SecureStorageService.instance.init().timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('SecureStorageService initialization failed: $e');
  }

  try {
    await LocalStorageService.instance.init().timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('LocalStorageService initialization failed: $e');
    // Continue - app can still run with limited functionality
  }

  // Initialize deep link service (must be early to catch initial links)
  try {
    await DeepLinkService.instance.init().timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('DeepLink service initialization failed: $e');
  }

  // Check for existing auth session (restores sign-in state)
  // Use timeout to prevent hang on iOS 26+ and Android 16+ with Credential Manager
  try {
    await AuthService.instance.checkExistingSession().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('Auth session check timed out - continuing without restored session');
        return false;
      },
    );
  } catch (e) {
    debugPrint('Auth session check error: $e');
  }

  // Initialize blox discovery service with saved pairing info (non-blocking)
  _initBloxDiscovery();

  // Initialize face detection services (non-blocking)
  FaceStorageService.instance.init().then((_) {
    FaceDetectionService.instance.init();
  });

  // Initialize tag storage service (non-blocking)
  TagStorageService.instance.init();

  // Initialize website service (non-blocking)
  WebsiteService.instance.init();

  // Initialize NFT service and wallet (non-blocking)
  NftService.instance.init();
  NftWalletService.instance.getAddress();

  // Initialize video services (non-blocking)
  VideoThumbnailService.instance.init();
  PipService.instance.init();

  // Initialize playlist service with timeout (audio player service is initialized on-demand)
  try {
    await PlaylistService.instance.init().timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('PlaylistService initialization failed: $e');
  }

  // Initialize upload speed tracker for progress estimation
  UploadSpeedTracker.instance.initialize();

  // Initialize background sync (with internal timeout protection)
  try {
    await BackgroundSyncService.instance.initialize().timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('BackgroundSyncService initialization failed: $e');
  }

  // Request notification permission early for sync notifications (Android 13+)
  // This is non-blocking and will show the permission dialog on first sync
  SyncNotificationService.instance.requestNotificationPermission();

  // Check if Fula API is configured and schedule sync
  // Use timeout for keychain access which can hang on iOS 26+
  String? jwtToken;
  try {
    jwtToken = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken)
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('JWT token read failed: $e');
  }

  if (FulaApiService.instance.isConfigured && jwtToken != null) {
    // Schedule periodic background sync (non-blocking)
    BackgroundSyncService.instance.schedulePeriodicSync();

    // Defer sync queue restoration to AFTER UI renders
    // This prevents blocking the splash screen on large sync queues
    Future.microtask(() async {
      await SyncService.instance.restoreQueue();
    });
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

  return container;
}

/// Initialize BloxDiscoveryService with saved pairing state (non-blocking).
/// This ensures pairedBlox is available throughout the app without needing
/// to visit the pairing screen first.
void _initBloxDiscovery() {
  Future(() async {
    try {
      final secret = await SecureStorageService.instance.read(SecureStorageKeys.bloxPairingSecret);
      if (secret == null || secret.isEmpty) return;

      final hwId = await SecureStorageService.instance.read(SecureStorageKeys.bloxHardwareId);
      final peerId = await SecureStorageService.instance.read(SecureStorageKeys.bloxPeerId);
      final ipOverride = await SecureStorageService.instance.read(SecureStorageKeys.bloxIpOverride);
      final lastKnownIp = await SecureStorageService.instance.read(SecureStorageKeys.bloxLastKnownIp);

      BloxDiscoveryService.instance.setPairedBlox(
        hardwareId: hwId,
        peerId: peerId,
        pairingSecret: secret,
      );

      if (ipOverride != null) {
        BloxDiscoveryService.instance.setManualIp(ipOverride);
      }
      if (lastKnownIp != null) {
        BloxDiscoveryService.instance.setLastKnownIp(lastKnownIp);
      }

      debugPrint('BloxDiscovery: initialized pairing state at startup');

      // Try to initialize local client using saved/last-known IP
      if (await _tryInitLocalClient(secret, timeout: const Duration(seconds: 5))) {
        return; // Success — done
      }

      // Saved IP didn't work (stale IP, mDNS not ready, etc.)
      // Run NSD discovery in background to find device's current IP
      debugPrint('BloxDiscovery: saved IP unreachable, running background NSD discovery');
      _runDiscoveryAndInit(secret);
    } catch (e) {
      debugPrint('BloxDiscovery: startup init failed: $e');
    }
  });
}

/// Attempt to initialize the local Blox download client.
/// Returns true if successful, false otherwise.
Future<bool> _tryInitLocalClient(String secret, {required Duration timeout}) async {
  if (!FulaApiService.instance.isConfigured) {
    debugPrint('BloxDiscovery: FulaApiService not configured, skipping local client');
    return false;
  }

  final blox = BloxDiscoveryService.instance.pairedBlox;
  if (blox == null) {
    debugPrint('BloxDiscovery: no paired blox IP available');
    return false;
  }

  final reachable = await BloxDiscoveryService.instance.quickHealthCheck(timeout: timeout);
  if (!reachable) {
    debugPrint('BloxDiscovery: health check failed (timeout: ${timeout.inSeconds}s)');
    return false;
  }

  await FulaApiService.instance.initializeLocalClient(
    endpoint: blox.s3Url,
    accessToken: secret,
  );
  debugPrint('BloxDiscovery: local client initialized at startup');

  // Persist last known IP for faster startup next time
  if (BloxDiscoveryService.instance.manualIp == null) {
    BloxDiscoveryService.instance.setLastKnownIp(blox.ip);
    await SecureStorageService.instance.write(
      SecureStorageKeys.bloxLastKnownIp,
      blox.ip,
    );
  }

  return true;
}

/// Run a one-shot NSD scan in the background, then attempt to init local client.
/// Non-blocking — fires and forgets so the caller is not delayed.
void _runDiscoveryAndInit(String secret) {
  Future(() async {
    try {
      BloxDiscoveryService.instance.stopScanning();
      BloxDiscoveryService.instance.startScanning(
        interval: const Duration(seconds: 30),
      );
      // NSD scan runs for ~8s; wait 10s to include buffer
      await Future.delayed(const Duration(seconds: 10));
      BloxDiscoveryService.instance.stopScanning();

      // Skip if local client was already initialized (e.g. user visited My Devices)
      if (FulaApiService.instance.hasLocalClient) return;

      if (await _tryInitLocalClient(secret, timeout: const Duration(seconds: 5))) {
        debugPrint('BloxDiscovery: local client initialized after NSD discovery');
      } else {
        debugPrint('BloxDiscovery: device not found after NSD scan — not on same network');
      }
    } catch (e) {
      debugPrint('BloxDiscovery: NSD discovery failed: $e');
    }
  });
}

/// Error recovery app shown when startup fails
class StartupErrorApp extends StatelessWidget {
  final String error;

  const StartupErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Colors.red,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Startup Error',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'The app encountered an error during startup. This may be due to corrupted data or a temporary issue.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[400],
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    error,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () {
                    // Try to restart the app
                    main();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () async {
                    // Clear potentially corrupted data and retry
                    try {
                      await LocalStorageService.instance.clearSyncQueue();
                      await LocalStorageService.instance.clearAllSyncStates();
                      debugPrint('Cleared sync data, restarting...');
                    } catch (e) {
                      debugPrint('Failed to clear data: $e');
                    }
                    main();
                  },
                  child: const Text('Clear Sync Data & Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
