import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_file_view_mode.dart';

void main() {
  group('nextWebFileViewMode', () {
    test('cycles list → grid2 → grid3 → list', () {
      expect(nextWebFileViewMode(WebFileViewMode.list), WebFileViewMode.grid2);
      expect(nextWebFileViewMode(WebFileViewMode.grid2), WebFileViewMode.grid3);
      expect(nextWebFileViewMode(WebFileViewMode.grid3), WebFileViewMode.list);
    });

    test('three cycles return to the starting mode', () {
      for (final start in WebFileViewMode.values) {
        var m = start;
        for (var i = 0; i < 3; i++) {
          m = nextWebFileViewMode(m);
        }
        expect(m, start);
      }
    });
  });

  group('persistence round-trip', () {
    test('every mode survives name → parse', () {
      for (final m in WebFileViewMode.values) {
        expect(parseWebFileViewMode(webFileViewModeName(m)), m);
      }
    });

    test('absent / unknown / legacy values fall back to list', () {
      expect(parseWebFileViewMode(null), WebFileViewMode.list);
      expect(parseWebFileViewMode(''), WebFileViewMode.list);
      expect(parseWebFileViewMode('largeGrid'), WebFileViewMode.list);
      expect(parseWebFileViewMode('GRID2'), WebFileViewMode.list);
    });

    test('storage keys are per screen and namespaced', () {
      expect(webFileViewModeKey('category_images'),
          'fx.viewMode.category_images');
      expect(webFileViewModeKey('cloud'), 'fx.viewMode.cloud');
      expect(webFileViewModeKey('category_images'),
          isNot(webFileViewModeKey('category_documents')));
    });
  });

  group('webGridColumnsFor', () {
    test('phone width gives exactly the column count the mode promises', () {
      expect(webGridColumnsFor(WebFileViewMode.grid2, 390), 2);
      expect(webGridColumnsFor(WebFileViewMode.grid3, 390), 3);
      // Boundary: <600 is phone.
      expect(webGridColumnsFor(WebFileViewMode.grid2, 599.9), 2);
    });

    test('scales by whole multiples on wider viewports', () {
      expect(webGridColumnsFor(WebFileViewMode.grid2, 600), 4);
      expect(webGridColumnsFor(WebFileViewMode.grid2, 1200), 6);
      expect(webGridColumnsFor(WebFileViewMode.grid2, 1800), 8);
      expect(webGridColumnsFor(WebFileViewMode.grid3, 600), 6);
      expect(webGridColumnsFor(WebFileViewMode.grid3, 1200), 9);
      expect(webGridColumnsFor(WebFileViewMode.grid3, 2560), 12);
    });

    test('grid3 is always denser than grid2, and both are monotonic', () {
      var prev2 = 0;
      var prev3 = 0;
      for (var w = 200.0; w <= 3000; w += 50) {
        final c2 = webGridColumnsFor(WebFileViewMode.grid2, w);
        final c3 = webGridColumnsFor(WebFileViewMode.grid3, w);
        expect(c3, greaterThan(c2), reason: 'at width $w');
        expect(c2, greaterThanOrEqualTo(prev2), reason: 'at width $w');
        expect(c3, greaterThanOrEqualTo(prev3), reason: 'at width $w');
        prev2 = c2;
        prev3 = c3;
      }
    });

    test('list mode reports a single column', () {
      expect(webGridColumnsFor(WebFileViewMode.list, 390), 1);
      expect(webGridColumnsFor(WebFileViewMode.list, 2560), 1);
    });

    test('never returns a non-positive count (would crash SliverGrid)', () {
      for (final m in WebFileViewMode.values) {
        for (final w in [0.0, 1.0, 320.0, 5000.0]) {
          expect(webGridColumnsFor(m, w), greaterThan(0));
        }
      }
    });
  });

  group('grid metrics', () {
    test('aspect ratios are positive and the dense grid is squarer', () {
      final a2 = webGridAspectRatioFor(WebFileViewMode.grid2);
      final a3 = webGridAspectRatioFor(WebFileViewMode.grid3);
      expect(a2, greaterThan(0));
      expect(a3, greaterThan(0));
      expect(a3, lessThan(a2));
    });

    test('low-end devices get a smaller cacheExtent (fewer offscreen '
        'thumbnail fetches)', () {
      expect(webGridCacheExtent(lowEnd: true),
          lessThan(webGridCacheExtent(lowEnd: false)));
      expect(webGridCacheExtent(lowEnd: true), greaterThan(0));
    });
  });
}
