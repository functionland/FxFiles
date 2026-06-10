// Unit tests for CollaborationGroup.mergeWith — the conflict-merge used when a
// collaboration manifest is read from multiple sources (local + S3 v8 + S3
// legacy + portal DB). Covers the per-file-id union + tombstone-union that make
// merge-both safe, and the P2 fix: revocation is monotonic (sticky) and expiry
// can only shorten, regardless of which side has the higher `version`.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/collaboration_group.dart';

void main() {
  CollaborationFile file(String id) => CollaborationFile(
        id: id,
        fileName: '$id.txt',
        bucket: 'images',
        storageKey: 'key-$id',
        addedByPublicKey: 'pk',
        addedAt: DateTime.utc(2026, 1, 1),
        fileSize: 1,
        encType: 'fula',
      );

  // Named `grp` (not `group`) to avoid shadowing flutter_test's `group(...)`.
  CollaborationGroup grp({
    int version = 1,
    bool isRevoked = false,
    DateTime? expiresAt,
    List<CollaborationFile> files = const [],
    List<String> removedFileIds = const [],
  }) =>
      CollaborationGroup(
        id: 'g1',
        name: 'Group',
        ownerPublicKey: 'owner',
        manifestBucket: 'fula-metadata',
        manifestKey: '.fula/collab/g1/manifest.json',
        createdAt: DateTime.utc(2026, 1, 1),
        expiresAt: expiresAt,
        isRevoked: isRevoked,
        files: files,
        removedFileIds: removedFileIds,
        version: version,
        updatedAt: DateTime.utc(2026, 1, 1),
      );

  group('CollaborationGroup.mergeWith — union + tombstones', () {
    test('unions files by id from both sides', () {
      final m = grp(version: 2, files: [file('x')])
          .mergeWith(grp(version: 1, files: [file('y')]));
      expect(m.files.map((f) => f.id), containsAll(<String>['x', 'y']));
    });

    test('a tombstone on either side removes the file even if the other still lists it', () {
      final m = grp(version: 2, removedFileIds: ['x'])
          .mergeWith(grp(version: 1, files: [file('x')]));
      expect(m.removedFileIds, contains('x'));
      expect(m.files.map((f) => f.id), isNot(contains('x')));
    });
  });

  group('CollaborationGroup.mergeWith — P2 security scalars', () {
    test('revoke is sticky: a revoked LOW-version side wins over a live HIGH-version side', () {
      final revokedLow = grp(version: 1, isRevoked: true);
      final liveHigh = grp(version: 5, isRevoked: false);
      expect(revokedLow.mergeWith(liveHigh).isRevoked, isTrue);
      expect(liveHigh.mergeWith(revokedLow).isRevoked, isTrue); // order-independent
    });

    test('expiry only shortens: the earlier expiry wins over a later one on a higher version', () {
      final soon = DateTime.utc(2026, 2, 1);
      final later = DateTime.utc(2026, 12, 1);
      final shortLow = grp(version: 1, expiresAt: soon);
      final longHigh = grp(version: 5, expiresAt: later);
      expect(shortLow.mergeWith(longHigh).expiresAt, soon);
      expect(longHigh.mergeWith(shortLow).expiresAt, soon); // order-independent
    });

    test('a set expiry wins over no-expiry (null), regardless of version', () {
      final exp = DateTime.utc(2026, 2, 1);
      final noExpiryHigh = grp(version: 9, expiresAt: null);
      final expiringLow = grp(version: 1, expiresAt: exp);
      expect(noExpiryHigh.mergeWith(expiringLow).expiresAt, exp);
      expect(expiringLow.mergeWith(noExpiryHigh).expiresAt, exp);
    });

    test('no expiry on both sides stays no-expiry', () {
      expect(grp(version: 2).mergeWith(grp(version: 1)).expiresAt, isNull);
    });
  });
}
