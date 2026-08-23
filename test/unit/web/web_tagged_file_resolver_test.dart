import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/remote_object_resolver.dart';
import 'package:fula_files/web/services/web_tagged_file_resolver.dart';

/// The Tags screen joins `TaggedFile.remoteKey` to a real cloud object.
/// Both halves of that join have to agree on what a key looks like, and
/// the historical bug is treating "whatever is before the first slash"
/// as a bucket name.
void main() {
  group('normalizeTaggedObjectKey', () {
    test('strips a leading segment that IS a known bucket', () {
      expect(
        WebTaggedFileResolver.normalizeTaggedObjectKey('images/photo.jpg'),
        'photo.jpg',
      );
      expect(
        WebTaggedFileResolver.normalizeTaggedObjectKey('documents/a/b.pdf'),
        'a/b.pdf',
      );
    });

    test('strips the -v8 sibling too', () {
      expect(
        WebTaggedFileResolver.normalizeTaggedObjectKey('images-v8/photo.jpg'),
        'photo.jpg',
      );
    });

    test('KEEPS a leading segment that is not a bucket', () {
      // The shelf key shape. Under the naive rule this became a request
      // for a bucket literally named `2026`, and the 404 was swallowed.
      expect(
        WebTaggedFileResolver.normalizeTaggedObjectKey('2026/07/report.pdf'),
        '2026/07/report.pdf',
      );
      expect(
        WebTaggedFileResolver.normalizeTaggedObjectKey('holiday/pic.jpg'),
        'holiday/pic.jpg',
      );
    });

    test('leaves a bare key untouched', () {
      expect(
        WebTaggedFileResolver.normalizeTaggedObjectKey('photo.jpg'),
        'photo.jpg',
      );
    });

    test('drops leading slashes', () {
      expect(
        WebTaggedFileResolver.normalizeTaggedObjectKey('/photo.jpg'),
        'photo.jpg',
      );
      expect(
        WebTaggedFileResolver.normalizeTaggedObjectKey('images//photo.jpg'),
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
}
