// Unit tests for the v8 bucket-version resolver (Phase 1).
//
// Device-free + deterministic: no SDK, no login, no gateway. Run with
// `flutter test test/unit/core/services/bucket_version_resolver_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';

void main() {
  // `enabled` is global mutable state — reset around every test so ordering
  // can never leak the flag between tests.
  setUp(() => BucketVersionResolver.enabled = false);
  tearDown(() => BucketVersionResolver.enabled = false);

  group('disabled (default — production-safe until Phase 2)', () {
    test('writeBucket is a pure passthrough for every bucket', () {
      for (final b in <String>[
        'images', 'videos', 'audio', 'documents', // managed bases
        'dump', 'dump-thumbs', 'tag-metadata', 'integration-test', // unmanaged
        'images-v8', // already-v8
      ]) {
        expect(BucketVersionResolver.writeBucket(b), b, reason: 'bucket=$b');
      }
    });

    test('readBuckets returns only the base', () {
      expect(BucketVersionResolver.readBuckets('images'), <String>['images']);
    });

    test('no bucket is a forbidden write target', () {
      expect(BucketVersionResolver.isForbiddenWriteTarget('images'), isFalse);
      expect(BucketVersionResolver.isForbiddenWriteTarget('dump'), isFalse);
    });
  });

  group('enabled', () {
    setUp(() => BucketVersionResolver.enabled = true);

    test('managed content bases route to their -v8 sibling', () {
      expect(BucketVersionResolver.writeBucket('images'), 'images-v8');
      expect(BucketVersionResolver.writeBucket('videos'), 'videos-v8');
      expect(BucketVersionResolver.writeBucket('audio'), 'audio-v8');
      expect(BucketVersionResolver.writeBucket('documents'), 'documents-v8');
    });

    test('writeBucket is idempotent — already-v8 passes through (no -v8-v8)', () {
      expect(BucketVersionResolver.writeBucket('images-v8'), 'images-v8');
    });

    test('unmanaged buckets pass through (un-migrated metadata / custom / test)',
        () {
      for (final b in <String>[
        'face-metadata', 'playlists',
        'website-assets', 'nft-assets',
        'integration-test', 'my-custom-folder',
      ]) {
        expect(BucketVersionResolver.writeBucket(b), b, reason: 'bucket=$b');
      }
    });

    test('readBuckets merges legacy + v8 for managed bases only', () {
      expect(
        BucketVersionResolver.readBuckets('images'),
        <String>['images', 'images-v8'],
      );
      expect(BucketVersionResolver.readBuckets('dump'), <String>['dump']);
    });

    test('managed legacy bases are forbidden write targets', () {
      expect(BucketVersionResolver.isForbiddenWriteTarget('images'), isTrue);
      expect(BucketVersionResolver.isForbiddenWriteTarget('videos'), isTrue);
      expect(BucketVersionResolver.isForbiddenWriteTarget('audio'), isTrue);
      expect(BucketVersionResolver.isForbiddenWriteTarget('documents'), isTrue);
    });

    test('v8 siblings and unmanaged buckets are NOT forbidden', () {
      expect(BucketVersionResolver.isForbiddenWriteTarget('images-v8'), isFalse);
      expect(
        BucketVersionResolver.isForbiddenWriteTarget('website-assets'),
        isFalse,
      );
      expect(
        BucketVersionResolver.isForbiddenWriteTarget('face-metadata'),
        isFalse,
      );
    });

    test('migrated metadata buckets route writes to -v8', () {
      for (final b in <String>[
        'dump-metadata',
        'tag-metadata',
        'nft-metadata',
        'website-metadata',
        'app-metadata',
        'fula-metadata', // shared 5-service bucket (P6 final piece)
      ]) {
        expect(BucketVersionResolver.writeBucket(b), '$b-v8', reason: b);
        expect(BucketVersionResolver.isForbiddenWriteTarget(b), isTrue,
            reason: b);
        // ...but a metadata bucket does NOT get the content LIST-merge, nor is
        // it a managed content base.
        expect(BucketVersionResolver.readBuckets(b), <String>[b], reason: b);
        expect(BucketVersionResolver.isManagedBase(b), isFalse, reason: b);
      }
    });

    test('migrated shelf-content buckets route writes to -v8 (no list-merge)',
        () {
      for (final b in <String>['dump', 'dump-thumbs']) {
        expect(BucketVersionResolver.writeBucket(b), '$b-v8', reason: b);
        expect(BucketVersionResolver.isForbiddenWriteTarget(b), isTrue,
            reason: b);
        // The shelf addresses each blob by the explicit key in its manifest —
        // so no content LIST-merge, and not a managed content base.
        expect(BucketVersionResolver.readBuckets(b), <String>[b], reason: b);
        expect(BucketVersionResolver.isManagedBase(b), isFalse, reason: b);
      }
    });

    test('asset / un-migrated buckets still pass through (incremental)', () {
      // Asset buckets are a separate (Type-B) scope — never in the metadata set.
      expect(BucketVersionResolver.writeBucket('website-assets'),
          'website-assets');
      expect(BucketVersionResolver.writeBucket('app-backups'), 'app-backups');
      expect(BucketVersionResolver.isForbiddenWriteTarget('website-assets'),
          isFalse);
    });
  });

  group('classification helpers (flag-independent)', () {
    test('isManagedBase', () {
      expect(BucketVersionResolver.isManagedBase('images'), isTrue);
      expect(BucketVersionResolver.isManagedBase('documents'), isTrue);
      expect(BucketVersionResolver.isManagedBase('images-v8'), isFalse);
      expect(BucketVersionResolver.isManagedBase('dump'), isFalse);
    });

    test('isV8', () {
      expect(BucketVersionResolver.isV8('images-v8'), isTrue);
      expect(BucketVersionResolver.isV8('documents-v8'), isTrue);
      expect(BucketVersionResolver.isV8('images'), isFalse);
      expect(BucketVersionResolver.isV8('dump'), isFalse);
    });

    test('baseOf strips a -v8 suffix (else passthrough)', () {
      expect(BucketVersionResolver.baseOf('images-v8'), 'images');
      expect(BucketVersionResolver.baseOf('documents-v8'), 'documents');
      expect(BucketVersionResolver.baseOf('images'), 'images');
      expect(BucketVersionResolver.baseOf('dump'), 'dump');
      expect(BucketVersionResolver.baseOf('my-custom-v8'), 'my-custom');
    });

    test('sameFamily matches base <-> v8 sibling (null never matches)', () {
      expect(BucketVersionResolver.sameFamily('images', 'images-v8'), isTrue);
      expect(BucketVersionResolver.sameFamily('images-v8', 'images'), isTrue);
      expect(BucketVersionResolver.sameFamily('images', 'images'), isTrue);
      expect(BucketVersionResolver.sameFamily('images-v8', 'images-v8'), isTrue);
      expect(BucketVersionResolver.sameFamily('images', 'videos'), isFalse);
      expect(BucketVersionResolver.sameFamily('images-v8', 'videos-v8'), isFalse);
      expect(BucketVersionResolver.sameFamily(null, 'images'), isFalse);
    });
  });
}
