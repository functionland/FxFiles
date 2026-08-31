// FxFiles user status tiers, from Member up to Platinum Whale.
//
// Pure Dart on purpose — no Flutter import — so the thresholds are
// unit-testable in the VM and the same logic can be reused from a native
// screen later without dragging widget code along. Colours and glyphs
// live in the badge widget, not here.
//
// WHAT EARNS A RANK
// -----------------
// Tokens held PLUS tokens spent in the last 12 months:
//
//     score = balanceFula + deductedLast12Months
//
// Both halves matter, and the second is the whole point. `balanceFula`
// alone is a CURRENT balance — it falls as the product is used, so
// ranking on it would DEMOTE people for being customers. Adding the
// spend back makes the score monotonic for anyone who never withdraws:
// storing more data moves tokens from the first term to the second and
// leaves the total where it was.
//
// The spend half is a TRAILING 12-MONTH window, not lifetime, so status
// reflects a user who is active now rather than one who was active once.
// A consequence worth knowing: the score can FALL over time as old spend
// ages out of the window, so a tier is not permanent. That is deliberate.
//
// Both inputs come straight from the billing API (`/api/v1/storage` →
// `balanceFula`, `deductedFulaLast12Months`). The client cannot derive
// the second one itself — see the note on that endpoint in the
// pinning-service repo — so an older server that omits it degrades to
// ranking on holdings alone rather than failing.
//
// Rank is presentational only right now — nothing gates on it.
library;

/// The status ladder, ascending. Order is load-bearing: `index` is used
/// as the tier's level in comparisons and monotonicity checks.
///
/// Note that Diamond sits BETWEEN Gold and Platinum rather than at the
/// top. That is unusual — Diamond normally tops a ladder — but it is
/// what the thresholds say (250,000 against Platinum's 500,000), and the
/// numbers are the specification.
enum UserRank {
  member,
  starter,
  growth,
  whale,
  silverWhale,
  goldWhale,
  diamondWhale,
  platinumWhale,
}

/// Display name shown beside the logo, in full.
String userRankLabel(UserRank rank) => switch (rank) {
      UserRank.member => 'Member',
      UserRank.starter => 'Starter',
      UserRank.growth => 'Growth',
      UserRank.whale => 'Whale',
      UserRank.silverWhale => 'Silver Whale',
      UserRank.goldWhale => 'Gold Whale',
      UserRank.diamondWhale => 'Diamond Whale',
      UserRank.platinumWhale => 'Platinum Whale',
    };

/// The tier's glyph.
///
/// DELIBERATELY NOT UNIQUE: a whale marks five of the eight tiers,
/// because the ladder is a whale ladder from 25,000 up. The glyph
/// signals the FAMILY; the label and the colour separate the tiers
/// within it. This is exactly why the badge cannot drop its label the
/// way a pip-count badge could — the glyph alone does not identify a
/// tier.
String userRankEmoji(UserRank rank) => switch (rank) {
      UserRank.member => '⭐',
      UserRank.starter => '🚀',
      UserRank.growth => '📈',
      UserRank.whale => '🐋',
      UserRank.silverWhale => '🐋',
      UserRank.goldWhale => '🐋',
      UserRank.diamondWhale => '💎',
      UserRank.platinumWhale => '🐋',
    };

/// Token thresholds, highest first.
///
/// Keep them ordered high→low; [rankForTokenScore] depends on it, and
/// `user_rank_test.dart` asserts the ordering so a careless insert fails
/// loudly rather than silently mis-ranking everyone.
///
/// [UserRank.member] is absent on purpose: it is the floor, earned by
/// having no score at all rather than by clearing a threshold.
const List<(UserRank, double)> kRankThresholdsTokens = <(UserRank, double)>[
  (UserRank.platinumWhale, 500000),
  (UserRank.diamondWhale, 250000),
  (UserRank.goldWhale, 125000),
  (UserRank.silverWhale, 62500),
  (UserRank.whale, 25000),
  (UserRank.growth, 12000),
  (UserRank.starter, 5000),
];

/// The status score: tokens held plus tokens spent in the last 12
/// months.
///
/// Defined here rather than at the call site so the metric has ONE
/// definition — the screen reads two numbers off `StorageInfo` and this
/// decides what they mean.
///
/// Both arguments are clamped at zero. A negative balance is a real
/// state in the billing system (an account can be overdrawn into
/// suspension), and letting it subtract from the spend term would rank a
/// suspended heavy user BELOW an empty account.
double userRankScore({
  required double balanceFula,
  required double deductedLast12Months,
}) {
  final held = balanceFula.isFinite && balanceFula > 0 ? balanceFula : 0.0;
  final used = deductedLast12Months.isFinite && deductedLast12Months > 0
      ? deductedLast12Months
      : 0.0;
  return held + used;
}

/// The rank earned by [tokens].
///
/// Everyone has a rank: an account below the first threshold is Member
/// rather than badge-less, so the header never renders an empty gap and
/// a new user can see what they are climbing from.
UserRank rankForTokenScore(double tokens) {
  // Defensive: a negative, NaN or absurd value from the billing API must
  // not produce a rank the thresholds never intended. NaN fails every
  // comparison below, so it would otherwise fall through to Member by
  // accident rather than by decision — this makes it a decision.
  if (!tokens.isFinite || tokens <= 0) return UserRank.member;
  for (final (rank, threshold) in kRankThresholdsTokens) {
    if (tokens >= threshold) return rank;
  }
  return UserRank.member;
}

/// Tokens still needed to reach the next tier, or null when already at
/// the top. Drives the badge's tooltip.
double? tokensToNextRank(double tokens) {
  // Normalise garbage to "no score" — the SAME reading
  // [rankForTokenScore] gives it, so the two can never disagree about a
  // NaN account (one calling it Member while the other calls it the top
  // rank, which is how the badge would end up telling a brand-new user
  // there is nothing left to unlock).
  final score = tokens.isFinite && tokens > 0 ? tokens : 0.0;
  if (rankForTokenScore(score) == UserRank.platinumWhale) return null;
  // Thresholds are ordered high→low, so the next tier up is the LAST
  // entry whose threshold still exceeds the current score.
  double? next;
  for (final (_, threshold) in kRankThresholdsTokens) {
    if (score < threshold) next = threshold;
  }
  if (next == null) return null;
  final remaining = next - score;
  return remaining > 0 ? remaining : null;
}

/// The tier immediately above [rank], or null at the top.
///
/// Derived from the enum's declaration order rather than a hand-written
/// switch: with eight tiers a switch is one careless edit away from
/// disagreeing with [kRankThresholdsTokens] about who is at the top.
UserRank? nextRankAfter(UserRank rank) {
  final next = rank.index + 1;
  return next < UserRank.values.length ? UserRank.values[next] : null;
}
