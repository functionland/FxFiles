import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/social_post_record.dart';

void main() {
  group('SocialPostStatus', () {
    test('wire round-trip + unknown maps to error', () {
      for (final s in SocialPostStatus.values) {
        expect(SocialPostStatus.fromWire(s.wire), s);
      }
      expect(SocialPostStatus.fromWire('weird'), SocialPostStatus.error);
      expect(SocialPostStatus.fromWire(null), SocialPostStatus.error);
    });

    test('isRunning covers exactly the non-terminal states', () {
      expect(SocialPostStatus.pending.isRunning, true);
      expect(SocialPostStatus.generating.isRunning, true);
      expect(SocialPostStatus.publishing.isRunning, true);
      expect(SocialPostStatus.completed.isRunning, false);
      expect(SocialPostStatus.error.isRunning, false);
    });
  });

  group('SocialPostRecord JSON', () {
    final full = SocialPostRecord(
      generationId: 'gen-1',
      tagId: 'tag-1',
      jobId: 'job-1',
      status: SocialPostStatus.completed,
      statusMessage: 'Social post ready',
      errorMessage: null,
      imageCid: 'bafyabc',
      imageUrl: 'https://gw/bafyabc',
      captions: const SocialCaptions(long: 'L', short: 'S'),
      websiteUrl: 'https://fxfiles.top/w/k',
      createdAt: DateTime.utc(2026, 7, 30, 10),
      updatedAt: DateTime.utc(2026, 7, 30, 11),
    );

    test('round-trips all fields', () {
      final restored = SocialPostRecord.fromJson(full.toJson());
      expect(restored, isNotNull);
      expect(restored!.generationId, 'gen-1');
      expect(restored.jobId, 'job-1');
      expect(restored.status, SocialPostStatus.completed);
      expect(restored.captions?.long, 'L');
      expect(restored.captions?.short, 'S');
      expect(restored.imageCid, 'bafyabc');
      expect(restored.websiteUrl, 'https://fxfiles.top/w/k');
      expect(restored.createdAt, DateTime.utc(2026, 7, 30, 10));
    });

    test('tolerates missing optionals and bad captions', () {
      final restored = SocialPostRecord.fromJson({
        'generationId': 'g2',
        'status': 'pending',
        'captions': {'long': 1}, // malformed → null captions
      });
      expect(restored, isNotNull);
      expect(restored!.captions, isNull);
      expect(restored.jobId, isNull);
      expect(restored.status, SocialPostStatus.pending);
    });

    test('rejects entries without a generationId', () {
      expect(SocialPostRecord.fromJson({'status': 'pending'}), isNull);
      expect(SocialPostRecord.fromJson({'generationId': ''}), isNull);
    });

    test('resolvedImageUrl prefers the recorded url, rebuilds from CID', () {
      expect(full.resolvedImageUrl, 'https://gw/bafyabc');
      final cidOnly = SocialPostRecord(
        generationId: 'g',
        tagId: 't',
        status: SocialPostStatus.completed,
        imageCid: 'bafyxyz',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(cidOnly.resolvedImageUrl, contains('bafyxyz'));
      final none = SocialPostRecord(
        generationId: 'g',
        tagId: 't',
        status: SocialPostStatus.pending,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(none.resolvedImageUrl, isNull);
    });
  });
}
