import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/remote_object_resolver.dart';
// The RESOLVER itself transitively imports `package:web`, which the VM
// test runner cannot load; the decisions it makes live here instead.
import 'package:fula_files/web/services/web_tagged_file_logic.dart';

/// The Tags screen joins `TaggedFile.remoteKey` to a real cloud object.
/// Both halves of that join have to agree on what a key looks like, and
/// the historical bug is treating "whatever is before the first slash"
/// as a bucket name.
void main() {
  group('normalizeTaggedObjectKey', () {
    test('strips a leading segment that IS a known bucket', () {
      expect(
        normalizeTaggedObjectKey('images/photo.jpg'),
        'photo.jpg',
      );
      expect(
        normalizeTaggedObjectKey('documents/a/b.pdf'),
        'a/b.pdf',
      );
    });

    test('strips the -v8 sibling too', () {
      expect(
        normalizeTaggedObjectKey('images-v8/photo.jpg'),
        'photo.jpg',
      );
    });

    test('KEEPS a leading segment that is not a bucket', () {
      // The shelf key shape. Under the naive rule this became a request
      // for a bucket literally named `2026`, and the 404 was swallowed.
      expect(
        normalizeTaggedObjectKey('2026/07/report.pdf'),
        '2026/07/report.pdf',
      );
      expect(
        normalizeTaggedObjectKey('holiday/pic.jpg'),
        'holiday/pic.jpg',
      );
    });

    test('leaves a bare key untouched', () {
      expect(
        normalizeTaggedObjectKey('photo.jpg'),
        'photo.jpg',
      );
    });

    test('drops leading slashes', () {
      expect(
        normalizeTaggedObjectKey('/photo.jpg'),
        'photo.jpg',
      );
      expect(
        normalizeTaggedObjectKey('images//photo.jpg'),
        'photo.jpg',
      );
    });
  });

  group('candidate expansion feeding the resolver', () {
    test('a bare image key targets the images family', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'photo.jpg',
        fileName: 'photo.jpg',
      );
      expect(refs, isNotEmpty);
      expect(refs.map((r) => r.bucket), contains('images-v8'));
      // Every candidate must carry the full key for a bare remoteKey.
      expect(refs.every((r) => r.key == 'photo.jpg'), isTrue);
    });

    test('a composite key is offered BOTH ways', () {
      // `documents/` is both a real bucket and a plausible user folder,
      // so the resolver must offer the stripped and unstripped readings
      // rather than silently picking one.
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'documents/notes.txt',
        fileName: 'notes.txt',
      );
      expect(refs.any((r) => r.key == 'notes.txt'), isTrue);
      expect(refs.any((r) => r.key == 'documents/notes.txt'), isTrue);
    });

    test('a shelf-shaped key never yields a bucket named after a date', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: '2026/07/report.pdf',
        fileName: 'report.pdf',
      );
      expect(refs, isNotEmpty);
      expect(refs.map((r) => r.bucket), isNot(contains('2026')));
      expect(refs.every((r) => r.key == '2026/07/report.pdf'), isTrue);
    });

    test('an explicit sourceBucket wins', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'clip.mp4',
        fileName: 'clip.mp4',
        sourceBucket: 'dump',
      );
      expect(refs.first.bucket, anyOf('dump', 'dump-v8'));
    });

    test('an empty or folder-marker key yields nothing to look up', () {
      expect(
        resolveRemoteObjectCandidates(remoteKey: '', fileName: 'x'),
        isEmpty,
      );
      expect(
        resolveRemoteObjectCandidates(remoteKey: 'images/', fileName: 'x'),
        isEmpty,
      );
    });
  });

  group('firstResolvedCandidate', () {
    test('takes the FIRST candidate present, not just any', () {
      // Order is meaningful: for a managed category the healthy -v8
      // bucket precedes the gc-damaged legacy one, so a file present in
      // both must resolve to v8.
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'photo.jpg',
        fileName: 'photo.jpg',
      );
      final listings = {
        'images-v8': {'photo.jpg': 'V8'},
        'images': {'photo.jpg': 'LEGACY'},
      };
      expect(firstResolvedCandidate(refs, listings), ('images-v8', 'V8'));
    });

    test('falls through to a later candidate when the first misses', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'photo.jpg',
        fileName: 'photo.jpg',
      );
      final listings = {
        'images-v8': <String, String>{},
        'images': {'photo.jpg': 'LEGACY'},
      };
      expect(firstResolvedCandidate(refs, listings), ('images', 'LEGACY'));
    });

    test('matches a composite listing key against a bare candidate', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'photo.jpg',
        fileName: 'photo.jpg',
      );
      final listings = {
        'images-v8': indexListingByKey(
          const ['images-v8/photo.jpg'],
          (k) => k,
        ),
      };
      expect(firstResolvedCandidate(refs, listings)?.$1, 'images-v8');
    });

    test('returns null when nothing resolves', () {
      final refs = resolveRemoteObjectCandidates(
        remoteKey: 'gone.jpg',
        fileName: 'gone.jpg',
      );
      expect(firstResolvedCandidate(refs, <String, Map<String, String>>{}),
          isNull);
    });
  });

  group('preferredBuckets', () {
    test('is the best candidate of each file, deduped', () {
      final a = resolveRemoteObjectCandidates(
          remoteKey: 'a.jpg', fileName: 'a.jpg');
      final b = resolveRemoteObjectCandidates(
          remoteKey: 'b.jpg', fileName: 'b.jpg');
      final c = resolveRemoteObjectCandidates(
          remoteKey: 'c.pdf', fileName: 'c.pdf');
      final preferred = preferredBuckets([a, b, c]);
      expect(preferred, {'images-v8', 'documents-v8'});
      // The legacy siblings are deliberately NOT in the first pass.
      expect(preferred, isNot(contains('images')));
    });

    test('ignores files with no candidates at all', () {
      expect(preferredBuckets([const [], const []]), isEmpty);
    });
  });
}
