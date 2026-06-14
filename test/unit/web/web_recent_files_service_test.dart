import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_recent_entry.dart';

/// Unit tests for the pure recents-merge logic (#17). The encrypted
/// IndexedDB / crypto.subtle store (web_recent_files_service.dart) imports
/// `package:web` and so is browser-only; the dedup + move-to-top + cap +
/// eviction core lives in the VM-safe web_recent_entry.dart and is tested
/// here.
WebRecentEntry _e(String key, int at, {String bucket = 'images-v8'}) =>
    WebRecentEntry(
      bucket: bucket,
      base: 'images',
      key: key,
      name: key,
      mime: 'image/*',
      size: 1,
      accessedAtMs: at,
      hasThumb: false,
    );

void main() {
  group('mergeRecentEntries', () {
    test('adds to an empty list', () {
      final (kept, dropped) = mergeRecentEntries(const [], _e('/a', 1));
      expect(kept.map((x) => x.key), ['/a']);
      expect(dropped, isEmpty);
    });

    test('orders newest first', () {
      final (kept, _) = mergeRecentEntries([_e('/a', 1)], _e('/b', 2));
      expect(kept.map((x) => x.key), ['/b', '/a']);
    });

    test('re-open dedups by (bucket,key) and moves to top', () {
      final (kept, dropped) = mergeRecentEntries(
        [_e('/a', 1), _e('/b', 2)],
        _e('/a', 3),
      );
      expect(kept.map((x) => x.key), ['/a', '/b']);
      expect(kept.where((x) => x.key == '/a').length, 1);
      expect(dropped, isEmpty);
    });

    test('same key in a different bucket is a distinct entry', () {
      final (kept, _) = mergeRecentEntries(
        [_e('/a', 1, bucket: 'images-v8')],
        _e('/a', 2, bucket: 'documents-v8'),
      );
      expect(kept.length, 2);
    });

    test('caps at the limit and reports the evicted oldest', () {
      final existing = [
        for (var i = 0; i < kWebRecentCap; i++) _e('/f$i', i + 1),
      ];
      final (kept, dropped) = mergeRecentEntries(existing, _e('/new', 9999));
      expect(kept.length, kWebRecentCap);
      expect(kept.first.key, '/new');
      // Oldest (/f0 at t=1) falls off and is reported for thumb cleanup.
      expect(dropped.map((x) => x.key), ['/f0']);
    });
  });
}
