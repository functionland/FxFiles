// Device-free unit tests for the P8 share-v8 routing helper.
//
// Folder / tag / category shares are "v8-native": they enumerate a bucket, so a
// NEW share targets `<base>-v8`. `shareV8Bucket` is the pure routing primitive
// behind every share-creation site; the resolver's own test covers `sameFamily`
// (used by the discovery badges). The live token-mint + manifest round-trip is
// integration-only (the service uses the non-injectable FulaApiService
// singleton), so this file pins the routing decision, not the I/O.
//
// Run: flutter test test/unit/core/services/sharing_v8_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/sharing_service.dart';

void main() {
  // `enabled` is global mutable state — reset around every test.
  setUp(() => BucketVersionResolver.enabled = false);
  tearDown(() => BucketVersionResolver.enabled = false);

  group('shareV8Bucket — folder/tag/category shares route to -v8', () {
    test('enabled: a managed content base routes to its -v8 sibling', () {
      BucketVersionResolver.enabled = true;
      expect(shareV8Bucket('images'), 'images-v8');
      expect(shareV8Bucket('videos'), 'videos-v8');
      expect(shareV8Bucket('audio'), 'audio-v8');
      expect(shareV8Bucket('documents'), 'documents-v8');
    });

    test('enabled: idempotent — an already-v8 bucket stays (no -v8-v8)', () {
      BucketVersionResolver.enabled = true;
      expect(shareV8Bucket('images-v8'), 'images-v8');
      expect(shareV8Bucket('documents-v8'), 'documents-v8');
    });

    test('enabled: an unmanaged bucket passes through (custom folder)', () {
      BucketVersionResolver.enabled = true;
      expect(shareV8Bucket('my-custom-folder'), 'my-custom-folder');
    });

    test('disabled (default): pure passthrough — exact flag-off rollback', () {
      for (final b in <String>['images', 'images-v8', 'my-custom-folder']) {
        expect(shareV8Bucket(b), b, reason: 'bucket=$b');
      }
    });
  });
}
