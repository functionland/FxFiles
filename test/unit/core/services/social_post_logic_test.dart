import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/services/social_post_logic.dart';

void main() {
  group('socialAssetPrefix', () {
    test('matches the website-assets sanitizer and clamps to 100', () {
      expect(socialAssetPrefix('Real Estate'), 'Real_Estate');
      expect(socialAssetPrefix('café+shop'), 'caf__shop');
      expect(socialAssetPrefix('a' * 150).length, 100);
      expect(socialAssetPrefix(''), '_');
    });
  });

  group('buildSocialGeneratePayload', () {
    final assets = [
      (fileName: 'hero.jpg', type: 'image', url: 'https://gw/a'),
      (fileName: 'logo.svg', type: 'image', url: 'https://gw/b'), // not raster
      (fileName: 'doc.pdf', type: 'document', url: 'https://gw/c'),
      (fileName: 'clip.mp4', type: 'video', url: 'https://gw/d'),
      (fileName: 'photo.PNG', type: 'image', url: 'https://gw/e'),
      (fileName: 'nourl.png', type: 'image', url: ''),
    ];

    test('keeps only URL-backed raster images', () {
      final payload = buildSocialGeneratePayload(
        generationId: 'g1',
        websiteUrl: 'https://fxfiles.top/w/x',
        userPrompt: 'my prompt',
        assets: assets,
        displayName: 'My Site',
      );
      final images = payload['assets'] as List;
      expect(images.map((a) => (a as Map)['fileName']),
          ['hero.jpg', 'photo.PNG']);
      expect(payload['assetPrefix'], 'My_Site');
      expect(payload['generationId'], 'g1');
      expect(payload['websiteUrl'], 'https://fxfiles.top/w/x');
      expect(payload['prompt'], 'my prompt');
    });

    test('caps at 14 images', () {
      final many = [
        for (var i = 0; i < 20; i++)
          (fileName: 'img$i.jpg', type: 'image', url: 'https://gw/$i'),
      ];
      final payload = buildSocialGeneratePayload(
        generationId: 'g1',
        websiteUrl: 'u',
        userPrompt: 'p',
        assets: many,
        displayName: 'd',
      );
      expect((payload['assets'] as List).length, 14);
    });
  });

  group('resolveSocialWebsiteUrl', () {
    test('front door wins, gateway falls back, null when neither', () {
      expect(resolveSocialWebsiteUrl('https://fxfiles.top/w/k', 'https://gw/c'),
          'https://fxfiles.top/w/k');
      expect(resolveSocialWebsiteUrl('', 'https://gw/c'), 'https://gw/c');
      expect(resolveSocialWebsiteUrl(null, null), isNull);
    });
  });

  group('socialUserPrompt', () {
    test('extracts the human body from an enriched prompt', () {
      const enriched = 'Website Name: My Site\n'
          'Category: Business\n\n'
          'A cozy bakery with fresh sourdough.';
      expect(socialUserPrompt(enriched),
          contains('cozy bakery'));
      expect(socialUserPrompt(enriched), isNot(contains('Website Name:')));
    });

    test('passes through a plain prompt', () {
      expect(socialUserPrompt('  just a prompt  '), 'just a prompt');
    });
  });

  group('mergeSocialPosts', () {
    Map<String, dynamic> entry(String id, String updatedAt,
            {String status = 'pending', Map<String, dynamic>? extra}) =>
        {
          'generationId': id,
          'status': status,
          'updatedAt': updatedAt,
          ...?extra,
        };

    test('latest updatedAt wins across blobs', () {
      final merged = mergeSocialPosts([
        [entry('a', '2026-07-30T10:00:00Z', status: 'pending')],
        [entry('a', '2026-07-30T11:00:00Z', status: 'completed')],
        [entry('a', '2026-07-30T09:00:00Z', status: 'generating')],
      ]);
      expect(merged['a']!['status'], 'completed');
    });

    test('skips malformed entries without dropping siblings', () {
      final merged = mergeSocialPosts([
        [
          {'noId': true},
          'garbage',
          entry('b', '2026-07-30T10:00:00Z'),
        ],
      ]);
      expect(merged.keys, ['b']);
    });

    test('preserves unknown keys on the winner', () {
      final merged = mergeSocialPosts([
        [
          entry('c', '2026-07-30T10:00:00Z',
              extra: {'futureField': 'kept'}),
        ],
      ]);
      expect(merged['c']!['futureField'], 'kept');
    });
  });

  group('captionForBufferService', () {
    test('short for twitter/x, long otherwise', () {
      expect(captionForBufferService('twitter', long: 'L', short: 'S'), 'S');
      expect(captionForBufferService('Twitter/X', long: 'L', short: 'S'), 'S');
      expect(captionForBufferService('x', long: 'L', short: 'S'), 'S');
      expect(
          captionForBufferService('instagram', long: 'L', short: 'S'), 'L');
      expect(captionForBufferService('facebook', long: 'L', short: 'S'), 'L');
      expect(captionForBufferService('linkedin', long: 'L', short: 'S'), 'L');
      expect(captionForBufferService('unknown', long: 'L', short: 'S'), 'L');
    });
  });

  group('socialResumeAction', () {
    final now = DateTime.utc(2026, 7, 30, 12);

    test('terminal states need nothing', () {
      for (final s in ['completed', 'error']) {
        expect(
          socialResumeAction(
              status: s, jobId: 'j', createdAt: now, now: now),
          SocialResumeAction.none,
        );
      }
    });

    test('running with jobId resumes regardless of age', () {
      expect(
        socialResumeAction(
            status: 'generating',
            jobId: 'j',
            createdAt: now.subtract(const Duration(days: 2)),
            now: now),
        SocialResumeAction.resumePoll,
      );
    });

    test('pending without jobId: fresh waits, stale marks interrupted', () {
      expect(
        socialResumeAction(
            status: 'pending',
            jobId: null,
            createdAt: now.subtract(const Duration(minutes: 2)),
            now: now),
        SocialResumeAction.none,
      );
      expect(
        socialResumeAction(
            status: 'pending',
            jobId: '',
            createdAt: now.subtract(const Duration(minutes: 10)),
            now: now),
        SocialResumeAction.markInterrupted,
      );
    });
  });

  group('nextSocialPollInterval', () {
    test('2s -> 3s -> 4.5s -> ... capped at 10s', () {
      var d = const Duration(seconds: 2);
      d = nextSocialPollInterval(d);
      expect(d, const Duration(seconds: 3));
      d = nextSocialPollInterval(d);
      expect(d, const Duration(milliseconds: 4500));
      for (var i = 0; i < 10; i++) {
        d = nextSocialPollInterval(d);
      }
      expect(d, const Duration(seconds: 10));
      expect(nextSocialPollInterval(const Duration(seconds: 10)),
          const Duration(seconds: 10));
    });
  });

  group('summarizeBufferResults', () {
    test('all ok / partial / none', () {
      expect(
        summarizeBufferResults([
          (channelId: 'a', ok: true, error: null),
          (channelId: 'b', ok: true, error: null),
        ]),
        (summary: 'Posted to all 2 channels', allOk: true),
      );
      expect(
        summarizeBufferResults([
          (channelId: 'a', ok: true, error: null),
          (channelId: 'b', ok: false, error: 'x'),
        ]),
        (summary: 'Posted to 1 of 2 channels', allOk: false),
      );
      expect(summarizeBufferResults([]).allOk, false);
    });
  });
}
