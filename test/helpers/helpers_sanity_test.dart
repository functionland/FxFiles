// Sanity test for the test helpers themselves. If this fails, the
// helpers have a compile or runtime error and EVERY downstream
// scenario test will be misleadingly broken.
//
// Keep this minimal — just enough to prove the helpers wire up.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/providers/fula_api_provider.dart';

import 'fake_fula_api.dart';
import 'fixtures.dart';
import 'test_container.dart';

void main() {
  group('test helpers — sanity', () {
    test('makeTestContainer overrides fulaApiProvider with FakeFulaApi', () {
      final fake = FakeFulaApi();
      final container = makeTestContainer(fulaApi: fake);

      final resolved = container.read(fulaApiProvider);
      expect(resolved, same(fake), reason: 'override must surface the fake');
    });

    test('FakeFulaApi defaults are sensible empty / configured=true', () async {
      final fake = FakeFulaApi();
      expect(fake.isConfigured, isTrue);
      expect(await fake.listBuckets(), isEmpty);
      expect(await fake.listObjects('any'), isEmpty);
    });

    test('FakeFulaApi.listBuckets honours bucketsResponse + counter', () async {
      final fake = FakeFulaApi();
      fake.bucketsResponse = const ['a', 'b'];
      expect(await fake.listBuckets(), ['a', 'b']);
      expect(fake.listBucketsCalls, 1);
    });

    test('FakeFulaApi.listBucketsCached falls back when live throws', () async {
      final fake = FakeFulaApi();
      fake.listBucketsCachedThrowsOnLive = true;
      final stamp = DateTime.utc(2026, 1, 5);
      fake.bucketsCachedFallback = (
        buckets: const ['cached1'],
        stale: true,
        fetchedAt: stamp,
      );
      final result = await fake.listBucketsCached();
      expect(result.buckets, ['cached1']);
      expect(result.stale, isTrue);
      expect(result.fetchedAt, stamp);
    });

    test('FakeFulaApi.deleteObject drops the entry from objectsResponseFor',
        () async {
      final fake = FakeFulaApi();
      fake.objectsResponseFor['images'] = [smallImageObject];
      await fake.deleteObject('images', smallImageObject.key);
      expect(fake.deletedKeys, ['images:${smallImageObject.key}']);
      expect(await fake.listObjects('images'), isEmpty);
    });

    test('FakeFulaApi.uploadObject synthesizes etag when no stub', () async {
      final fake = FakeFulaApi();
      final result = await fake.uploadObject(
        'images',
        'foo.jpg',
        smallUploadPayload,
      );
      expect(result.etag, isNotEmpty);
      expect(result.contentCid, isNotEmpty);
      expect(fake.uploadCalls['images:foo.jpg'], 1);
    });
  });
}
