// Integration test for Scenario #6 — Download after delete (warm
// offline path).
//
// Verifies that a file uploaded online can be downloaded back even
// after the device's local copy is gone and the master is reachable
// only via the SDK's warm cache + gateway race.
//
// **What "warm offline" means here:** between upload and the
// offline download, we list the file at least once while online so
// the SDK's BLOCKS cache gets populated. Cold-start (no warm cache
// at all) is a separate scenario that needs a full app reinstall —
// not feasible from `flutter test integration_test/` and lives at
// the SDK tier in `crates/fula-client/tests/offline_e2e.rs`.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fula_files/core/services/fula_api_service.dart';

import '../helpers/test_fixture.dart';
import '../helpers/test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Integration #6 — Download after delete (warm offline)', () {
    late TestHarness harness;
    late TestFixture fixture;
    late String testKey;

    tearDown(() async {
      await fixture.dispose();
      await harness.tearDown();
    });

    testWidgets(
        'upload → list (warms cache) → go offline → download returns bytes',
        (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      fixture = await TestFixture.createSmall(
        name: 's6-${DateTime.now().millisecondsSinceEpoch}.bin',
        sizeBytes: 8192,
      );
      testKey = harness.bucket.key(
        's6-${DateTime.now().millisecondsSinceEpoch}.bin',
      );

      final api = FulaApiService.instance;

      // Phase 1: upload while online.
      harness.logger.step('phase 1: upload ${fixture.bytes.length} bytes');
      final etag = await api.uploadLargeFileFromPath(
        harness.bucket.bucket,
        testKey,
        fixture.file.path,
      );
      harness.bucket.trackKey(testKey);
      expect(etag, isNotEmpty);

      // Phase 2: online list — required to warm the BLOCKS cache
      // BEFORE going offline, because v0.5.1 doesn't warm on write.
      // Post-issue-#8 SDKs would warm via PUT alone, but this test
      // is robust across both versions by warming via READ too.
      harness.logger.step('phase 2: online list to warm cache');
      final onlineFiles = await api.listObjects(harness.bucket.bucket);
      expect(onlineFiles.any((f) => f.key == testKey), isTrue);

      // Phase 3: simulate offline.
      harness.logger.step('phase 3: flipping to offline');
      await harness.network.goOffline();
      await tester.pump(const Duration(seconds: 1));

      // Phase 4: download via the offline path. Must return bytes
      // that byte-match the original payload (proves the download
      // path's integrity verification didn't drop or corrupt).
      harness.logger.step('phase 4: offline download');
      final downloaded = await api.downloadObject(
        harness.bucket.bucket,
        testKey,
      );
      expect(
        downloaded.length,
        fixture.bytes.length,
        reason: 'offline download length mismatch. '
            '${harness.diagnostics()}',
      );
      // Byte-by-byte equality. Use `equals(...)` instead of
      // `containsAll` so a single bit-flip fails loudly.
      expect(
        downloaded,
        equals(fixture.bytes),
        reason: 'offline download must byte-match the uploaded payload. '
            '${harness.diagnostics()}',
      );
      harness.logger.step('phase 4: offline download OK (bytes verified)');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
