import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_l1_budget.dart';

void main() {
  group('L1Budget', () {
    test('inserts under budget evict nothing and count bytes', () {
      final b = L1Budget(budgetBytes: 100);
      expect(b.insert('a', 40), isEmpty);
      expect(b.insert('b', 40), isEmpty);
      expect(b.totalBytes, 80);
    });

    test('over budget evicts strictly coldest-first until it fits', () {
      final b = L1Budget(budgetBytes: 100);
      b.insert('a', 40);
      b.insert('b', 40);
      expect(b.insert('c', 40), ['a']); // a is coldest
      expect(b.totalBytes, 80);
      expect(b.insert('d', 90), ['b', 'c']);
      expect(b.totalBytes, 90);
    });

    test('touch reorders: touched entry survives the next eviction', () {
      final b = L1Budget(budgetBytes: 100);
      b.insert('a', 40);
      b.insert('b', 40);
      b.touch('a'); // b is now coldest
      expect(b.insert('c', 40), ['b']);
    });

    test('re-inserting an existing key replaces it and never self-evicts',
        () {
      final b = L1Budget(budgetBytes: 100);
      b.insert('a', 90);
      expect(b.insert('a', 95), isEmpty); // old 90 released first
      expect(b.totalBytes, 95);
    });

    test('shouldCache is false only above the whole budget', () {
      final b = L1Budget(budgetBytes: 100);
      expect(b.shouldCache(100), isTrue);
      expect(b.shouldCache(101), isFalse);
    });

    test('an entry larger than the budget evicts everything else if forced',
        () {
      // Callers gate on shouldCache; insert() itself still behaves
      // sanely if misused: evicts all, then holds the oversized entry.
      final b = L1Budget(budgetBytes: 100);
      b.insert('a', 40);
      expect(b.insert('big', 150), ['a']);
      expect(b.totalBytes, 150);
    });

    test('remove and clear keep the byte counter consistent', () {
      final b = L1Budget(budgetBytes: 100);
      b.insert('a', 30);
      b.insert('b', 30);
      b.remove('a');
      expect(b.totalBytes, 30);
      b.remove('missing'); // no-op
      expect(b.totalBytes, 30);
      b.clear();
      expect(b.totalBytes, 0);
      expect(b.insert('c', 100), isEmpty);
    });

    test('mixed workload keeps counter equal to sum of resident entries',
        () {
      final b = L1Budget(budgetBytes: 200);
      b.insert('a', 50);
      b.insert('b', 60);
      b.touch('a');
      b.insert('c', 70);
      b.insert('b', 10); // replace shrinks
      b.remove('a');
      expect(b.totalBytes, 70 + 10);
    });
  });
}
