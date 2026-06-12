import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_swr_policy.dart';

void main() {
  group('swrTierForAge', () {
    test('fresh below 2 minutes', () {
      expect(swrTierForAge(Duration.zero), SwrTier.fresh);
      expect(swrTierForAge(const Duration(seconds: 119)), SwrTier.fresh);
    });

    test('silent between 2 minutes and 1 hour', () {
      expect(swrTierForAge(const Duration(minutes: 2)), SwrTier.silent);
      expect(swrTierForAge(const Duration(minutes: 59, seconds: 59)),
          SwrTier.silent);
    });

    test('stale at and beyond 1 hour', () {
      expect(swrTierForAge(const Duration(hours: 1)), SwrTier.stale);
      expect(swrTierForAge(const Duration(days: 3)), SwrTier.stale);
    });

    test('windows keep their plan-reviewed ordering', () {
      expect(kSwrFreshWindow < kSwrSilentWindow, isTrue);
      expect(kSwrSyncedAgoWindow > kSwrFreshWindow, isTrue);
      expect(kSwrSyncedAgoWindow < kSwrSilentWindow, isTrue);
    });
  });
}
