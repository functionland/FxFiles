import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_shelf_write_logic.dart';

/// The shelf manifest is a FULL SNAPSHOT overwritten on every add, so
/// `_readV8BlobOrThrow` refuses to write unless the current copy is either
/// readable or *structurally confirmed absent*. This predicate is the whole
/// safety boundary: too narrow and a user who has never had a v8 index can
/// never create one; too broad and a damaged index gets silently overwritten.
void main() {
  group('confirmed absence - safe to write a fresh manifest', () {
    test('fula-client structured ObjectNotFound (the reported deadlock)', () {
      // crates/fula-client/src/error.rs:48 -> "Object not found: {bucket}/{key}"
      expect(
        isConfirmedShelfAbsence(Exception(
            'FulaApiException: Failed to download object: AnyhowException('
            'Object not found: dump-metadata-v8/.fula/dumps/0e2ec6dca6e5708b.json)')),
        isTrue,
      );
    });

    test('S3 structural codes', () {
      expect(isConfirmedShelfAbsence(Exception('NoSuchKey')), isTrue);
      expect(isConfirmedShelfAbsence(Exception('NoSuchBucket')), isTrue);
    });
  });

  group('NOT absence - must abort rather than overwrite', () {
    test('gc-orphaned index is damage, not absence', () {
      // fula-cli/src/handlers/object.rs:743 - same words, NO colon. Treating
      // this as absence would overwrite a shelf whose blobs still exist.
      expect(
        isConfirmedShelfAbsence(Exception(
            'Object not found (gc-orphaned index; client recovers by CID)')),
        isFalse,
      );
      expect(
        isConfirmedShelfAbsence(Exception(
            'Object not found (gc-orphaned block; client recovers by CID)')),
        isFalse,
      );
    });

    test('server-side generic phrasings', () {
      // fula-core/src/bucket.rs:1376 / 1404
      expect(
        isConfirmedShelfAbsence(Exception('Object not found in this bucket')),
        isFalse,
      );
      expect(
        isConfirmedShelfAbsence(
            Exception('Object not found in any matching bucket')),
        isFalse,
      );
    });

    test('transport / proxy / auth failures', () {
      for (final msg in [
        '404 Not Found',
        'HTTP 404 from gateway',
        'not found',
        'Failed host lookup: s3.cloud.fx.land',
        '401 Unauthorized',
        '403 Forbidden',
        'Connection closed before full header was received',
        'decryption failed: aead::Error',
      ]) {
        expect(
          isConfirmedShelfAbsence(Exception(msg)),
          isFalse,
          reason: 'must not treat "$msg" as a confirmed empty shelf',
        );
      }
    });
  });
}
