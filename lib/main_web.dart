// FxFiles web entrypoint.
//
// Build:  flutter build web --release -t lib/main_web.dart
// Dev:    flutter run -d chrome -t lib/main_web.dart
//
// Keeps the web compile graph free of dart:io: imports only the
// platform-neutral cloud core (AuthCore/FulaApiService/etc. via the
// web shell) — never lib/app or the native service mesh.
//
// E2E hooks (used by the headless-Chrome harness). Compiled OUT of
// production builds: only a build made with --dart-define=E2E=true
// contains them. The active mode comes from the URL at runtime so one
// test build covers every scenario:
//   ?e2e=create               create a vault with a fresh phrase
//   ?e2e=signin&seed=w1+w2…   open an existing vault
//   ?e2e=restore              assert the persisted session restores
//   ?e2e=signout              sign out + assert storage cleared
// Progress + results are print()ed with an [e2e] prefix.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/platform/rust_lib_init.dart' as rust_lib;
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/app_web.dart';
import 'package:fula_files/web/services/web_session.dart';

const bool _e2eEnabled = bool.fromEnvironment('E2E');

String get _e2eMode => !_e2eEnabled
    ? ''
    : (Uri.parse(web.window.location.href).queryParameters['e2e'] ?? '');
String get _e2eSeed => !_e2eEnabled
    ? ''
    : (Uri.parse(web.window.location.href).queryParameters['seed'] ?? '');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Object? bootError;
  var restored = false;
  try {
    // Load pkg/fula_flutter.js + wasm. Everything crypto depends on it.
    await rust_lib.ensureRustLibInitialized();

    await SecureStorageService.instance.init();
    await IpfsGatewayHelper.init();

    restored = await WebSession.instance.restore();
  } catch (e) {
    bootError = e;
    debugPrint('web boot error: $e');
  }

  if (_e2eMode.isNotEmpty) {
    unawaited(_runE2E(bootError: bootError, restored: restored));
  }

  if (bootError != null) {
    runApp(_BootErrorApp(error: bootError.toString()));
    return;
  }

  runApp(const FxFilesWebApp());
}

Future<void> _runE2E({Object? bootError, required bool restored}) async {
  void log(String line) {
    // ignore: avoid_print
    print('[e2e] $line');
  }

  log('mode=$_e2eMode bootError=${bootError ?? 'none'}');
  try {
    switch (_e2eMode) {
      case 'create':
        final seed = _e2eSeed.isNotEmpty
            ? _e2eSeed
            : await WebSession.instance.generateRecoveryMnemonic();
        log('seed-words=${seed.split(' ').length}');
        // The seed itself is logged ONLY under the explicit e2e flag so
        // the harness can save it for the follow-up restore/sign-in runs.
        log('seed=$seed');
        await WebSession.instance.signInModeC(seed: seed);
        log('signin-ok euid=${WebSession.instance.user?.id}');
        log('fula-configured=${FulaApiService.instance.isConfigured}');
        break;
      case 'signin':
        if (_e2eSeed.isEmpty) {
          log('FAIL: signin mode needs E2E_SEED');
          break;
        }
        await WebSession.instance.signInModeC(seed: _e2eSeed);
        log('signin-ok euid=${WebSession.instance.user?.id}');
        log('fula-configured=${FulaApiService.instance.isConfigured}');
        break;
      case 'restore':
        log('restored=$restored euid=${WebSession.instance.user?.id ?? 'none'}');
        log('fula-configured=${FulaApiService.instance.isConfigured}');
        break;
      case 'signout':
        log('restored=$restored');
        await WebSession.instance.signOut();
        final cred = await SecureStorageService.instance
            .readJson(SecureStorageKeys.userCredentials);
        final kek = await SecureStorageService.instance
            .read(SecureStorageKeys.encryptionKey);
        log('signout-ok credentialsCleared=${cred == null} kekCleared=${kek == null}');
        break;
      default:
        log('FAIL: unknown mode');
    }
  } catch (e) {
    log('FAIL: $e');
  }
  log('E2E DONE');
}

class _BootErrorApp extends StatelessWidget {
  final String error;
  const _BootErrorApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FxFiles',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 56),
                const SizedBox(height: 12),
                const Text(
                  'FxFiles could not start',
                  style: TextStyle(fontSize: 20),
                ),
                const SizedBox(height: 8),
                Text(
                  'The encryption engine failed to load. This can happen '
                  'when an ad-blocker blocks WebAssembly files or the '
                  'network dropped mid-load.\n\n$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  // Full page reload re-runs the boot sequence.
                  onPressed: () => web.window.location.reload(),
                  child: const Text('Reload the page'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
