// Pure tests for REQ2 folder-add planning: which listed objects become group
// files (skip directories + .fula_keep markers; count already-present as skipped).

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/features/sharing/utils/collab_folder_add.dart';

FulaObject _obj(String key, {bool dir = false, int size = 10}) =>
    FulaObject(key: key, size: size, isDirectory: dir);

void main() {
  group('planCollabFolderAdd', () {
    test('adds plain files, preserving listing order', () {
      final plan = planCollabFolderAdd(
        [_obj('docs/a.txt'), _obj('docs/b.txt')],
        <String>{},
      );
      expect(plan.toAdd.map((o) => o.key), ['docs/a.txt', 'docs/b.txt']);
      expect(plan.skipped, 0);
    });

    test('excludes directories and .fula_keep markers (not counted)', () {
      final plan = planCollabFolderAdd(
        [
          _obj('docs/', dir: true),
          _obj('docs/.fula_keep', size: 0),
          _obj('docs/a.txt'),
        ],
        <String>{},
      );
      expect(plan.toAdd.map((o) => o.key), ['docs/a.txt']);
      expect(plan.skipped, 0); // dirs/markers are filtered, not "skipped"
    });

    test('counts objects already in the group as skipped', () {
      final plan = planCollabFolderAdd(
        [_obj('docs/a.txt'), _obj('docs/b.txt'), _obj('docs/c.txt')],
        {'docs/a.txt', 'docs/c.txt'},
      );
      expect(plan.toAdd.map((o) => o.key), ['docs/b.txt']);
      expect(plan.skipped, 2);
    });

    test('empty listing yields nothing to add', () {
      final plan = planCollabFolderAdd(const [], <String>{});
      expect(plan.toAdd, isEmpty);
      expect(plan.skipped, 0);
    });
  });
}
