// Pure tests for the shared collab folder-tree util (REQ4) — the derivation both
// the native detail screen and the web shell use, so a drift here would diverge
// the two platforms' folder views.

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/features/sharing/utils/collab_folder_tree.dart';

CollaborationFile _file(
  String id, {
  String encType = 'collab',
  String? pathScope,
  String? contentType,
  DateTime? addedAt,
}) =>
    CollaborationFile(
      id: id,
      fileName: '$id.txt',
      contentType: contentType,
      bucket: 'b',
      storageKey: 'sk-$id',
      pathScope: pathScope,
      addedByPublicKey: 'pk',
      addedAt: addedAt ?? DateTime(2026, 1, 1),
      fileSize: 1,
      encType: encType,
    );

CollaborationGroup _group(List<CollaborationFile> files) => CollaborationGroup(
      id: 'g',
      name: 'n',
      ownerPublicKey: 'o',
      manifestBucket: 'mb',
      manifestKey: 'mk',
      createdAt: DateTime(2026),
      files: files,
      version: 1,
      updatedAt: DateTime(2026),
    );

void main() {
  group('collabItemsAtPath', () {
    test('fula files render at the root regardless of pathScope', () {
      // A fula-encrypted file keeps its STORAGE KEY in pathScope, so it must
      // never be mistaken for a folder path — it shows at the root.
      final g = _group([
        _file('a', encType: 'fula', pathScope: 'images/looks-like/a/folder'),
      ]);
      final root = collabItemsAtPath(g, '');
      expect(root.folders, isEmpty);
      expect(root.files.map((f) => f.id), ['a']);
    });

    test('collab files build a folder hierarchy from pathScope', () {
      // pathScope is the file's FOLDER (not the full path); fileName is separate.
      final g = _group([
        _file('root', encType: 'collab', pathScope: ''),
        _file('a', encType: 'collab', pathScope: 'docs'),
        _file('b', encType: 'collab', pathScope: 'docs/sub'),
      ]);

      final root = collabItemsAtPath(g, '');
      expect(root.folders, ['docs']);
      expect(root.files.map((f) => f.id), ['root']); // file at root only

      final docs = collabItemsAtPath(g, 'docs');
      expect(docs.folders, ['sub']);
      expect(docs.files.map((f) => f.id), ['a']);

      final sub = collabItemsAtPath(g, 'docs/sub');
      expect(sub.folders, isEmpty);
      expect(sub.files.map((f) => f.id), ['b']);
    });

    test('explicit directory markers surface as folders, not files', () {
      final g = _group([
        _file('dir',
            encType: 'collab',
            pathScope: 'empty',
            contentType: 'application/x-directory'),
      ]);
      final root = collabItemsAtPath(g, '');
      expect(root.folders, contains('empty'));
      expect(root.files, isEmpty);
    });

    test('folders are sorted and files ordered by addedAt', () {
      final g = _group([
        _file('z', encType: 'collab', pathScope: 'zeta'),
        _file('a', encType: 'collab', pathScope: 'alpha'),
        _file('late',
            encType: 'fula', addedAt: DateTime(2026, 5, 1)),
        _file('early',
            encType: 'fula', addedAt: DateTime(2026, 1, 1)),
      ]);
      final root = collabItemsAtPath(g, '');
      expect(root.folders, ['alpha', 'zeta']);
      expect(root.files.map((f) => f.id), ['early', 'late']);
    });
  });

  group('collabCountFolderFiles', () {
    test('counts non-directory files at or beneath a folder', () {
      final g = _group([
        _file('a', encType: 'collab', pathScope: 'docs'),
        _file('b', encType: 'collab', pathScope: 'docs/sub'),
        _file('dir',
            encType: 'collab',
            pathScope: 'docs/sub',
            contentType: 'application/x-directory'),
        _file('other', encType: 'collab', pathScope: 'misc'),
      ]);
      expect(collabCountFolderFiles(g, 'docs'), 2); // a + b, not the dir marker
      expect(collabCountFolderFiles(g, 'docs/sub'), 1); // b
      expect(collabCountFolderFiles(g, 'misc'), 1);
    });
  });
}
