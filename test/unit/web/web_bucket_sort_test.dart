import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/web/services/web_bucket_sort.dart';

/// Unit tests for the pure web bucket sort (#7), mirroring native
/// file_service.dart (directories first; name caseless / date; asc/desc).
void main() {
  FulaObject obj(String key, {DateTime? date, bool dir = false}) =>
      FulaObject(
        key: key,
        size: 0,
        lastModified: date,
        isDirectory: dir,
      );

  final a = obj('apple.jpg', date: DateTime(2026, 1, 1));
  final b = obj('Banana.jpg', date: DateTime(2026, 3, 1));
  final c = obj('cherry.jpg', date: DateTime(2026, 2, 1));

  List<String> names(List<FulaObject> l) => l.map((o) => o.name).toList();

  test('date descending (default) = newest first', () {
    expect(names(sortObjects([a, b, c], WebSortBy.date, false)),
        ['Banana.jpg', 'cherry.jpg', 'apple.jpg']);
  });

  test('date ascending = oldest first', () {
    expect(names(sortObjects([a, b, c], WebSortBy.date, true)),
        ['apple.jpg', 'cherry.jpg', 'Banana.jpg']);
  });

  test('name ascending is case-insensitive (A-Z)', () {
    expect(names(sortObjects([c, a, b], WebSortBy.name, true)),
        ['apple.jpg', 'Banana.jpg', 'cherry.jpg']);
  });

  test('name descending (Z-A)', () {
    expect(names(sortObjects([a, b, c], WebSortBy.name, false)),
        ['cherry.jpg', 'Banana.jpg', 'apple.jpg']);
  });

  test('directories sort before files regardless of mode', () {
    final dir = obj('zzz-folder', dir: true);
    final result = sortObjects([a, dir, b], WebSortBy.name, true);
    expect(result.first.isDirectory, isTrue); // 'zzz-folder' first despite Z
    expect(names(result), ['zzz-folder', 'apple.jpg', 'Banana.jpg']);
  });

  test('does not mutate the input list', () {
    final input = [a, b, c];
    sortObjects(input, WebSortBy.name, true);
    expect(identical(input[0], a), isTrue);
    expect(names(input), ['apple.jpg', 'Banana.jpg', 'cherry.jpg']);
  });

  test('missing lastModified sorts as epoch 0 (oldest)', () {
    final noDate = obj('nodate.jpg');
    expect(names(sortObjects([b, noDate], WebSortBy.date, true)).first,
        'nodate.jpg');
  });
}
