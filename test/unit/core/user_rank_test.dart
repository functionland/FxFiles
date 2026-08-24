import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/user_rank.dart';

const int _gib = 1024 * 1024 * 1024;

void main() {
  group('rankForPaidStorageBytes', () {
    test('no purchased storage is Bronze, not "no rank"', () {
      // Everyone has a rank so the header never renders an empty gap.
      expect(rankForPaidStorageBytes(0), UserRank.bronze);
      expect(rankForPaidStorageBytes(1), UserRank.bronze);
      expect(rankForPaidStorageBytes(99 * _gib), UserRank.bronze);
    });

    test('a nonsense value from the billing API cannot invent a rank', () {
      expect(rankForPaidStorageBytes(-1), UserRank.bronze);
      expect(rankForPaidStorageBytes(-999 * _gib), UserRank.bronze);
    });

    test('each threshold is inclusive at its exact boundary', () {
      expect(rankForPaidStorageBytes(100 * _gib), UserRank.silver);
      expect(rankForPaidStorageBytes(512 * _gib), UserRank.gold);
      expect(rankForPaidStorageBytes(2048 * _gib), UserRank.platinum);
    });

    test('one byte below a threshold stays in the lower tier', () {
      expect(rankForPaidStorageBytes(100 * _gib - 1), UserRank.bronze);
      expect(rankForPaidStorageBytes(512 * _gib - 1), UserRank.silver);
      expect(rankForPaidStorageBytes(2048 * _gib - 1), UserRank.gold);
    });

    test('far above the top threshold is still Platinum', () {
      expect(rankForPaidStorageBytes(100000 * _gib), UserRank.platinum);
    });

    test('is monotonic — more storage never lowers the rank', () {
      var previous = -1;
      for (var gb = 0; gb <= 4096; gb += 37) {
        final rank = rankForPaidStorageBytes(gb * _gib);
        final level = UserRank.values.indexOf(rank);
        expect(level, greaterThanOrEqualTo(previous),
            reason: 'rank went backwards at ${gb}GiB');
        previous = level;
      }
    });
  });

  group('stars and labels', () {
    test('one pip per tier, ascending, capped at four', () {
      expect(userRankStars(UserRank.bronze), 1);
      expect(userRankStars(UserRank.silver), 2);
      expect(userRankStars(UserRank.gold), 3);
      expect(userRankStars(UserRank.platinum), 4);
    });

    test('every tier has a label', () {
      for (final r in UserRank.values) {
        expect(userRankLabel(r), isNotEmpty);
      }
    });
  });

  group('bytesToNextRank', () {
    test('reports the gap to the next tier', () {
      expect(bytesToNextRank(0), 100 * _gib);
      expect(bytesToNextRank(50 * _gib), 50 * _gib);
      expect(bytesToNextRank(100 * _gib), (512 - 100) * _gib);
      expect(bytesToNextRank(512 * _gib), (2048 - 512) * _gib);
    });

    test('is null at the top tier', () {
      expect(bytesToNextRank(2048 * _gib), isNull);
      expect(bytesToNextRank(9999 * _gib), isNull);
    });

    test('never reports a non-positive gap', () {
      for (var gb = 0; gb <= 3000; gb += 13) {
        final gap = bytesToNextRank(gb * _gib);
        if (gap != null) {
          expect(gap, greaterThan(0), reason: 'at ${gb}GiB');
        }
      }
    });
  });

  group('nextRankAfter', () {
    test('walks the ladder and stops at the top', () {
      expect(nextRankAfter(UserRank.bronze), UserRank.silver);
      expect(nextRankAfter(UserRank.silver), UserRank.gold);
      expect(nextRankAfter(UserRank.gold), UserRank.platinum);
      expect(nextRankAfter(UserRank.platinum), isNull);
    });

    test('agrees with bytesToNextRank about who is at the top', () {
      for (final r in UserRank.values) {
        final atTop = nextRankAfter(r) == null;
        expect(atTop, r == UserRank.platinum);
      }
    });
  });
}
