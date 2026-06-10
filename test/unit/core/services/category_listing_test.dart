// Unit tests for the merged category listing (Phase 2a). Device-free.
//
// Run: flutter test test/unit/core/services/category_listing_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/category_listing.dart';
import 'package:fula_files/core/services/fula_api.dart';

import '../../../helpers/fake_fula_api.dart';

FulaObject obj(String key, {int size = 1, String? etag}) =>
    FulaObject(key: key, size: size, etag: etag);

void main() {
  setUp(() => BucketVersionResolver.enabled = false);
  tearDown(() => BucketVersionResolver.enabled = false);

  group('single-bucket (disabled / unmanaged)', () {
    test('disabled: reads only the base bucket, tags sourceBucket, '
        'never queries v8', () async {
      final fake = FakeFulaApi();
      fake.objectsResponseFor['images'] = [obj('a.jpg'), obj('b.jpg')];
      fake.objectsResponseFor['images-v8'] = [obj('new.jpg')]; // must be ignored

      final r = await listCategoryMerged(fake, 'images');

      expect(r.map((o) => o.key), unorderedEquals(<String>['a.jpg', 'b.jpg']));
      expect(r.every((o) => o.sourceBucket == 'images'), isTrue);
      expect(fake.listObjectsCalls['images-v8'], isNull,
          reason: 'v8 must not be queried while disabled');
    });

    test('enabled but unmanaged bucket → single bucket', () async {
      BucketVersionResolver.enabled = true;
      final fake = FakeFulaApi();
      fake.objectsResponseFor['dump'] = [obj('x')];
      final r = await listCategoryMerged(fake, 'dump');
      expect(r.single.sourceBucket, 'dump');
    });
  });

  group('enabled, managed (merge)', () {
    setUp(() => BucketVersionResolver.enabled = true);

    test('merges legacy + v8, each tagged with its real bucket', () async {
      final fake = FakeFulaApi();
      fake.objectsResponseFor['images'] = [obj('old1.jpg'), obj('old2.jpg')];
      fake.objectsResponseFor['images-v8'] = [obj('new1.jpg')];

      final r = await listCategoryMerged(fake, 'images');

      expect(r.map((o) => o.key),
          unorderedEquals(<String>['old1.jpg', 'old2.jpg', 'new1.jpg']));
      final srcByKey = {for (final o in r) o.key: o.sourceBucket};
      expect(srcByKey['old1.jpg'], 'images');
      expect(srcByKey['new1.jpg'], 'images-v8');
    });

    test('duplicate key resolves to v8 (prefer-v8)', () async {
      final fake = FakeFulaApi();
      fake.objectsResponseFor['images'] = [obj('dup.jpg', etag: 'legacy-etag')];
      fake.objectsResponseFor['images-v8'] = [obj('dup.jpg', etag: 'v8-etag')];

      final r = await listCategoryMerged(fake, 'images');

      expect(r.length, 1);
      expect(r.single.sourceBucket, 'images-v8');
      expect(r.single.etag, 'v8-etag');
    });

    test('empty v8 bucket → just legacy (common pre-upload case)', () async {
      final fake = FakeFulaApi();
      fake.objectsResponseFor['images'] = [obj('only-old.jpg')];
      // images-v8 unset → fake returns empty
      final r = await listCategoryMerged(fake, 'images');
      expect(r.single.key, 'only-old.jpg');
      expect(r.single.sourceBucket, 'images');
    });

    test('v8 error is TOLERATED (treated empty); legacy still shows', () async {
      final fake = FakeFulaApi();
      fake.objectsResponseFor['images'] = [obj('old.jpg')];
      fake.listObjectsErrorFor['images-v8'] = FulaApiException('v8 not created');
      final r = await listCategoryMerged(fake, 'images');
      expect(r.single.key, 'old.jpg');
    });

    test('legacy error PROPAGATES (legacy is the source of truth)', () async {
      final fake = FakeFulaApi();
      fake.listObjectsErrorFor['images'] = FulaApiException('master down');
      await expectLater(
        listCategoryMerged(fake, 'images'),
        throwsA(isA<FulaApiException>()),
      );
    });
  });
}
