// Integration test for Scenario #10 — Cloud bucket browsing.
//
// Lighter than the others because the real-master version is just
// "the request hits master + the parser handles the response". The
// unit-tier version already tests UI rendering with mocked data —
// at integration tier we just confirm the real call works.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fula_files/core/services/fula_api_service.dart';

import '../helpers/test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Integration #10 — Cloud bucket browsing', () {
    late TestHarness harness;

    tearDown(() async {
      await harness.tearDown();
    });

    testWidgets('listBuckets returns a non-empty list against real master',
        (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      final buckets = await FulaApiService.instance.listBuckets();
      harness.logger.step('listBuckets returned ${buckets.length} buckets');
      expect(
        buckets,
        isNotEmpty,
        reason: 'real master should report at least the test bucket '
            '${harness.bucket.bucket}. ${harness.diagnostics()}',
      );
      expect(
        buckets.contains(harness.bucket.bucket),
        isTrue,
        reason: 'integration test bucket should be present in the list. '
            '${harness.diagnostics()}',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('listBucketsCached returns stale=false when master is up',
        (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      final result = await FulaApiService.instance.listBucketsCached();
      harness.logger.step(
        'listBucketsCached: ${result.buckets.length} buckets, stale=${result.stale}',
      );
      expect(
        result.stale,
        isFalse,
        reason: 'master is up — the cached helper must report fresh data. '
            '${harness.diagnostics()}',
      );
      expect(result.fetchedAt, isNotNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets(
        'listBucketsCached falls back to cache when master is offline',
        (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      // Phase 1: warm the on-disk bucket cache via an online call.
      final pre = await FulaApiService.instance.listBucketsCached();
      expect(pre.stale, isFalse);
      harness.logger.step('phase 1: warmed bucket cache (${pre.buckets.length})');

      // Phase 2: flip offline.
      await harness.network.goOffline();
      await tester.pump(const Duration(seconds: 1));

      // Phase 3: cached helper should now return stale=true.
      final off = await FulaApiService.instance.listBucketsCached();
      harness.logger.step(
        'phase 3: listBucketsCached offline returned stale=${off.stale}, '
        'buckets=${off.buckets.length}',
      );
      expect(
        off.stale,
        isTrue,
        reason: 'master unreachable — cached helper must report stale=true. '
            '${harness.diagnostics()}',
      );
      expect(
        off.buckets,
        equals(pre.buckets),
        reason: 'cached listBuckets should match the snapshot taken online. '
            '${harness.diagnostics()}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
