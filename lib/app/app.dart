import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/app/router.dart';
import 'package:fula_files/app/theme/app_theme.dart';
import 'package:fula_files/core/services/blox_discovery_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';
import 'package:fula_files/features/onboarding/screens/terms_of_service_screen.dart';
import 'package:fula_files/shared/widgets/mini_player.dart';

class FulaFilesApp extends ConsumerStatefulWidget {
  const FulaFilesApp({super.key});

  @override
  ConsumerState<FulaFilesApp> createState() => _FulaFilesAppState();
}

class _FulaFilesAppState extends ConsumerState<FulaFilesApp>
    with WidgetsBindingObserver {
  // Track if user accepted ToS in this session (before async save completes)
  bool _acceptedThisSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshBloxConnection();
    }
  }

  /// Re-check local Blox connectivity when app returns to foreground.
  /// Non-blocking — runs entirely in the background.
  void _refreshBloxConnection() {
    Future(() async {
      try {
        final secret = BloxDiscoveryService.instance.pairingSecret;
        if (secret == null) return; // Not paired
        if (!FulaApiService.instance.isConfigured) return;

        // Quick health check on current/last-known IP
        if (await BloxDiscoveryService.instance.quickHealthCheck(
          timeout: const Duration(seconds: 3),
        )) {
          // Device reachable — ensure local client is initialized
          if (!FulaApiService.instance.hasLocalClient) {
            final blox = BloxDiscoveryService.instance.pairedBlox;
            if (blox != null) {
              await FulaApiService.instance.initializeLocalClient(
                endpoint: blox.s3Url,
                accessToken: secret,
              );
              debugPrint('BloxDiscovery: local client initialized on app resume');
            }
          }
          return;
        }

        // Saved IP unreachable — dispose stale local client (avoids 3s timeout
        // per download attempt while NSD scan runs) and discover new IP
        debugPrint('BloxDiscovery: IP unreachable on resume, running NSD scan');
        FulaApiService.instance.disposeLocalClient();

        BloxDiscoveryService.instance.stopScanning();
        BloxDiscoveryService.instance.startScanning(
          interval: const Duration(seconds: 30),
        );
        await Future.delayed(const Duration(seconds: 10));
        BloxDiscoveryService.instance.stopScanning();

        // Skip if already initialized (e.g. user visited My Devices meanwhile)
        if (FulaApiService.instance.hasLocalClient) return;

        final blox = BloxDiscoveryService.instance.pairedBlox;
        if (blox == null) {
          debugPrint('BloxDiscovery: no device found after NSD scan on resume');
          return;
        }

        if (await BloxDiscoveryService.instance.quickHealthCheck(
          timeout: const Duration(seconds: 5),
        )) {
          await FulaApiService.instance.initializeLocalClient(
            endpoint: blox.s3Url,
            accessToken: secret,
          );
          // Persist new IP for next startup
          if (BloxDiscoveryService.instance.manualIp == null) {
            BloxDiscoveryService.instance.setLastKnownIp(blox.ip);
            await SecureStorageService.instance.write(
              SecureStorageKeys.bloxLastKnownIp,
              blox.ip,
            );
          }
          debugPrint('BloxDiscovery: local client initialized on resume after NSD discovery');
        } else {
          debugPrint('BloxDiscovery: device not reachable after NSD scan on resume');
        }
      } catch (e) {
        debugPrint('BloxDiscovery: resume refresh failed: $e');
      }
    });
  }

  void _onTosAccepted() {
    setState(() {
      _acceptedThisSession = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);

    // ToS is accepted if: saved in storage OR accepted this session
    final tosAccepted = settings.tosAccepted || _acceptedThisSession;

    return MaterialApp.router(
      title: 'FxFiles',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.themeMode,
      routerConfig: router,
      builder: (context, child) {
        // Show ToS screen if not accepted
        if (!tosAccepted) {
          return TermsOfServiceScreen(onAccepted: _onTosAccepted);
        }

        return Column(
          children: [
            Expanded(child: child ?? const SizedBox()),
            const MiniPlayer(),
          ],
        );
      },
    );
  }
}
