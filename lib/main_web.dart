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
//   ?e2e=upload               upload small (100 KB) + large (5 MB)
//                             deterministic patterns to documents-v8
//   ?e2e=download             download both + byte-compare vs patterns
//   ?e2e=list                 merged documents listing, assert presence
//   ?e2e=delete               delete both + assert absent from listing
// Progress + results are print()ed with an [e2e] prefix.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:web/web.dart' as web;

import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/models/share_token.dart' as share_model;
import 'package:fula_files/core/platform/rust_lib_init.dart' as rust_lib;
import 'package:fula_files/core/services/automate_task_service.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/core/services/category_listing.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/share_link_builder.dart';
import 'package:fula_files/web/app_web.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_nft_service.dart';
import 'package:fula_files/web/services/web_session.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

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

    // Hive → IndexedDB. Automate task configs persist locally per
    // browser, same as the app persists them locally per device (the
    // task's tag still syncs through the cloud tag manifest).
    await Hive.initFlutter();
    await AutomateTaskService.instance.init();

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
      case 'upload':
        log('restored=$restored');
        final target = BucketVersionResolver.writeBucket('documents');
        try {
          await FulaApiService.instance.createBucket(target);
          log('bucket-created $target');
        } catch (e) {
          log('bucket-create tolerated: $e');
        }
        final small = _e2ePattern(100 * 1024, 0);
        final large = _e2ePattern(5 * 1024 * 1024, 7);
        final r1 = await FulaApiService.instance
            .uploadObject(target, '/e2e/p4-small.bin', small);
        log('upload-small-ok etag=${r1.etag.substring(0, 12)}… bytes=${small.length}');
        final etag2 = await FulaApiService.instance.uploadLargeFile(
          target,
          '/e2e/p4-large.bin',
          large,
          onProgress: (p) {},
        );
        log('upload-large-ok etag=${etag2.substring(0, 12)}… bytes=${large.length}');
        break;
      case 'download':
        log('restored=$restored');
        final target = BucketVersionResolver.writeBucket('documents');
        final small = await FulaApiService.instance
            .downloadObject(target, '/e2e/p4-small.bin');
        final large = await FulaApiService.instance
            .downloadObject(target, '/e2e/p4-large.bin');
        log('download-small bytes=${small.length} '
            'equal=${_bytesEqual(small, _e2ePattern(100 * 1024, 0))}');
        log('download-large bytes=${large.length} '
            'equal=${_bytesEqual(large, _e2ePattern(5 * 1024 * 1024, 7))}');
        break;
      case 'list':
        log('restored=$restored');
        final r = await listCategoryMergedCached(
            FulaApiService.instance, 'documents');
        final keys = r.objects.map((o) => o.key).toSet();
        log('list count=${r.objects.length} stale=${r.stale} '
            'hasSmall=${keys.contains('/e2e/p4-small.bin')} '
            'hasLarge=${keys.contains('/e2e/p4-large.bin')}');
        break;
      case 'share':
        log('restored=$restored');
        final target = BucketVersionResolver.writeBucket('documents');
        try {
          await FulaApiService.instance.createBucket(target);
        } catch (_) {}
        final data = _e2ePattern(64 * 1024, 3);
        const key = '/e2e/p8-share.bin';
        final up = await FulaApiService.instance.uploadObject(
            target, key, data);
        log('share-upload-ok etag=${up.etag.substring(0, 12)}…');

        // Mirror the web UI's _share flow exactly.
        final objects =
            await FulaApiService.instance.listObjects(target, prefix: key);
        final obj = objects.firstWhere((o) => o.key == key);
        final storageKey = obj.storageKey ?? obj.key;
        final priv = Uint8List.fromList(
            List<int>.generate(32, (i) => (i * 13 + 5) % 251));
        final pub = Uint8List.fromList(await fula.derivePublicKeyFromSecret(
            secretKeyBytes: priv.toList()));
        final expiresAtUnix = DateTime.now()
                .add(const Duration(days: 7))
                .millisecondsSinceEpoch ~/
            1000;
        final token = await FulaApiService.instance.createShareToken(
          target,
          storageKey,
          pub,
          share_model.ShareMode.temporal,
          expiresAtUnix,
        );
        final url = buildPublicShareUrl(
          baseUrl: kShareGatewayBaseUrl,
          tokenId: 'e2e-share-id',
          fulaToken: token,
          bucket: target,
          pathScope: key,
          storageKey: storageKey,
          linkSecretKey: priv,
          fileName: 'p8-share.bin',
        );
        // Parse back the fragment and assert the v2 payload integrity.
        final frag = Uri.parse(url).fragment;
        final payload =
            jsonDecode(utf8.decode(base64Url.decode(frag))) as Map;
        final skRoundtrip = base64Decode(payload['sk'] as String);
        log('share-url-ok host=${Uri.parse(url).host} len=${url.length} '
            'v=${payload['v']} hasToken=${(payload['t'] as String).isNotEmpty} '
            'bucket=${payload['b']} cid-match=${payload['cid'] == storageKey} '
            'sk-roundtrip=${_bytesEqual(Uint8List.fromList(skRoundtrip), priv)}');
        await FulaApiService.instance.deleteObject(target, key);
        log('share-cleanup-ok');
        break;
      case 'delete':
        log('restored=$restored');
        final target = BucketVersionResolver.writeBucket('documents');
        await FulaApiService.instance
            .deleteObject(target, '/e2e/p4-small.bin');
        await FulaApiService.instance
            .deleteObject(target, '/e2e/p4-large.bin');
        final r = await listCategoryMergedCached(
            FulaApiService.instance, 'documents');
        final keys = r.objects.map((o) => o.key).toSet();
        log('delete-ok absentSmall=${!keys.contains('/e2e/p4-small.bin')} '
            'absentLarge=${!keys.contains('/e2e/p4-large.bin')}');
        break;
      case 'perf-seed':
        // Populate documents-v8 with tiny files so the perf mode can
        // measure how forest-load / list / decrypt SCALE with object
        // count (the empty test vault only gives floor costs). Files
        // stay around — later perf runs and P1 gates reuse them.
        if (_e2eSeed.isEmpty) {
          log('FAIL: perf-seed mode needs seed');
          break;
        }
        await WebSession.instance.signInModeC(seed: _e2eSeed);
        log('signin-ok euid=${WebSession.instance.user?.id}');
        final seedCount = int.tryParse(
                Uri.parse(web.window.location.href).queryParameters['n'] ??
                    '') ??
            150;
        final seedBucket = BucketVersionResolver.writeBucket('documents');
        try {
          await FulaApiService.instance.createBucket(seedBucket);
        } catch (_) {}
        final body = _e2ePattern(4 * 1024, 11);
        var ok = 0;
        final swSeed = Stopwatch()..start();
        for (var i = 0; i < seedCount; i++) {
          try {
            await FulaApiService.instance
                .uploadObject(seedBucket, '/e2e/perf/f$i.bin', body);
            ok++;
          } catch (e) {
            log('seed upload $i failed: ${'$e'.split('\n').first}');
          }
          if ((i + 1) % 25 == 0) {
            log('seeded ${i + 1}/$seedCount '
                '(${swSeed.elapsedMilliseconds ~/ (i + 1)}ms/file)');
          }
        }
        swSeed.stop();
        log('perf-seed-done ok=$ok/$seedCount '
            'totalMs=${swSeed.elapsedMilliseconds}');
        break;
      case 'perf':
        // P0 baseline for docs/web-listing-prefetch-cache-plan.md.
        // Per category: cold open (forest-load + list — the [perf]
        // spans from fula_api_service print the split) vs warm re-list
        // (forest memoized), plus approximate JS-heap growth per cold
        // load. Then each feature manifest load, timed.
        if (_e2eSeed.isEmpty) {
          log('FAIL: perf mode needs seed');
          break;
        }
        await WebSession.instance.signInModeC(seed: _e2eSeed);
        log('signin-ok euid=${WebSession.instance.user?.id}');
        const bases = [
          'images',
          'videos',
          'audio',
          'documents',
          'downloads',
          'archives',
        ];
        for (final base in bases) {
          final bucket = BucketVersionResolver.writeBucket(base);
          final h0 = _jsHeapMB();
          final cold = Stopwatch()..start();
          var count = -1;
          var note = '';
          try {
            final r =
                await FulaApiService.instance.listObjectsCached(bucket);
            count = r.objects.length;
            if (r.stale) note = ' stale';
          } catch (e) {
            note = ' error=${'$e'.split('\n').first}';
          }
          cold.stop();
          final h1 = _jsHeapMB();
          final warm = Stopwatch()..start();
          try {
            await FulaApiService.instance.listObjectsCached(bucket);
          } catch (_) {}
          warm.stop();
          final heap = (h0 != null && h1 != null)
              ? (h1 - h0).toStringAsFixed(1)
              : '?';
          log('cat $base cold=${cold.elapsedMilliseconds}ms '
              'warm=${warm.elapsedMilliseconds}ms n=$count '
              'heapDeltaMB=$heap$note');
        }
        Future<void> feat(String name, Future<void> Function() fn) async {
          final sw = Stopwatch()..start();
          var note = '';
          try {
            await fn();
          } catch (e) {
            note = ' error=${'$e'.split('\n').first}';
          }
          sw.stop();
          log('feat $name ${sw.elapsedMilliseconds}ms$note');
        }

        await feat('tags', () => WebTagService.instance.load(force: true));
        await feat('nfts', () => WebNftService.instance.load(force: true));
        await feat('websites', () => WebFeatures.loadWebsites());
        await feat('shelf', () => WebFeatures.loadShelf());
        await feat('playlists', () => WebFeatures.loadPlaylists());
        break;
      case 'wallet':
        // Regression probe for the AppKit modal: in the broken state
        // (dead context) openModalView() resolved INSTANTLY with no
        // UI; when the modal is actually showing, its future stays
        // pending (it awaits dismissal) and the root navigator gains
        // a poppable route.
        if (_e2eSeed.isNotEmpty) {
          await WebSession.instance.signInModeC(seed: _e2eSeed);
          log('signin-ok euid=${WebSession.instance.user?.id}');
        }
        // Give runApp + the router a frame to mount.
        await Future<void>.delayed(const Duration(seconds: 2));
        final navState = walletNavigatorKey.currentState;
        log('navigator-attached=${navState != null}');
        final ctx = walletNavigatorKey.currentContext;
        if (ctx == null) {
          log('FAIL: walletNavigatorKey has no context');
          break;
        }
        // Harness context: the root-navigator context is app-lifetime,
        // which is exactly what the lint can't see.
        // ignore: use_build_context_synchronously
        await WalletService.instance.initialize(ctx);
        log('wallet-initialized=${WalletService.instance.isInitialized}');
        var connectResolved = false;
        unawaited(WalletService.instance
            // ignore: use_build_context_synchronously
            .connectWallet(ctx)
            .then<bool>((_) => connectResolved = true)
            .catchError((Object e) {
          connectResolved = true;
          log('connect-error: $e');
          return false;
        }));
        await Future<void>.delayed(const Duration(seconds: 4));
        log('modal-open-pending=${!connectResolved} '
            'navigator-canPop=${walletNavigatorKey.currentState?.canPop()}');
        break;
      default:
        log('FAIL: unknown mode');
    }
  } catch (e) {
    log('FAIL: $e');
  }
  log('E2E DONE');
}

/// Approximate JS heap (MB) via Chrome's non-standard
/// `performance.memory.usedJSHeapSize` — null elsewhere. Launched with
/// --enable-precise-memory-info for unquantized values. Wasm linear
/// memory is backed by an ArrayBuffer counted in this number, so the
/// per-category delta approximates the forest's resident cost.
double? _jsHeapMB() {
  try {
    final perf = web.window.performance as JSObject;
    final mem = perf.getProperty('memory'.toJS);
    if (mem.isUndefinedOrNull) return null;
    final used = (mem as JSObject).getProperty('usedJSHeapSize'.toJS);
    if (used.isUndefinedOrNull) return null;
    return (used as JSNumber).toDartDouble / (1024 * 1024);
  } catch (_) {
    return null;
  }
}

/// Deterministic test payload: byte i = (i * 31 + offset) % 251. The
/// download stage regenerates the same pattern for byte-equality.
Uint8List _e2ePattern(int length, int offset) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + offset) % 251;
  }
  return out;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
