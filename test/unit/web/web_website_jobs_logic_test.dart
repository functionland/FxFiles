import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_website_jobs_logic.dart';

Map<String, dynamic> _entry(String id,
        {String? updatedAt, Map<String, dynamic> extra = const {}}) =>
    {
      'generationId': id,
      'jobId': 'job-$id',
      if (updatedAt != null) 'updatedAt': updatedAt,
      ...extra,
    };

void main() {
  group('mergePendingJobs', () {
    test('newest updatedAt wins per generationId across blobs', () {
      final out = mergePendingJobs([
        [_entry('a', updatedAt: '2026-01-01T00:00:00.000')],
        [_entry('a', updatedAt: '2026-01-02T00:00:00.000')],
        [_entry('a', updatedAt: '2026-01-01T12:00:00.000')],
      ]);
      expect(out['a']!['updatedAt'], '2026-01-02T00:00:00.000');
    });

    test('missing or unparseable updatedAt reads as epoch and loses', () {
      final out = mergePendingJobs([
        [_entry('a')],
        [_entry('a', updatedAt: 'not-a-date')],
        [_entry('a', updatedAt: '2026-01-01T00:00:00.000')],
      ]);
      expect(out['a']!['updatedAt'], '2026-01-01T00:00:00.000');
    });

    test('epoch never beats an existing epoch entry (first stays)', () {
      final out = mergePendingJobs([
        [
          _entry('a', extra: {'marker': 'first'}),
          _entry('a', extra: {'marker': 'second'}),
        ],
      ]);
      expect(out['a']!['marker'], 'first');
    });

    test('non-map and id-less entries are skipped', () {
      final out = mergePendingJobs([
        [
          'junk',
          42,
          {'jobId': 'no-generation-id'},
          {'generationId': ''},
          {'generationId': 7},
          _entry('a'),
        ],
      ]);
      expect(out.keys.toList(), ['a']);
    });

    test('unknown fields on the winning raw map survive', () {
      final out = mergePendingJobs([
        [
          _entry('a',
              updatedAt: '2026-01-02T00:00:00.000',
              extra: {'futureField': 'preserved'}),
        ],
        [_entry('a', updatedAt: '2026-01-01T00:00:00.000')],
      ]);
      expect(out['a']!['futureField'], 'preserved');
    });

    test('empty input yields empty map', () {
      expect(mergePendingJobs(const []), isEmpty);
      expect(mergePendingJobs(const [[]]), isEmpty);
    });
  });
}
