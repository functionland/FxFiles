// Integration test for Scenario #4 — load-bearing for issue #8.
//
// **This is the test that catches the bug on fula_client 0.5.1.**
//
// Flow (mirrors the user's manual `s3 → s33` reproducer):
//   1. Online: upload a small file to the test bucket.
//   2. Online: list the bucket and assert the file appears (proves
//      the upload completed end to end).
//   3. Mutate the endpoint to a non-resolvable URL (simulates the
//      user opening the app after the master goes unreachable, e.g.
//      via cellular failover or actual outage).
//   4. Offline: list the bucket. MUST still find the file via the
//      SDK's offline-fallback path.
//
// **Why this is load-bearing for issue #8:**
// Pre-fix (v0.5.1), step 4 fails because the SDK's BLOCKS cache
// wasn't warmed during step 1's PUT. Step 2's read warms it for
// the page read, BUT a fresh master GET happens at step 4
// (because the SDK re-fetches the manifest after the endpoint
// changed), and that GET fails DNS → no fallback bytes.
//
// Post-fix (v0.6+), step 1's PUT warms BLOCKS, step 4's offline
// read serves from BLOCKS without going to master at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fula_files/core/services/fula_api_service.dart';

import '../helpers/test_fixture.dart';
import '../helpers/test_harness.dart';
import '../helpers/wait_for.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Integration #4 — online + offline list', () {
    late TestHarness harness;
    late TestFixture fixture;
    late String testKey;

    setUp(() async {
      // The setUp runs inside a testWidgets block; we delegate the
      // tester to bootSignedIn from each test's body so we have a
      // WidgetTester instance.
    });

    tearDown(() async {
      await fixture.dispose();
      await harness.tearDown();
    });

    testWidgets('uploaded file appears in offline list', (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      fixture = await TestFixture.createSmall(
        name: 'scenario4-${DateTime.now().millisecondsSinceEpoch}.bin',
        sizeBytes: 2048,
      );
      testKey = harness.bucket.key(
        'scenario4-${DateTime.now().millisecondsSinceEpoch}.bin',
      );

      final api = FulaApiService.instance;
      harness.logger.step('phase 1: upload ${fixture.bytes.length} bytes to $testKey');

      // Phase 1: online upload
      final etag = await api.uploadLargeFileFromPath(
        harness.bucket.bucket,
        testKey,
        fixture.file.path,
      );
      harness.bucket.trackKey(testKey);
      harness.logger.step('phase 1: upload OK, etag=$etag');
      expect(etag, isNotEmpty, reason: harness.diagnostics());

      // Phase 2: online list (proves the upload landed + the forest
      // reflects it). Also warms the SDK's in-memory forest cache.
      harness.logger.step('phase 2: online list ${harness.bucket.bucket}');
      var onlineFiles = await api.listObjects(harness.bucket.bucket);
      expect(
        onlineFiles.any((f) => f.key == testKey),
        isTrue,
        reason: 'online list must include the just-uploaded file. '
            '${harness.diagnostics()}',
      );
      harness.logger.step(
        'phase 2: online list OK (${onlineFiles.length} files in bucket)',
      );

      // Phase 3: mutate endpoint to non-resolvable
      harness.logger.step('phase 3: flipping to offline endpoint');
      await harness.network.goOffline();

      // Give the SDK a beat to register the endpoint change.
      // The health gate's failure threshold is 2 failures within its
      // TTL — give it enough wall-clock time.
      await tester.pump(const Duration(seconds: 1));

      // Phase 4: offline list — MUST still find the file
      harness.logger.step('phase 4: offline list ${harness.bucket.bucket}');
      List<dynamic> offlineFiles;
      try {
        offlineFiles = await api.listObjects(harness.bucket.bucket);
      } on FulaApiException catch (e) {
        fail(
          'phase 4: offline list THREW — this is the issue #8 bug on '
          'fula_client <0.6. The SDK\'s BLOCKS cache was not warmed by '
          'the upload, so the manifest re-fetch on the new client '
          'instance has nothing to serve when master is unreachable.\n'
          'Error: $e\n'
          '${harness.diagnostics()}',
        );
      }
      expect(
        offlineFiles.any((f) => f.key == testKey),
        isTrue,
        reason: 'offline list must include the just-uploaded file '
            '(issue #8 fix #3 — warm BLOCKS at write time). '
            '${harness.diagnostics()}',
      );
      harness.logger.step(
        'phase 4: offline list OK (${offlineFiles.length} files served '
        'from local cache + fula-client offline path)',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('uploaded file still listed after re-online', (tester) async {
      // Variant: makes sure the online→offline→online round-trip
      // doesn't lose the upload from the listing. Catches a possible
      // regression where the offline path serves stale data that the
      // re-online path doesn't reconcile.
      harness = await TestHarness.bootSignedIn(tester);
      fixture = await TestFixture.createSmall(
        name: 'scenario4b-${DateTime.now().millisecondsSinceEpoch}.bin',
        sizeBytes: 1024,
      );
      testKey = harness.bucket.key(
        'scenario4b-${DateTime.now().millisecondsSinceEpoch}.bin',
      );

      final api = FulaApiService.instance;

      harness.logger.step('phase 1: upload');
      await api.uploadLargeFileFromPath(
        harness.bucket.bucket,
        testKey,
        fixture.file.path,
      );
      harness.bucket.trackKey(testKey);

      harness.logger.step('phase 2: go offline + list');
      await harness.network.goOffline();
      await tester.pump(const Duration(seconds: 1));

      // Note: a try/expect here would mask the same issue #8 bug. We
      // accept either success or the typed exception, and DO NOT
      // re-fail here — only the re-online list below must succeed.
      try {
        await api.listObjects(harness.bucket.bucket);
        harness.logger.step('phase 2: offline list succeeded');
      } catch (e) {
        harness.logger.step('phase 2: offline list failed (expected on v0.5.1): $e');
      }

      harness.logger.step('phase 3: re-online + list');
      await harness.network.goOnline();
      // After re-online the health gate's Down state stays cached
      // for its TTL (~30s by default). Force a probe through by
      // waiting until a fresh listObjects succeeds.
      await waitForAsync(
        () async {
          try {
            await api.listObjects(harness.bucket.bucket);
            return true;
          } catch (_) {
            return false;
          }
        },
        timeout: const Duration(seconds: 60),
        pollInterval: const Duration(seconds: 2),
        message: 're-online list never succeeded after goOnline()',
      );

      final reonlineFiles = await api.listObjects(harness.bucket.bucket);
      expect(
        reonlineFiles.any((f) => f.key == testKey),
        isTrue,
        reason: 're-online list must still include the file. '
            '${harness.diagnostics()}',
      );
      harness.logger.step('phase 3: re-online list OK');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
