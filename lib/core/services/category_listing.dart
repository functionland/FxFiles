// Merged category listing for the v8 migration (Phase 2a).
//
// A category's content can be split across its legacy bucket (old uploads) and
// its fresh `<base>-v8` bucket (new uploads — see
// docs/v8-bucket-migration-plan.md). This helper presents them as ONE list: it
// reads every bucket in `BucketVersionResolver.readBuckets(base)`, tags each
// object with the bucket it actually lives in (`FulaObject.sourceBucket`), and
// merges them deduped by key (the v8 copy wins on a collision — prefer-v8).
//
// Standalone over the `FulaApi` interface so it behaves identically with the
// real `FulaApiService` and the test fake, with no interface change.
//
// When v8 routing is disabled, or [base] is unmanaged, `readBuckets` returns
// just `[base]` and this collapses to a single tagged `listObjects` call — zero
// behavior change. (Phase 3 layers a frozen legacy cache and Phase 4 a
// tombstone-subtraction over this same seam.)

import 'package:flutter/foundation.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api.dart';
import 'package:fula_files/core/services/legacy_listing_cache.dart';

/// List a category as a single merged view across its legacy + v8 buckets.
///
/// `readBuckets` is legacy-first / v8-last, so a key present in BOTH resolves
/// to the v8 object (prefer-v8). The legacy bucket (first) is the source of
/// truth and MUST load — a real error there propagates. A later (v8) bucket
/// that doesn't exist yet (no uploads in this category) or hiccups is treated
/// as empty, so it can never hide legacy content.
Future<List<FulaObject>> listCategoryMerged(
  FulaApi api,
  String base, {
  String prefix = '',
}) async {
  final buckets = BucketVersionResolver.readBuckets(base);

  // Fast path: single bucket (unmanaged / v8 disabled). Tag + return.
  if (buckets.length == 1) {
    final objs = await api.listObjects(buckets.first, prefix: prefix);
    return objs.map((o) => o.withSourceBucket(buckets.first)).toList();
  }

  final byKey = <String, FulaObject>{};
  for (var i = 0; i < buckets.length; i++) {
    final bucket = buckets[i];
    List<FulaObject> objs;
    try {
      objs = await api.listObjects(bucket, prefix: prefix);
    } catch (e) {
      if (i == 0) rethrow; // legacy is the source of truth — it must load
      // A v8 sibling may not exist yet (no uploads here) or may hiccup;
      // treat as empty rather than hiding all of legacy.
      debugPrint('listCategoryMerged: skipping "$bucket" (treated empty): $e');
      objs = const <FulaObject>[];
    }
    for (final o in objs) {
      byKey[o.key] = o.withSourceBucket(bucket); // later bucket (v8) wins
    }
  }
  return byKey.values.toList();
}

/// Cached / timeout-bounded variant of [listCategoryMerged], mirroring
/// [FulaApi.listObjectsCached] so browser screens keep their stale-aware,
/// non-blocking behavior across the legacy+v8 merge.
///
/// `stale` is true if ANY queried bucket served from cache; `fetchedAt` is the
/// OLDEST of the merged fetches (the conservative freshness). Same error
/// policy as [listCategoryMerged]: legacy (first) propagates, v8 (later) is
/// tolerated as empty.
Future<({List<FulaObject> objects, bool stale, DateTime? fetchedAt})>
    listCategoryMergedCached(
  FulaApi api,
  String base, {
  String prefix = '',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final buckets = BucketVersionResolver.readBuckets(base);

  // Fast path: single bucket (unmanaged / v8 disabled).
  if (buckets.length == 1) {
    final r = await api.listObjectsCached(
      buckets.first,
      prefix: prefix,
      timeout: timeout,
    );
    return (
      objects:
          r.objects.map((o) => o.withSourceBucket(buckets.first)).toList(),
      stale: r.stale,
      fetchedAt: r.fetchedAt,
    );
  }

  final byKey = <String, FulaObject>{};
  var anyStale = false;
  DateTime? oldestFetch;
  for (var i = 0; i < buckets.length; i++) {
    final bucket = buckets[i];
    ({List<FulaObject> objects, bool stale, DateTime? fetchedAt}) r;
    try {
      r = await api.listObjectsCached(bucket, prefix: prefix, timeout: timeout);
    } catch (e) {
      if (i == 0) rethrow; // legacy is the source of truth — it must load
      debugPrint(
        'listCategoryMergedCached: skipping "$bucket" (treated empty): $e',
      );
      continue;
    }
    anyStale = anyStale || r.stale;
    final f = r.fetchedAt;
    if (f != null && (oldestFetch == null || f.isBefore(oldestFetch!))) {
      oldestFetch = f;
    }
    for (final o in r.objects) {
      byKey[o.key] = o.withSourceBucket(bucket); // later bucket (v8) wins
    }
  }
  return (
    objects: byKey.values.toList(),
    stale: anyStale,
    fetchedAt: oldestFetch,
  );
}

/// Cache-backed merged listing (Phase 3): the LEGACY bucket is loaded ONCE and
/// frozen in [cache] (legacy is immutable post-migration), so steady-state
/// opens only hit the fresh `-v8` bucket live. New users (no legacy bucket) and
/// transient legacy errors are treated as empty — never a breaking error.
///
/// Returns the same `(objects, stale, fetchedAt)` shape as
/// [FulaApi.listObjectsCached] so it drops into the browser screens.
Future<({List<FulaObject> objects, bool stale, DateTime? fetchedAt})>
    listCategoryCached(
  FulaApi api,
  LegacyListingCache cache,
  String userId,
  String base, {
  String prefix = '',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final buckets = BucketVersionResolver.readBuckets(base);

  // Single bucket (unmanaged / v8 disabled): no legacy/v8 split, no caching.
  if (buckets.length == 1) {
    final r = await api.listObjectsCached(
      buckets.first,
      prefix: prefix,
      timeout: timeout,
    );
    return (
      objects:
          r.objects.map((o) => o.withSourceBucket(buckets.first)).toList(),
      stale: r.stale,
      fetchedAt: r.fetchedAt,
    );
  }

  final legacy = buckets[0];
  final v8 = buckets[1];

  // 1) LEGACY — frozen cache if present (incl. frozen-empty); else load once
  //    and freeze on a FRESH success. Failure / new-user → treated as empty.
  List<FulaObject> legacyItems;
  var legacyStale = false;
  final frozen = cache.getFrozen(userId, legacy);
  if (frozen != null) {
    legacyItems = frozen; // instant — legacy is never re-loaded once frozen
  } else {
    try {
      final r =
          await api.listObjectsCached(legacy, prefix: prefix, timeout: timeout);
      legacyItems = r.objects;
      legacyStale = r.stale;
      if (!r.stale) {
        // Fresh complete load (incl. a genuinely-empty / new-user result) →
        // freeze so legacy is never re-loaded. Stale (master-down) loads are
        // NOT frozen — they may be incomplete.
        await cache.freeze(userId, legacy, legacyItems);
      }
    } catch (e) {
      debugPrint('listCategoryCached: legacy "$legacy" failed → empty: $e');
      legacyItems = const <FulaObject>[];
    }
  }

  // 2) v8 — always live (the fresh, frequently-changing bucket).
  List<FulaObject> v8Items = const <FulaObject>[];
  var v8Stale = false;
  DateTime? v8Fetch;
  try {
    final r = await api.listObjectsCached(v8, prefix: prefix, timeout: timeout);
    v8Items = r.objects;
    v8Stale = r.stale;
    v8Fetch = r.fetchedAt;
  } catch (e) {
    // v8 may not exist yet (no uploads in this category) → empty.
    debugPrint('listCategoryCached: v8 "$v8" failed → empty: $e');
  }

  // 3) Merge — legacy first, v8 overwrites (prefer-v8), each tagged.
  final byKey = <String, FulaObject>{};
  for (final o in legacyItems) {
    byKey[o.key] = o.withSourceBucket(legacy);
  }
  for (final o in v8Items) {
    byKey[o.key] = o.withSourceBucket(v8);
  }

  return (
    objects: byKey.values.toList(),
    stale: legacyStale || v8Stale,
    fetchedAt: v8Fetch,
  );
}
