import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/web/services/web_search_logic.dart';

/// Unit tests for the pure web search filter (#8).
void main() {
  WebSearchEntry entry(String base, String key) =>
      WebSearchEntry(base, FulaObject(key: key, size: 0));

  final index = [
    entry('images', 'Vacation.JPG'),
    entry('images', 'sunset.png'),
    entry('videos', 'vacation-clip.mp4'),
    entry('documents', 'budget.xlsx'),
  ];

  List<String> names(List<WebSearchEntry> l) => l.map((e) => e.name).toList();

  test('blank query returns nothing (screen shows a prompt instead)', () {
    expect(searchEntries(index, ''), isEmpty);
    expect(searchEntries(index, '   '), isEmpty);
  });

  test('case-insensitive substring match across categories, index order', () {
    // Index order is preserved (a name-sort would put 'vacation-clip' first
    // since '-' < '.'), so this also guards against re-sorting.
    expect(names(searchEntries(index, 'vacation')),
        ['Vacation.JPG', 'vacation-clip.mp4']);
  });

  test('matches on extension/substring too', () {
    expect(names(searchEntries(index, '.png')), ['sunset.png']);
  });

  test('trims the query', () {
    expect(names(searchEntries(index, '  budget  ')), ['budget.xlsx']);
  });

  test('no match returns empty', () {
    expect(searchEntries(index, 'zzz'), isEmpty);
  });
}
