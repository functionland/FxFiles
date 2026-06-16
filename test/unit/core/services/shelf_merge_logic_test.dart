import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_merge_logic.dart';

ShelfItem _item(String id, {String? name, DateTime? at}) => ShelfItem(
      id: id,
      receivedAt: at ?? DateTime.utc(2026, 6, 15),
      originalName: name ?? 'item-$id',
      sizeBytes: 1,
      localCachePath: '',
      category: ShelfCategory.note,
      contentSha: 'sha-$id',
    );

void main() {
  group('shelfCloudAdditions', () {
    test('returns cloud items the box lacks', () {
      final out = shelfCloudAdditions(
        boxIds: {'a'},
        tombstonedIds: const {},
        cloudItemsV8First: [_item('a'), _item('b'), _item('c')],
      );
      expect(out.map((i) => i.id).toList(), ['b', 'c']);
    });

    test('excludes items already in the box', () {
      final out = shelfCloudAdditions(
        boxIds: {'a', 'b'},
        tombstonedIds: const {},
        cloudItemsV8First: [_item('a'), _item('b')],
      );
      expect(out, isEmpty);
    });

    test('excludes tombstoned (locally-deleted) ids — no resurrection', () {
      final out = shelfCloudAdditions(
        boxIds: const {},
        tombstonedIds: {'b'},
        cloudItemsV8First: [_item('a'), _item('b')],
      );
      expect(out.map((i) => i.id).toList(), ['a']); // b stays deleted
    });

    test('v8 (first occurrence) wins a duplicate id', () {
      final out = shelfCloudAdditions(
        boxIds: const {},
        tombstonedIds: const {},
        cloudItemsV8First: [
          _item('x', name: 'v8-x'),
          _item('x', name: 'legacy-x'),
        ],
      );
      expect(out, hasLength(1));
      expect(out.single.originalName, 'v8-x');
    });

    test('empty cloud → no additions', () {
      expect(
        shelfCloudAdditions(
            boxIds: const {},
            tombstonedIds: const {},
            cloudItemsV8First: const []),
        isEmpty,
      );
    });
  });
}
