// User rank tiers (Bronze → Silver → Gold → Platinum).
//
// Pure Dart on purpose — no Flutter import — so the thresholds are
// unit-testable in the VM and the same logic can be reused from a native
// screen later without dragging widget code along. Colours and icons
// live in the badge widget, not here.
//
// WHAT EARNS A RANK
// -----------------
// Purchased storage, i.e. `StorageInfo.paidStorageBytes`. That is the
// only lifetime "you paid for this" signal the client actually has:
// `balanceFula` is a CURRENT balance (it goes down when spent, so
// ranking on it would demote people for using the product), and
// `usedCredits`/`totalCredits` are a per-period credit allowance, not
// cumulative spend. There is no lifetime-spend field on StorageInfo
// today; if one is added server-side, `rankForPaidStorageBytes` is the
// single place to switch to it.
//
// Rank is presentational only right now — nothing gates on it.
library;

enum UserRank { bronze, silver, gold, platinum }

/// Display name shown beside the logo.
String userRankLabel(UserRank rank) => switch (rank) {
      UserRank.bronze => 'Bronze',
      UserRank.silver => 'Silver',
      UserRank.gold => 'Gold',
      UserRank.platinum => 'Platinum',
    };

/// Pip count, in the military-insignia sense: one star for the entry
/// tier up to four at the top. Deliberately capped at 4 — more pips than
/// that stop being countable at a glance and start costing header width.
int userRankStars(UserRank rank) => switch (rank) {
      UserRank.bronze => 1,
      UserRank.silver => 2,
      UserRank.gold => 3,
      UserRank.platinum => 4,
    };

const int _kGiB = 1024 * 1024 * 1024;

/// Purchased-storage thresholds, highest first.
///
/// These are a starting point, not a law — they are the one thing here
/// most likely to need tuning once you can see the real distribution of
/// paid storage across accounts. Keep them ordered high→low; the lookup
/// below depends on it.
const List<(UserRank, int)> kRankThresholdsBytes = <(UserRank, int)>[
  (UserRank.platinum, 2048 * _kGiB), // 2 TiB
  (UserRank.gold, 512 * _kGiB), //     512 GiB
  (UserRank.silver, 100 * _kGiB), //   100 GiB
];

/// The rank earned by [paidStorageBytes].
///
/// Everyone has a rank: an account with no purchased storage is Bronze
/// rather than badge-less, so the header never renders an empty gap and
/// a new user can see what they are climbing from.
UserRank rankForPaidStorageBytes(int paidStorageBytes) {
  // Defensive: a negative or absurd value from the billing API must not
  // produce a rank the thresholds never intended.
  if (paidStorageBytes <= 0) return UserRank.bronze;
  for (final (rank, threshold) in kRankThresholdsBytes) {
    if (paidStorageBytes >= threshold) return rank;
  }
  return UserRank.bronze;
}

/// Bytes of purchased storage still needed to reach the next tier, or
/// null when already at the top. Drives the badge's tooltip.
int? bytesToNextRank(int paidStorageBytes) {
  final current = rankForPaidStorageBytes(paidStorageBytes);
  if (current == UserRank.platinum) return null;
  // Thresholds are ordered high→low, so the next tier up is the LAST
  // entry whose threshold still exceeds the current holding.
  int? next;
  for (final (_, threshold) in kRankThresholdsBytes) {
    if (paidStorageBytes < threshold) next = threshold;
  }
  if (next == null) return null;
  final remaining = next - paidStorageBytes;
  return remaining > 0 ? remaining : null;
}

/// The tier immediately above [rank], or null at the top.
UserRank? nextRankAfter(UserRank rank) => switch (rank) {
      UserRank.bronze => UserRank.silver,
      UserRank.silver => UserRank.gold,
      UserRank.gold => UserRank.platinum,
      UserRank.platinum => null,
    };
