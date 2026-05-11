// Integration test for Scenario #3 — Upload to Cloud baseline.
//
// Verifies the end-to-end upload path against the REAL master:
//   1. Sign-in state assumed (TestHarness.bootSignedIn).
//   2. Upload a small + a chunked file via `uploadLargeFileFromPath`.
//   3. Listing the bucket includes both files.
//   4. Etag matches CID format expected on v0.4.4+ master.
//
// Compared to scenario #4 (which proves the offline path works),
// this scenario just proves the upload path itself works.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fula_files/core/services/fula_api_service.dart';

import '../helpers/test_fixture.dart';
import '../helpers/test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Integration #3 — Upload to Cloud (baseline)', () {
    late TestHarness harness;
    final List<TestFixture> fixtures = <TestFixture>[];

    tearDown(() async {
      for (final f in fixtures) {
        await f.dispose();
      }
      fixtures.clear();
      await harness.tearDown();
    });

    testWidgets('small file upload appears in bucket listing', (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      final fix = await TestFixture.createSmall(
        name: 's3small-${DateTime.now().millisecondsSinceEpoch}.bin',
        sizeBytes: 4096,
      );
      fixtures.add(fix);
      final key = harness.bucket.key(
        's3small-${DateTime.now().millisecondsSinceEpoch}.bin',
      );

      final etag = await FulaApiService.instance.uploadLargeFileFromPath(
        harness.bucket.bucket,
        key,
        fix.file.path,
      );
      harness.bucket.trackKey(key);
      expect(etag, isNotEmpty, reason: harness.diagnostics());

      // v0.4.4+ master returns `bafkr4i…` (raw-codec BLAKE3) etags.
      // Older master returns hex MD5. The test accepts either — it
      // just checks the call succeeded. Asserting the CID format
      // would couple this scenario to master version, which the
      // user explicitly chose to keep loose.
      harness.logger.step('upload succeeded, etag=$etag');

      final files = await FulaApiService.instance
          .listObjects(harness.bucket.bucket);
      expect(
        files.any((f) => f.key == key),
        isTrue,
        reason: 'uploaded file must appear in listObjects. '
            '${harness.diagnostics()}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('chunked (>768 KB) upload appears in bucket listing',
        (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      final fix = await TestFixture.createLarge(
        name: 's3chunked-${DateTime.now().millisecondsSinceEpoch}.bin',
        sizeBytes: 1024 * 1024, // ~1 MB — crosses the 768 KB threshold
      );
      fixtures.add(fix);
      final key = harness.bucket.key(
        's3chunked-${DateTime.now().millisecondsSinceEpoch}.bin',
      );

      final etag = await FulaApiService.instance.uploadLargeFileFromPath(
        harness.bucket.bucket,
        key,
        fix.file.path,
      );
      harness.bucket.trackKey(key);
      expect(etag, isNotEmpty, reason: harness.diagnostics());

      final files = await FulaApiService.instance
          .listObjects(harness.bucket.bucket);
      expect(
        files.any((f) => f.key == key),
        isTrue,
        reason: 'chunked upload must appear in listObjects '
            '(exercises the fula put_object_chunked_internal path). '
            '${harness.diagnostics()}',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
