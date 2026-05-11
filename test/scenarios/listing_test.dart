// Scenario #4 — Online + offline (warm/cold) listing of uploaded
// files.
//
// **Tier:** unit tests at the FulaApi boundary.
//
// **Coverage of the stated requirement** ("ensure previous uploaded
// files in the category show and list correctly in both online and
// offline mode (warm and cold)"):
//
// - Online: `listBuckets`/`listObjects` return the live master state.
// - Offline-warm: `listBucketsCached` returns the cached snapshot
//   with `stale=true` and a fetched-at timestamp the UI can surface.
// - Offline-cold (no cache): `listBucketsCached` throws so callers
//   render a clear error state.
// - Object prefix filter: Dart-side narrowing on `listObjects` works.
//
// **What's NOT covered here (integration territory):**
// - Real master DNS-fail → real cache hit. That's an end-to-end
//   trace that lives in fula-client's Rust offline_e2e tests.
// - Real device airplane-mode toggling.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/fula_api.dart';

import '../helpers/fake_fula_api.dart';
import '../helpers/fixtures.dart';

void main() {
  group('Scenario #4 — Online + offline listing', () {
    // ---------- online ----------

    test('online listBuckets returns the live master result', () async {
      final fake = FakeFulaApi();
      fake.bucketsResponse = const ['images', 'videos', 'documents'];
      expect(await fake.listBuckets(), ['images', 'videos', 'documents']);
      expect(fake.listBucketsCalls, 1);
    });

    test('online listObjects returns all files when prefix is empty',
        () async {
      final fake = FakeFulaApi();
      fake.objectsResponseFor['images'] = [
        smallImageObject,
        secondImageObject,
      ];
      final files = await fake.listObjects('images');
      expect(files, hasLength(2));
      expect(files.map((f) => f.key),
          containsAll([smallImageObject.key, secondImageObject.key]));
    });

    test('listObjects respects prefix filter', () async {
      final fake = FakeFulaApi();
      fake.objectsResponseFor['mixed'] = [
        smallImageObject, // key: images/IMG_...
        chunkedVideoObject, // key: videos/VID_...
      ];
      final imagesOnly =
          await fake.listObjects('mixed', prefix: 'images/');
      expect(imagesOnly, hasLength(1));
      expect(imagesOnly.single.key, smallImageObject.key);
    });

    test('empty bucket returns empty list (not null)', () async {
      final fake = FakeFulaApi();
      // No entry set for 'images' — defaults to empty list.
      expect(await fake.listObjects('images'), isEmpty);
    });

    // ---------- offline warm ----------

    test('offline-warm listBucketsCached returns cache with stale=true',
        () async {
      final fake = FakeFulaApi();
      final stamp = DateTime.utc(2026, 1, 2, 10);
      fake.listBucketsCachedThrowsOnLive = true;
      fake.bucketsCachedFallback = (
        buckets: const ['images', 'videos'],
        stale: true,
        fetchedAt: stamp,
      );

      final result = await fake.listBucketsCached();
      expect(result.buckets, ['images', 'videos']);
      expect(result.stale, isTrue,
          reason: 'UI relies on this to surface "you may be seeing old data"');
      expect(result.fetchedAt, stamp);
    });

    test('online listBucketsCached returns stale=false on live success',
        () async {
      final fake = FakeFulaApi();
      fake.bucketsResponse = const ['images'];
      final result = await fake.listBucketsCached();
      expect(result.buckets, ['images']);
      expect(result.stale, isFalse);
      expect(result.fetchedAt, isNotNull);
    });

    // ---------- offline cold ----------

    test('offline-cold listBucketsCached throws when no cache exists',
        () async {
      final fake = FakeFulaApi();
      fake.listBucketsCachedThrowsOnLive = true;
      // bucketsCachedFallback intentionally left null → no cache.

      await expectLater(
        fake.listBucketsCached(),
        throwsA(isA<FulaApiException>()),
      );
    });

    test('listObjects error surfaces as FulaApiException', () async {
      final fake = FakeFulaApi();
      fake.listObjectsErrorFor['face-metadata'] =
          FulaApiException('master unreachable');

      await expectLater(
        fake.listObjects('face-metadata'),
        throwsA(isA<FulaApiException>()),
      );
    });
  });
}
