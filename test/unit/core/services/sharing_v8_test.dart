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
import 'package:fula_files/shared/utils/error_messages.dart';

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

  group('P8.3: empty/pre-v8 share errors surface a friendly note', () {
    // The sharing service throws these when a folder/tag has nothing shareable
    // in v8 yet; ErrorMessages must turn them into a clear "re-upload" note
    // instead of the generic "Unable to share. Please try again."
    test('every empty/pending share message avoids the generic fallback', () {
      const cases = <String>[
        'SharingException: Tag "x" has no shareable files — older files must '
            'be re-uploaded to share them.',
        'SharingException: No files here can be shared yet — newly uploaded '
            'files are shareable; older files must be re-uploaded to share them.',
        'SharingException: No cloud files yet. 1 file(s) are uploading — try '
            'again in a moment.',
      ];
      for (final raw in cases) {
        final msg = ErrorMessages.forShare(Exception(raw));
        expect(msg, isNot('Unable to share. Please try again.'), reason: raw);
        expect(msg.toLowerCase(), contains('re-upload'), reason: raw);
      }
    });

    test('an unrelated share error still gets the generic share message', () {
      final msg = ErrorMessages.forShare(
          Exception('SharingException: recipient public key invalid'));
      expect(msg.toLowerCase(), isNot(contains('re-upload')));
    });
  });
}
