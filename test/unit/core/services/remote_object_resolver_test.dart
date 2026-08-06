import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/remote_object_resolver.dart';

/// Contract for the (bucket, key) resolution that Ask AI (and any other
/// consumer of a stored `remoteKey`) must follow.
///
/// The bug this pins down: the old AiAskService split `remoteKey` on '/' and
/// used the first segment as a bucket. Shelf keys are '<year>/<month>/<id>-name',
/// so it asked for a bucket literally named `2026`, the download 404'd, the
/// error was swallowed, and the request went out with zero attachments.
void main() {
  setUp(() => BucketVersionResolver.enabled = true);
  tearDown(() => BucketVersionResolver.enabled = true);

  List<String> asStrings(List<RemoteObjectRef> refs) =>
      refs.map((r) => '${r.bucket}|${r.key}').toList();

  group('year-prefixed bare keys (the Ask AI regression)', () {
    test('shelf key with a recorded sourceBucket never yields bucket "2026"',
        () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: '2026/07/871c2305-4_5899982044640844890.pdf',
        fileName: '4_5899982044640844890.pdf',
        sourceBucket: 'dump-v8',
        fallbackBase: 'dump',
      );

      expect(refs, isNotEmpty);
      expect(refs.first.bucket, 'dump-v8');
      expect(refs.first.key, '2026/07/871c2305-4_5899982044640844890.pdf');
      expect(refs.map((r) => r.bucket), isNot(contains('2026')));
    });

    test('pre-P7 shelf row (null sourceBucket) still reaches legacy dump', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: '2025/03/abc-notes.pdf',
        fileName: 'notes.pdf',
        sourceBucket: null,
        fallbackBase: 'dump',
      );

      // shelf_item.dart documents a null sourceBucket as the LEGACY `dump`
      // bucket, while the current v8 write target is `dump-v8`. Emitting both
      // makes the ambiguity harmless instead of a coin flip.
      expect(refs.map((r) => r.bucket), containsAll(['dump-v8', 'dump']));
      expect(refs.map((r) => r.bucket), isNot(contains('2025')));
      for (final r in refs) {
        expect(r.key, '2025/03/abc-notes.pdf');
      }
    });

    test('year-prefixed tag key with no bucket hint falls back to extension',
        () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: '2026/07/holiday.jpg',
        fileName: 'holiday.jpg',
      );

      expect(refs.map((r) => r.bucket), isNot(contains('2026')));
      expect(refs.first.bucket, 'images-v8');
      expect(refs.first.key, '2026/07/holiday.jpg');
    });
  });

  group('bare keys with no slash', () {
    test('never invents the non-existent "files" bucket', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'photo.jpg',
        fileName: 'photo.jpg',
      );

      expect(refs.map((r) => r.bucket), isNot(contains('files')));
      expect(asStrings(refs), ['images-v8|photo.jpg', 'images|photo.jpg']);
    });

    test('maps each category from the file extension', () {
      expect(
        resolveRemoteObjectCandidates(remoteKey: 'a.mp4', fileName: 'a.mp4')
            .first
            .bucket,
        'videos-v8',
      );
      expect(
        resolveRemoteObjectCandidates(remoteKey: 'a.mp3', fileName: 'a.mp3')
            .first
            .bucket,
        'audio-v8',
      );
      expect(
        resolveRemoteObjectCandidates(remoteKey: 'a.pdf', fileName: 'a.pdf')
            .first
            .bucket,
        'documents-v8',
      );
    });

    test('unmanaged categories have no v8 sibling', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'a.zip',
        fileName: 'a.zip',
      );
      expect(asStrings(refs), ['archives|a.zip']);
    });
  });

  group('composite keys written by the web cloud browser', () {
    test('a known bucket prefix is honoured and stripped', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'images-v8/2026/07/x.jpg',
        fileName: 'x.jpg',
      );

      expect(refs.first.bucket, 'images-v8');
      expect(refs.first.key, '2026/07/x.jpg');
    });

    test('a legacy bucket prefix also offers its v8 sibling', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'images/x.jpg',
        fileName: 'x.jpg',
      );

      expect(refs.first, const RemoteObjectRef('images', 'x.jpg'));
      expect(refs.map((r) => r.bucket), contains('images-v8'));
    });

    test('an explicit sourceBucket outranks a bucket-looking prefix', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'images-v8/x.jpg',
        fileName: 'x.jpg',
        sourceBucket: 'dump-v8',
      );

      expect(refs.first.bucket, 'dump-v8');
      expect(refs.first.key, 'x.jpg');
    });
  });

  group('ambiguity is resolved by trying both readings', () {
    test('a user FOLDER named like a bucket still resolves', () {
      // 'documents/' here is a real folder inside the images bucket, not a
      // bucket name. Both interpretations are offered so the lookup can
      // recover instead of silently failing.
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'documents/scan.jpg',
        fileName: 'scan.jpg',
      );

      expect(asStrings(refs), contains('documents|scan.jpg'));
      expect(asStrings(refs), contains('images-v8|documents/scan.jpg'));
    });

    test('an unknown leading segment is kept as part of the key', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'Camera Roll/x.jpg',
        fileName: 'x.jpg',
      );

      for (final r in refs) {
        expect(r.key, 'Camera Roll/x.jpg');
      }
      expect(refs.first.bucket, 'images-v8');
    });

    test('candidates are de-duplicated', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'images-v8/x.jpg',
        fileName: 'x.jpg',
        sourceBucket: 'images-v8',
      );
      expect(asStrings(refs).toSet().length, asStrings(refs).length);
    });
  });

  group('v8 routing disabled', () {
    test('falls back to legacy buckets only', () {
      BucketVersionResolver.enabled = false;

      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'photo.jpg',
        fileName: 'photo.jpg',
      );
      expect(asStrings(refs), ['images|photo.jpg']);
    });
  });

  group('degenerate input', () {
    test('leading slashes are stripped', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: '/x.jpg',
        fileName: 'x.jpg',
      );
      for (final r in refs) {
        expect(r.key, 'x.jpg');
        expect(r.bucket, isNotEmpty);
      }
    });

    test('an empty remoteKey yields no candidates', () {
      expect(
        resolveRemoteObjectCandidates(remoteKey: '', fileName: 'x.jpg'),
        isEmpty,
      );
      expect(
        resolveRemoteObjectCandidates(remoteKey: '   ', fileName: 'x.jpg'),
        isEmpty,
      );
    });

    test('a bucket-only key yields no candidates', () {
      expect(
        resolveRemoteObjectCandidates(
            remoteKey: 'images-v8/', fileName: 'x.jpg'),
        isEmpty,
      );
    });
  });
}
