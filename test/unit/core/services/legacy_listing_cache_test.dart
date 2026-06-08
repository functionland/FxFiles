// Unit tests for the legacy-listing cache + cache-backed merge (Phase 3).
// Device-free; the cache is used in-memory (no Hive).
//
// Run: flutter test test/unit/core/services/legacy_listing_cache_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/category_listing.dart';
import 'package:fula_files/core/services/fula_api.dart';
import 'package:fula_files/core/services/legacy_listing_cache.dart';

import '../../../helpers/fake_fula_api.dart';

FulaObject obj(String key, {int size = 1, String? etag}) =>
    FulaObject(key: key, size: size, etag: etag);

const String _uid = 'user-1';

void main() {
  setUp(() => BucketVersionResolver.enabled = true);
  tearDown(() => BucketVersionResolver.enabled = false);

  group('FulaObject JSON round-trip (cache serialization)', () {
    test('every field incl. sourceBucket survives', () {
      final o = FulaObject(
        key: 'photos/a.jpg',
        size: 4096,
        lastModified: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        etag: 'bafkr4i…',
        metadata: const {'storageKey': 'sk', 'contentType': 'image/jpeg'},
        sourceBucket: 'images-v8',
      ).withSourceBucket('images-v8');
      final back = FulaObject.fromJson(o.toJson());
      expect(back.key, o.key);
      expect(back.size, o.size);
      expect(back.lastModified, o.lastModified);
      expect(back.etag, o.etag);
      expect(back.metadata, o.metadata);
      expect(back.sourceBucket, 'images-v8');
    });
  });

  group('LegacyListingCache (in-memory)', () {
    test('getFrozen is null until freeze, then returns the list', () async {
      final c = LegacyListingCache.forTest();
      expect(c.getFrozen(_uid, 'images'), isNull);
      await c.freeze(_uid, 'images', [obj('a.jpg')]);
      expect(c.getFrozen(_uid, 'images')!.single.key, 'a.jpg');
    });

    test('frozen-EMPTY is distinct from never-frozen (empty != null)', () async {
      final c = LegacyListingCache.forTest();
      await c.freeze(_uid, 'videos', const <FulaObject>[]);
      expect(c.getFrozen(_uid, 'videos'), isNotNull);
      expect(c.getFrozen(_uid, 'videos'), isEmpty);
    });

    test('clear drops the frozen entry (manual refresh)', () async {
      final c = LegacyListingCache.forTest();
      await c.freeze(_uid, 'images', [obj('a.jpg')]);
      await c.clear(_uid, 'images');
      expect(c.getFrozen(_uid, 'images'), isNull);
    });

    test('keys are per-user', () async {
      final c = LegacyListingCache.forTest();
      await c.freeze('user-A', 'images', [obj('a.jpg')]);
      expect(c.getFrozen('user-B', 'images'), isNull);
    });
  });

  group('listCategoryCached', () {
    test('first open loads legacy+v8 and FREEZES legacy; '
        'second open skips legacy, re-queries v8', () async {
      final fake = FakeFulaApi();
      final c = LegacyListingCache.forTest();
      fake.objectsResponseFor['images'] = [obj('old.jpg')];
      fake.objectsResponseFor['images-v8'] = [obj('new.jpg')];

      final r1 = await listCategoryCached(fake, c, _uid, 'images');
      expect(r1.objects.map((o) => o.key),
          unorderedEquals(<String>['old.jpg', 'new.jpg']));
      expect(c.getFrozen(_uid, 'images')!.single.key, 'old.jpg');
      expect(fake.listObjectsCalls['images'], 1);

      final r2 = await listCategoryCached(fake, c, _uid, 'images');
      expect(r2.objects.map((o) => o.key),
          unorderedEquals(<String>['old.jpg', 'new.jpg']));
      expect(fake.listObjectsCalls['images'], 1,
          reason: 'legacy frozen — not re-queried');
      expect(fake.listObjectsCalls['images-v8'], 2,
          reason: 'v8 is live — re-queried each open');
    });

    test('duplicate key prefers v8', () async {
      final fake = FakeFulaApi();
      final c = LegacyListingCache.forTest();
      fake.objectsResponseFor['images'] = [obj('dup.jpg', etag: 'L')];
      fake.objectsResponseFor['images-v8'] = [obj('dup.jpg', etag: 'V')];
      final r = await listCategoryCached(fake, c, _uid, 'images');
      expect(r.objects.single.etag, 'V');
      expect(r.objects.single.sourceBucket, 'images-v8');
    });

    test('STALE legacy load is NOT frozen (may be incomplete)', () async {
      final fake = FakeFulaApi();
      final c = LegacyListingCache.forTest();
      fake.objectsCachedResponseFor['images'] =
          (objects: [obj('old.jpg')], stale: true, fetchedAt: null);
      final r = await listCategoryCached(fake, c, _uid, 'images');
      expect(r.objects.single.key, 'old.jpg');
      expect(r.stale, isTrue);
      expect(c.getFrozen(_uid, 'images'), isNull,
          reason: 'stale must not freeze');
    });

    test('new user / legacy error → treated empty, no break; v8 shows', () async {
      final fake = FakeFulaApi();
      final c = LegacyListingCache.forTest();
      fake.listObjectsErrorFor['images'] = FulaApiException('no legacy bucket');
      fake.objectsResponseFor['images-v8'] = [obj('new.jpg')];
      final r = await listCategoryCached(fake, c, _uid, 'images');
      expect(r.objects.single.key, 'new.jpg');
      expect(c.getFrozen(_uid, 'images'), isNull,
          reason: 'failed load must not freeze');
    });

    test('fresh-EMPTY legacy is frozen (new user pays no repeat timeout)',
        () async {
      final fake = FakeFulaApi();
      final c = LegacyListingCache.forTest();
      // 'images' unset → fake returns empty + stale=false (fresh)
      fake.objectsResponseFor['images-v8'] = [obj('new.jpg')];
      final r1 = await listCategoryCached(fake, c, _uid, 'images');
      expect(r1.objects.single.key, 'new.jpg');
      expect(c.getFrozen(_uid, 'images'), isEmpty,
          reason: 'fresh-empty is frozen');
      final legacyCalls = fake.listObjectsCalls['images'];
      await listCategoryCached(fake, c, _uid, 'images');
      expect(fake.listObjectsCalls['images'], legacyCalls,
          reason: 'frozen-empty legacy not re-queried');
    });

    test('disabled → single bucket, no caching', () async {
      BucketVersionResolver.enabled = false;
      final fake = FakeFulaApi();
      final c = LegacyListingCache.forTest();
      fake.objectsResponseFor['images'] = [obj('a.jpg')];
      final r = await listCategoryCached(fake, c, _uid, 'images');
      expect(r.objects.single.sourceBucket, 'images');
      expect(c.getFrozen(_uid, 'images'), isNull);
    });
  });
}
