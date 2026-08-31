import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/user_rank.dart';

void main() {
  group('the published ladder', () {
    // These numbers ARE the specification, so they are asserted
    // literally rather than derived. If a threshold is ever retuned this
    // test should fail and be updated deliberately — silently shifting
    // what "Whale" means is the failure mode worth catching.
    test('every tier sits at its published token threshold', () {
      expect(kRankThresholdsTokens, [
        (UserRank.platinumWhale, 500000.0),
        (UserRank.diamondWhale, 250000.0),
        (UserRank.goldWhale, 125000.0),
        (UserRank.silverWhale, 62500.0),
        (UserRank.whale, 25000.0),
        (UserRank.growth, 12000.0),
        (UserRank.starter, 5000.0),
      ]);
    });

    test('thresholds are ordered high to low', () {
      // rankForTokenScore walks this list top-down and returns the first
      // match, so an out-of-order entry would silently mis-rank people.
      for (var i = 1; i < kRankThresholdsTokens.length; i++) {
        expect(kRankThresholdsTokens[i].$2,
            lessThan(kRankThresholdsTokens[i - 1].$2));
      }
    });

    test('the threshold list agrees with the enum order', () {
      // Diamond deliberately sits BELOW Platinum. Pin that down: it is
      // the one place this ladder departs from the usual convention, so
      // it is also the one most likely to be "fixed" by mistake.
      final ranked = kRankThresholdsTokens.map((e) => e.$1).toList();
      for (var i = 1; i < ranked.length; i++) {
        expect(ranked[i].index, lessThan(ranked[i - 1].index));
      }
      expect(UserRank.diamondWhale.index,
          greaterThan(UserRank.goldWhale.index));
      expect(UserRank.diamondWhale.index,
          lessThan(UserRank.platinumWhale.index));
    });

    test('every tier except the floor has a threshold', () {
      final withThreshold = kRankThresholdsTokens.map((e) => e.$1).toSet();
      expect(withThreshold, UserRank.values.toSet()..remove(UserRank.member));
    });
  });

  group('rankForTokenScore', () {
    test('below the first threshold is Member, not "no rank"', () {
      // Everyone has a rank so the header never renders an empty gap.
      expect(rankForTokenScore(0), UserRank.member);
      expect(rankForTokenScore(1), UserRank.member);
      expect(rankForTokenScore(4999.99), UserRank.member);
    });

    test('a nonsense value from the billing API cannot invent a rank', () {
      expect(rankForTokenScore(-1), UserRank.member);
      expect(rankForTokenScore(-999999), UserRank.member);
      expect(rankForTokenScore(double.nan), UserRank.member);
      expect(rankForTokenScore(double.infinity), UserRank.member);
      expect(rankForTokenScore(double.negativeInfinity), UserRank.member);
    });

    test('each threshold is inclusive at its exact boundary', () {
      expect(rankForTokenScore(5000), UserRank.starter);
      expect(rankForTokenScore(12000), UserRank.growth);
      expect(rankForTokenScore(25000), UserRank.whale);
      expect(rankForTokenScore(62500), UserRank.silverWhale);
      expect(rankForTokenScore(125000), UserRank.goldWhale);
      expect(rankForTokenScore(250000), UserRank.diamondWhale);
      expect(rankForTokenScore(500000), UserRank.platinumWhale);
    });

    test('one token below a threshold stays in the lower tier', () {
      expect(rankForTokenScore(4999), UserRank.member);
      expect(rankForTokenScore(11999), UserRank.starter);
      expect(rankForTokenScore(24999), UserRank.growth);
      expect(rankForTokenScore(62499), UserRank.whale);
      expect(rankForTokenScore(124999), UserRank.silverWhale);
      expect(rankForTokenScore(249999), UserRank.goldWhale);
      expect(rankForTokenScore(499999), UserRank.diamondWhale);
    });

    test('far above the top threshold is still Platinum Whale', () {
      expect(rankForTokenScore(10000000), UserRank.platinumWhale);
    });

    test('is monotonic — more tokens never lower the rank', () {
      var previous = -1;
      for (var t = 0; t <= 600000; t += 997) {
        final level = rankForTokenScore(t.toDouble()).index;
        expect(level, greaterThanOrEqualTo(previous),
            reason: 'rank went backwards at $t tokens');
        previous = level;
      }
    });
  });

  group('userRankScore', () {
    test('is holdings plus the last 12 months of spend', () {
      expect(
        userRankScore(balanceFula: 20000, deductedLast12Months: 5000),
        25000,
      );
    });

    test('spending does not demote — it moves between the two terms', () {
      // The whole reason the spend term exists. A user who stores data
      // converts balance into spend; the total must not move.
      const held = 30000.0;
      for (final spent in [0.0, 1000.0, 12000.0, 29999.0]) {
        expect(
          userRankScore(
              balanceFula: held - spent, deductedLast12Months: spent),
          held,
          reason: 'score moved after spending $spent',
        );
      }
    });

    test('an overdrawn balance cannot subtract from spend', () {
      // A suspended account really can hold a negative balance. Letting
      // it net against the spend would rank a heavy user BELOW an empty
      // account.
      expect(
        userRankScore(balanceFula: -500, deductedLast12Months: 26000),
        26000,
      );
    });

    test('non-finite inputs are treated as zero, not propagated', () {
      expect(
        userRankScore(balanceFula: double.nan, deductedLast12Months: 26000),
        26000,
      );
      expect(
        userRankScore(
            balanceFula: 26000, deductedLast12Months: double.infinity),
        26000,
      );
      expect(
        userRankScore(
            balanceFula: double.nan, deductedLast12Months: double.nan),
        0,
      );
    });

    test('a server that omits the spend field ranks on holdings alone', () {
      // StorageInfo defaults the field to 0, so this is what an older
      // backend produces. A slightly low tier, never a crash.
      expect(
        userRankScore(balanceFula: 130000, deductedLast12Months: 0),
        130000,
      );
      expect(rankForTokenScore(130000), UserRank.goldWhale);
    });
  });

  group('tokensToNextRank', () {
    test('reports the gap to the next tier', () {
      expect(tokensToNextRank(0), 5000);
      expect(tokensToNextRank(5000), 7000);
      expect(tokensToNextRank(12000), 13000);
      expect(tokensToNextRank(25000), 37500);
      expect(tokensToNextRank(62500), 62500);
      expect(tokensToNextRank(125000), 125000);
      expect(tokensToNextRank(250000), 250000);
    });

    test('is null at the top tier', () {
      expect(tokensToNextRank(500000), isNull);
      expect(tokensToNextRank(9999999), isNull);
    });

    test('never reports a non-positive gap', () {
      for (var t = 0; t <= 550000; t += 631) {
        final gap = tokensToNextRank(t.toDouble());
        if (gap != null) {
          expect(gap, greaterThan(0), reason: 'at $t tokens');
        }
      }
    });

    test('garbage reads as "no score", never as the top rank', () {
      // The trap this guards: if a NaN returned null here while
      // rankForTokenScore called it Member, the badge would tell a
      // brand-new user they had nothing left to unlock.
      for (final bad in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
        -1.0,
      ]) {
        expect(tokensToNextRank(bad), 5000, reason: 'for $bad');
        expect(rankForTokenScore(bad), UserRank.member);
      }
    });

    test('the gap always lands exactly on the next tier', () {
      for (var t = 0; t <= 550000; t += 1013) {
        final score = t.toDouble();
        final gap = tokensToNextRank(score);
        if (gap == null) continue;
        final next = nextRankAfter(rankForTokenScore(score));
        expect(rankForTokenScore(score + gap), next,
            reason: 'adding the reported gap at $t did not reach $next');
      }
    });
  });

  group('nextRankAfter', () {
    test('walks the whole ladder and stops at the top', () {
      expect(nextRankAfter(UserRank.member), UserRank.starter);
      expect(nextRankAfter(UserRank.starter), UserRank.growth);
      expect(nextRankAfter(UserRank.growth), UserRank.whale);
      expect(nextRankAfter(UserRank.whale), UserRank.silverWhale);
      expect(nextRankAfter(UserRank.silverWhale), UserRank.goldWhale);
      expect(nextRankAfter(UserRank.goldWhale), UserRank.diamondWhale);
      expect(nextRankAfter(UserRank.diamondWhale), UserRank.platinumWhale);
      expect(nextRankAfter(UserRank.platinumWhale), isNull);
    });

    test('agrees with tokensToNextRank about who is at the top', () {
      for (final r in UserRank.values) {
        final atTop = nextRankAfter(r) == null;
        expect(atTop, r == UserRank.platinumWhale);
      }
    });
  });

  group('labels and glyphs', () {
    test('every tier has a distinct, non-empty label', () {
      final labels = UserRank.values.map(userRankLabel).toList();
      expect(labels.every((l) => l.isNotEmpty), isTrue);
      expect(labels.toSet().length, UserRank.values.length,
          reason: 'two tiers share a name and are indistinguishable');
    });

    test('every tier has a glyph', () {
      for (final r in UserRank.values) {
        expect(userRankEmoji(r), isNotEmpty, reason: r.name);
      }
    });

    test('the glyph alone does NOT identify a tier', () {
      // Documents WHY the badge can never drop its label: a whale marks
      // five of the eight tiers. If this ever became false, the badge
      // could go back to a glyph-only narrow layout.
      final whales =
          UserRank.values.where((r) => userRankEmoji(r) == '🐋').length;
      expect(whales, greaterThan(1));
    });
  });
}
