/// Freshness policy for the web SWR read path
/// (docs/web-listing-prefetch-cache-plan.md §5.3). Pure Dart — no web
/// imports — so the tier logic unit-tests on the VM.
library;

/// Below this age a cache hit renders with NO revalidation (a
/// navigation bounce shouldn't re-list).
const Duration kSwrFreshWindow = Duration(minutes: 2);

/// Between fresh and this: render + silent background revalidate.
/// Above it: stale banner + revalidate.
const Duration kSwrSilentWindow = Duration(hours: 1);

/// Age above which screens show the "Synced X min ago" line.
const Duration kSwrSyncedAgoWindow = Duration(minutes: 15);

enum SwrTier { fresh, silent, stale }

SwrTier swrTierForAge(Duration age) {
  if (age < kSwrFreshWindow) return SwrTier.fresh;
  if (age < kSwrSilentWindow) return SwrTier.silent;
  return SwrTier.stale;
}
