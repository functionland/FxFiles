import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/web/utils/cloud_folder_tree.dart';

/// Deterministic gate for the Cloud Files folder browser. The folder structure
/// is derived ENTIRELY on the client from the flat key list (listObjects sets
/// isDirectory=false and returns the whole bucket), so this derivation is the
/// only thing that proves create-folder / nested-upload / empty-folder work.
FulaObject _o(String key) => FulaObject(key: key, size: 1);

List<String> _fileNames(List<FulaObject> files) =>
    [for (final f in files) cloudKeyName(f.key)]..sort();

void main() {
  group('key normalization', () {
    test('normalizeCloudKey drops one leading slash', () {
      expect(normalizeCloudKey('/a/b'), 'a/b');
      expect(normalizeCloudKey('a/b'), 'a/b');
      expect(normalizeCloudKey('/'), '');
    });

    test('cloudKeyName returns the leaf', () {
      expect(cloudKeyName('/a/b/c.txt'), 'c.txt');
      expect(cloudKeyName('x.txt'), 'x.txt');
      expect(cloudKeyName('/x.txt'), 'x.txt');
    });

    test('normalizeCloudPrefix: no leading slash, single trailing slash', () {
      expect(normalizeCloudPrefix(''), '');
      expect(normalizeCloudPrefix('/'), '');
      expect(normalizeCloudPrefix('a/b'), 'a/b/');
      expect(normalizeCloudPrefix('/a/b/'), 'a/b/');
      expect(normalizeCloudPrefix('a/b//'), 'a/b/');
    });
  });

  group('folder markers', () {
    test('isFolderMarker matches by leaf name regardless of slashes', () {
      expect(isFolderMarker(_o('/sub/$kFolderMarkerName')), isTrue);
      expect(isFolderMarker(_o(kFolderMarkerName)), isTrue);
      expect(isFolderMarker(_o('/sub/photo.jpg')), isFalse);
    });

    test('stripFolderMarkers removes only markers', () {
      final list = [_o('/a.txt'), _o('/sub/$kFolderMarkerName'), _o('/b.txt')];
      final out = stripFolderMarkers(list);
      expect(_fileNames(out), ['a.txt', 'b.txt']);
    });
  });

  group('deriveCloudFolderView — root', () {
    test('root-only files: no folders', () {
      final v = deriveCloudFolderView([_o('/a.txt'), _o('/b.txt')], '');
      expect(v.folders, isEmpty);
      expect(_fileNames(v.files), ['a.txt', 'b.txt']);
    });

    test('mixed root files + a nested file → one folder, root file only', () {
      final v = deriveCloudFolderView(
          [_o('/a.txt'), _o('/sub/c.txt'), _o('/sub/deep/d.txt')], '');
      expect(v.folders, ['sub']);
      expect(_fileNames(v.files), ['a.txt']);
    });

    test('folders are de-duplicated and sorted', () {
      final v = deriveCloudFolderView(
          [_o('/zeta/1.txt'), _o('/alpha/2.txt'), _o('/alpha/3.txt')], '');
      expect(v.folders, ['alpha', 'zeta']);
      expect(v.files, isEmpty);
    });
  });

  group('deriveCloudFolderView — descend', () {
    final objects = [
      _o('/a.txt'),
      _o('/sub/c.txt'),
      _o('/sub/deep/d.txt'),
      _o('/sub/deep/e.txt'),
    ];

    test('inside sub/: one folder (deep) + direct file c.txt', () {
      final v = deriveCloudFolderView(objects, 'sub/');
      expect(v.folders, ['deep']);
      expect(_fileNames(v.files), ['c.txt']);
    });

    test('inside sub/deep/: two files, no folders', () {
      final v = deriveCloudFolderView(objects, 'sub/deep/');
      expect(v.folders, isEmpty);
      expect(_fileNames(v.files), ['d.txt', 'e.txt']);
    });

    test('prefix is normalized (missing trailing slash still works)', () {
      final v = deriveCloudFolderView(objects, 'sub');
      expect(v.folders, ['deep']);
      expect(_fileNames(v.files), ['c.txt']);
    });

    test('duplicate leaf names under different folders stay separate', () {
      final v = deriveCloudFolderView(
          [_o('/a/x.txt'), _o('/b/x.txt')], 'a/');
      expect(v.folders, isEmpty);
      expect(_fileNames(v.files), ['x.txt']);
    });
  });

  group('deriveCloudFolderView — empty folders via markers', () {
    test('marker-only folder appears at root but shows no files inside', () {
      final objects = [_o('/empty/$kFolderMarkerName')];
      final root = deriveCloudFolderView(objects, '');
      expect(root.folders, ['empty']);
      expect(root.files, isEmpty);

      final inside = deriveCloudFolderView(objects, 'empty/');
      expect(inside.folders, isEmpty);
      expect(inside.files, isEmpty); // marker hidden, not shown as a file
    });

    test('marker at the current level is never a file', () {
      final v = deriveCloudFolderView(
          [_o('/dir/$kFolderMarkerName'), _o('/dir/real.txt')], 'dir/');
      expect(v.folders, isEmpty);
      expect(_fileNames(v.files), ['real.txt']);
    });
  });

  group('deriveCloudFolderView — leading-slash agnostic', () {
    test('keys without a leading slash behave identically', () {
      final v = deriveCloudFolderView(
          [_o('a.txt'), _o('sub/c.txt')], '');
      expect(v.folders, ['sub']);
      expect(_fileNames(v.files), ['a.txt']);
    });

    test('mixed slash conventions in the same listing', () {
      final v = deriveCloudFolderView(
          [_o('/sub/c.txt'), _o('sub/d.txt')], 'sub/');
      expect(v.folders, isEmpty);
      expect(_fileNames(v.files), ['c.txt', 'd.txt']);
    });
  });

  group('normalizeCloudPrefix + cloudChildKey (rename/move keys)', () {
    test('collapses internal // runs (silent-orphan guard)', () {
      expect(normalizeCloudPrefix('foo//bar'), 'foo/bar/');
      expect(normalizeCloudPrefix('///a///b///'), 'a/b/');
    });

    test('cloudChildKey at root and inside a folder', () {
      expect(cloudChildKey('', 'a.txt'), '/a.txt');
      expect(cloudChildKey('photos/2024/', 'p.jpg'), '/photos/2024/p.jpg');
      expect(cloudChildKey('photos/2024', 'p.jpg'), '/photos/2024/p.jpg');
    });

    test('cloudChildKey collapses // so the file stays discoverable', () {
      final key = cloudChildKey('foo//bar', 'f.txt');
      expect(key, '/foo/bar/f.txt');
      final v = deriveCloudFolderView([_o(key)], 'foo/bar/');
      expect(_fileNames(v.files), ['f.txt']);
    });
  });
}
