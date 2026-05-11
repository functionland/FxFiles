// Integration test harness.
//
// **Prerequisite:** the user must sign in on the device ONCE before
// running these tests. The harness reads the persisted session from
// `SecureStorage` and waits for `FulaApiService` to become configured.
// If you've never signed in (or `pm clear`'d the app), the harness
// fails fast with a clear message.
//
// **Usage:**
// ```dart
// late TestHarness harness;
// setUp(() async {
//   harness = await TestHarness.bootSignedIn(tester);
// });
// tearDown(() async {
//   await harness.tearDown();
// });
// ```
//
// The harness composes the bucket + network + logger helpers so
// scenarios don't have to re-construct them.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fula_client/fula_client.dart' show RustLib;

import 'package:fula_files/app/app.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

import 'failure_logger.dart';
import 'network_mutator.dart';
import 'test_bucket.dart';
import 'wait_for.dart';

class TestHarness {
  final WidgetTester tester;
  final TestBucket bucket = TestBucket();
  final NetworkMutator network = NetworkMutator();
  final FailureLogger logger = FailureLogger();

  TestHarness._(this.tester);

  /// Boot a fresh test app session and wait for sign-in state to
  /// restore. **`flutter test integration_test/` does NOT run
  /// `lib/main.dart`** — it hijacks `main()` and pumps the widget
  /// tree directly. That means the pre-`runApp` initialization in
  /// production main.dart (RustLib, SecureStorage, LocalStorage,
  /// `AuthService.checkExistingSession()`) is skipped. We
  /// re-invoke just enough of it here to make `AuthService` find
  /// the user's persisted session on disk.
  ///
  /// **Prerequisite:** the device must have FxFiles signed in via
  /// the SAME `applicationId` as the debug-build APK that `flutter
  /// test integration_test/` installs. In practice that means: run
  /// the test once (it installs the debug APK), sign in manually
  /// inside the debug build (one-time), then subsequent test runs
  /// pick up that session.
  ///
  /// If the user is NOT signed in on the device, this fails fast at
  /// the `AuthService.isAuthenticated` poll with a descriptive error.
  static Future<TestHarness> bootSignedIn(WidgetTester tester) async {
    final harness = TestHarness._(tester);
    harness.logger.reset();
    harness.logger.step('bootSignedIn: pumping FulaFilesApp');

    await tester.pumpWidget(const ProviderScope(child: FulaFilesApp()));

    // Pumping settle on a fresh launch can hang because of
    // long-running streams (sync service, watchers). Just give it
    // enough frames for first paint then move to polling.
    harness.logger.step('bootSignedIn: pumping 5 frames for first paint');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // ----- Re-run the pre-runApp init that integration_test skipped.
    // Each step mirrors lib/main.dart's _initializeApp(). We catch
    // and log per step so a single sub-init failure doesn't blow
    // up the whole harness — the production app also runs each
    // under a `try/catch` for the same reason.

    harness.logger.step('bootSignedIn: initializing RustLib');
    try {
      // RustLib.init() is idempotent — a no-op if already loaded.
      // The smoke-test path may have already loaded it; this just
      // ensures it's loaded before AuthService starts FRB calls.
      await RustLib.init().timeout(const Duration(seconds: 30));
    } catch (e) {
      harness.logger.step('bootSignedIn: RustLib init failed: $e (continuing)');
    }
    AuthService.markRustLibInitialized();

    harness.logger.step('bootSignedIn: initializing SecureStorage');
    try {
      await SecureStorageService.instance
          .init()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      harness.logger.step(
        'bootSignedIn: SecureStorage init failed: $e (continuing)',
      );
    }

    harness.logger.step('bootSignedIn: initializing LocalStorage');
    try {
      await LocalStorageService.instance
          .init()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      harness.logger.step(
        'bootSignedIn: LocalStorage init failed: $e (continuing)',
      );
    }

    harness.logger.step('bootSignedIn: calling AuthService.checkExistingSession');
    try {
      await AuthService.instance.checkExistingSession().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          harness.logger.step(
            'bootSignedIn: checkExistingSession timed out — '
            'persisted session may be missing or corrupted',
          );
          return false;
        },
      );
    } catch (e) {
      harness.logger.step('bootSignedIn: checkExistingSession threw: $e');
    }

    // Step 1: wait for AuthService to restore the persisted session.
    harness.logger.step('bootSignedIn: waiting for AuthService.isAuthenticated');
    await waitFor(
      () => AuthService.instance.isAuthenticated,
      timeout: const Duration(seconds: 30),
      message:
          'AuthService never became authenticated. The test runner '
          'must have a signed-in FxFiles session on the device. '
          'Steps to set up: '
          '(1) `flutter run -d <device>` once to launch the debug build, '
          '(2) tap through the ToS and sign in via the OAuth flow, '
          '(3) then run `flutter test integration_test/`. '
          'Subsequent runs re-use the saved session. '
          'See test/README.md "Tier-1A auth assumption".',
    );
    harness.logger.step(
      'bootSignedIn: authenticated as ${AuthService.instance.currentUser?.email}',
    );

    // Step 2: explicitly kick off FulaApiService initialization via
    // AuthService.reinitializeFulaClient. The production flow runs
    // this from `checkExistingSession()` on success; we call it
    // explicitly so the timeout below is a real bound on SDK init,
    // not a wait for some indirect chain to fire.
    harness.logger.step('bootSignedIn: calling reinitializeFulaClient');
    try {
      await AuthService.instance
          .reinitializeFulaClient()
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      harness.logger.step(
        'bootSignedIn: reinitializeFulaClient failed: $e (continuing — '
        'isConfigured poll will surface the real error)',
      );
    }

    // Step 3: wait for FulaApiService to finish initializing.
    // SDK init can take 30+ seconds on a real device (RustLib load,
    // network round-trips, walkable-v8 startup). 90s is the user's
    // observed worst case for a healthy master.
    harness.logger.step('bootSignedIn: waiting for FulaApiService.isConfigured');
    await waitFor(
      () => FulaApiService.instance.isConfigured,
      timeout: const Duration(seconds: 90),
      pollInterval: const Duration(milliseconds: 500),
      message:
          'FulaApiService never became configured within 90s. '
          'AuthService reported signed-in but the SDK init never '
          'completed. Causes worth checking: '
          '(a) device offline — first init needs the master reachable; '
          '(b) RustLib failed to load (look for "RustLib initialization '
          'failed" in device logs); '
          '(c) stale credentials — try `flutter run -d <device>` and '
          're-sign-in. ',
    );
    harness.logger.step('bootSignedIn: FulaApiService.isConfigured = true');

    // Step 3: snapshot the current endpoint so we can restore later.
    final endpoint = await _readCurrentEndpoint();
    harness.network.snapshotCurrent(currentEndpoint: endpoint);

    // Step 4: ensure the test bucket exists.
    await harness.bucket.ensureBucketExists();

    harness.logger.step('bootSignedIn: ready');
    return harness;
  }

  /// Best-effort cleanup. Always restores the online endpoint so the
  /// next test doesn't inherit a bogus URL, then deletes per-test
  /// keys.
  Future<void> tearDown() async {
    logger.step('tearDown: restoring online endpoint');
    try {
      await network.goOnline();
    } catch (e) {
      logger.step('tearDown: goOnline failed: $e (continuing)');
    }
    logger.step('tearDown: cleaning up per-test keys');
    try {
      await bucket.cleanup();
    } catch (e) {
      logger.step('tearDown: bucket.cleanup failed: $e (continuing)');
    }
    logger.step('tearDown: done');
  }

  /// Dump the failure logger's breadcrumbs as a single string. Pass
  /// to `expect(..., reason: harness.diagnostics())` so a failure
  /// shows the full test history.
  String diagnostics() => 'Test diagnostics:\n${logger.dump()}';

  // -------- internals --------

  /// Reads the currently-configured endpoint by interrogating
  /// AuthService's stored configuration. The exact method differs
  /// across FxFiles versions; this implementation defaults to
  /// `https://s3.cloud.fx.land` if the endpoint can't be read,
  /// because that's the production default.
  static Future<String> _readCurrentEndpoint() async {
    // FxFiles stores the endpoint via SecureStorageService. We can't
    // call its private fields directly, so we trust the production
    // default. If a future FxFiles version makes this user-configurable,
    // wire a getter on AuthService and read it here.
    return 'https://s3.cloud.fx.land';
  }
}
