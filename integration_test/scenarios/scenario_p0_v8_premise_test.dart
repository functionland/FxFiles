// Phase 0 — v8 fresh-bucket premise + durability probe.
//
// Proves the load-bearing premise of the v8 bucket migration
// (docs/v8-bucket-migration-plan.md): a FRESHLY-created bucket has an
// empty forest, so the read-modify-write that is BLOCKED on gc-damaged
// legacy buckets succeeds — i.e. uploads to a fresh bucket work
// end-to-end (create -> upload -> list -> download -> byte-match) on the
// REAL production master.
//
// The companion DURABILITY check (are the SDK-written client-forest
// `__fula_forest_v7_nodes/` blocks actually pinned, so v8 can't re-rot
// on the next `ipfs repo gc`) is confirmed SERVER-SIDE after this test
// runs: locate this run's forest-node pins for the probe bucket in the
// gateway log (`v8-node:e2e-v8-probe`) and confirm they're in the
// cluster pinset. This test logs the bucket + key + etag so that
// server-side step can find them (see the DURABILITY-PROBE log line).
//
// PREREQUISITE: a device signed into FxFiles (see test_harness.dart).
// For Phases 0-3 this is your real account; the probe writes ONLY to a
// dedicated `e2e-v8-probe` bucket under `__e2e/<run>/` keys and
// cleans up its keys, so it never touches your real category buckets.

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fula_files/core/services/fula_api_service.dart';

import '../helpers/test_fixture.dart';
import '../helpers/test_harness.dart';

/// Dedicated, clearly-named probe bucket. Created fresh on first run
/// (which is itself the premise proof: a brand-new bucket accepts an
/// upload), reused thereafter. Never a real category bucket.
const String kProbeBucket = 'e2e-v8-probe';

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 0 — v8 fresh-bucket premise + durability probe', () {
    late TestHarness harness;
    final List<TestFixture> fixtures = <TestFixture>[];
    final List<String> createdKeys = <String>[];
    final String runStamp = DateTime.now().millisecondsSinceEpoch.toString();

    tearDown(() async {
      // Clean up only the probe keys this run created — never a bucket,
      // never legacy content. (Deletes on the healthy probe bucket are
      // fine; the HARD INVARIANT only forbids deleting LEGACY objects.)
      final api = FulaApiService.instance;
      for (final k in createdKeys) {
        try {
          await api.deleteObject(kProbeBucket, k);
        } catch (_) {
          // best-effort
        }
      }
      createdKeys.clear();
      for (final f in fixtures) {
        await f.dispose();
      }
      fixtures.clear();
      await harness.tearDown();
    });

    Future<void> roundTrip(TestFixture fix, String label) async {
      final api = FulaApiService.instance;

      // (1) Fresh bucket: create if absent. The first run proves a
      //     brand-new bucket accepts writes (the whole premise).
      if (!await api.bucketExists(kProbeBucket)) {
        harness.logger.step('creating fresh probe bucket "$kProbeBucket"');
        await api.createBucket(kProbeBucket);
      }
      expect(
        await api.bucketExists(kProbeBucket),
        isTrue,
        reason: 'probe bucket must exist after create. ${harness.diagnostics()}',
      );

      final key = '__e2e/$runStamp/$label';

      // (2) Upload through the real forest path (the op that is BLOCKED
      //     on gc-damaged legacy buckets).
      final etag =
          await api.uploadLargeFileFromPath(kProbeBucket, key, fix.file.path);
      createdKeys.add(key);
      expect(
        etag,
        isNotEmpty,
        reason:
            'upload must succeed on a fresh bucket. ${harness.diagnostics()}',
      );
      // Logged for the SERVER-SIDE durability check (forest-node pinning):
      harness.logger.step(
        'DURABILITY-PROBE bucket=$kProbeBucket key=$key etag=$etag '
        'sha256(local)=${_sha256Hex(fix.bytes)}',
      );

      // (3) List: the object appears in the fresh forest.
      final files = await api.listObjects(kProbeBucket);
      expect(
        files.any((f) => f.key == key),
        isTrue,
        reason: 'uploaded object must appear in the fresh bucket listing. '
            '${harness.diagnostics()}',
      );

      // (4) Download + BYTE-MATCH — the core round-trip integrity assertion.
      final got = await api.downloadObject(kProbeBucket, key);
      expect(
        got.length,
        fix.bytes.length,
        reason: 'downloaded size must match the upload. '
            '${harness.diagnostics()}',
      );
      expect(
        _sha256Hex(got),
        _sha256Hex(fix.bytes),
        reason: 'downloaded bytes must byte-match the upload. '
            '${harness.diagnostics()}',
      );
      harness.logger.step('round-trip OK ($label): byte-match confirmed');
    }

    testWidgets('small file round-trips on a fresh v8 bucket', (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      final fix = await TestFixture.createSmall(
        name: 'p0-small-$runStamp.bin',
        sizeBytes: 4096,
      );
      fixtures.add(fix);
      await roundTrip(
          fix, 'small-${DateTime.now().millisecondsSinceEpoch}.bin');
    }, timeout: const Timeout(Duration(minutes: 4)));

    testWidgets('chunked file round-trips on a fresh v8 bucket',
        (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      final fix = await TestFixture.createLarge(
        name: 'p0-large-$runStamp.bin',
        sizeBytes: 1024 * 1024, // ~1 MB — crosses the chunked threshold
      );
      fixtures.add(fix);
      await roundTrip(
          fix, 'large-${DateTime.now().millisecondsSinceEpoch}.bin');
    }, timeout: const Timeout(Duration(minutes: 6)));
  });
}
